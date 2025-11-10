# --------------------------------------------------------------------------------------
# ------------------------------STAGE-1-------------------------------------------------
# --------------------------------------------------------------------------------------
#!/bin/bash
set -euo pipefail

echo "---------------------------------------"
echo "Stage 1 - Task 2: Validate and Process Inputs (Fixed for Bamboo Variable Syntax)"
echo "---------------------------------------"

# ---------------------------------------
# Step 1: Load AWS Credentials
# ---------------------------------------
export AWS_ACCESS_KEY_ID="${bamboo_AWS_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${bamboo_AWS_SECRET_ACCESS_KEY}"
export AWS_REGION="${bamboo_AWS_REGION}"

echo "Using AWS Region: $AWS_REGION"

# ---------------------------------------
# Step 2: Load Bamboo Variables
# ---------------------------------------
DATE_RAW="${bamboo_DATE}"
TIME_RAW="${bamboo_TIME}"
DB_NAMES_RAW="${bamboo_DB_NAMES}"
IOPS_RAW="${bamboo_IOPS_TICKET}"
RDS_RAW="${bamboo_RDS_INSTANCE_NAMES}"
TEAM_NAME="${bamboo_TEAM_NAME}"
USER_EMAILS_RAW="${bamboo_USER_EMAILS}"

# Validate mandatory inputs
if [[ -z "$DB_NAMES_RAW" || -z "$IOPS_RAW" || -z "$RDS_RAW" || -z "$TEAM_NAME" || -z "$USER_EMAILS_RAW" ]]; then
  echo "[ERROR] One or more required inputs are missing!"
  exit 1
fi

IFS=',' read -r -a RDS_INSTANCES <<< "$RDS_RAW"
IFS=',' read -r -a DATE_LIST <<< "$DATE_RAW"
IFS=',' read -r -a TIME_LIST <<< "$TIME_RAW"
IFS=',' read -r -a IOPS_LIST <<< "$IOPS_RAW"

NUM_RDS=${#RDS_INSTANCES[@]}
NUM_DATES=${#DATE_LIST[@]}
NUM_TIMES=${#TIME_LIST[@]}
NUM_IOPS=${#IOPS_LIST[@]}

echo "---------------------------------------"
echo "Input Summary:"
echo "RDS Count: $NUM_RDS"
echo "Date Entries: $NUM_DATES"
echo "Time Entries: $NUM_TIMES"
echo "IOPS Entries: $NUM_IOPS"
echo "---------------------------------------"

# Warn about mismatched lengths
if (( NUM_DATES > 0 && NUM_DATES != NUM_RDS )); then
  echo "[WARNING] DATE entries ($NUM_DATES) don't match RDS count ($NUM_RDS)"
fi
if (( NUM_TIMES > 0 && NUM_TIMES != NUM_RDS )); then
  echo "[WARNING] TIME entries ($NUM_TIMES) don't match RDS count ($NUM_RDS)"
fi
if (( NUM_IOPS > 0 && NUM_IOPS != NUM_RDS )); then
  echo "[WARNING] IOPS entries ($NUM_IOPS) don't match RDS count ($NUM_RDS)"
fi

# Helper: get last array element safely
get_last() {
  local -n arr=$1
  echo "${arr[$((${#arr[@]} - 1))]}"
}
LAST_IOPS="$(get_last IOPS_LIST)"

# Retry wrapper for AWS CLI
aws_retry() {
  local tries=0
  local max=3
  local delay=2
  local cmd=("$@")
  until (( tries >= max )); do
    if "${cmd[@]}"; then
      return 0
    fi
    ((tries++))
    echo "[WARN] Command failed, attempt $tries/$max. Retrying in ${delay}s..."
    sleep $delay
    delay=$((delay * 2))
  done
  echo "[ERROR] Command failed after $max attempts: ${cmd[*]}"
  return 1
}

declare -A RDS_RESTORE_TIMES
declare -A RDS_IOPS
declare -A RESTORE_SOURCE

# ---------------------------------------
# Step 3: Assign timestamps + IOPS per RDS
# ---------------------------------------
for i in "${!RDS_INSTANCES[@]}"; do
  RDS="$(echo "${RDS_INSTANCES[$i]}" | xargs)"
  DATE_INPUT="${DATE_LIST[$i]:-}"
  TIME_INPUT="${TIME_LIST[$i]:-}"
  IOPS_TICKET="${IOPS_LIST[$i]:-${LAST_IOPS}}"

  RDS_IOPS["$RDS"]="$IOPS_TICKET"

  if [[ -n "$DATE_INPUT" && -n "$TIME_INPUT" ]]; then
    TS="${DATE_INPUT}T${TIME_INPUT}"
    RDS_RESTORE_TIMES["$RDS"]="$TS"
    RESTORE_SOURCE["$RDS"]="Provided"
    echo "$RDS → Using provided timestamp: $TS (IOPS: $IOPS_TICKET)"
  else
    echo "$RDS → Fetching latest restorable time from AWS..."
    if ! LATEST_RESTORE_TIME=$(aws_retry aws rds describe-db-instances \
        --db-instance-identifier "$RDS" \
        --query "DBInstances[0].LatestRestorableTime" \
        --output text --region "$AWS_REGION" 2>/dev/null); then
      echo "[ERROR] Failed to fetch LatestRestorableTime for $RDS"
      continue
    fi

    if [[ "$LATEST_RESTORE_TIME" == "None" || -z "$LATEST_RESTORE_TIME" ]]; then
      echo "[WARNING] No LatestRestorableTime for $RDS"
      continue
    fi

    CLEAN_TIME=$(echo "$LATEST_RESTORE_TIME" | sed -E 's/(\.[0-9]+)?(\+.*|Z)//')
    RDS_RESTORE_TIMES["$RDS"]="$CLEAN_TIME"
    RESTORE_SOURCE["$RDS"]="AWS"
    echo "$RDS → LatestRestorableTime (from AWS): $CLEAN_TIME (IOPS: $IOPS_TICKET)"
    sleep 1
  fi
done

# Check if any RDS is missing a restore time
MISSING=()
for RDS in "${RDS_INSTANCES[@]}"; do
  RDS=$(echo "$RDS" | xargs)
  if [[ -z "${RDS_RESTORE_TIMES[$RDS]:-}" ]]; then
    MISSING+=("$RDS")
  fi
done

if (( ${#MISSING[@]} > 0 )); then
  echo "[ERROR] Missing restore timestamp for RDS: ${MISSING[*]}"
  exit 1
fi

# ---------------------------------------
# Step 4: Write Artifact
# ---------------------------------------
ARTIFACT_FILE="restore_timestamp.txt"
: > "$ARTIFACT_FILE"

for RDS in "${RDS_INSTANCES[@]}"; do
  RDS=$(echo "$RDS" | xargs)
  echo "${RDS}|${RDS_RESTORE_TIMES[$RDS]}|${RDS_IOPS[$RDS]}" >> "$ARTIFACT_FILE"
done

echo "---------------------------------------"
echo "Restore Timestamp Summary"
echo "---------------------------------------"
printf "%-30s | %-25s | %-10s\n" "RDS Instance" "Restore Timestamp" "IOPS"
echo "---------------------------------------"
for RDS in "${RDS_INSTANCES[@]}"; do
  RDS=$(echo "$RDS" | xargs)
  printf "%-30s | %-25s | %-10s\n" "$RDS" "${RDS_RESTORE_TIMES[$RDS]}" "${RDS_IOPS[$RDS]}"
done
echo "---------------------------------------"
echo "Artifact created: $ARTIFACT_FILE"
cat "$ARTIFACT_FILE"
echo "---------------------------------------"

# --------------------------------------------------------------------------------------
# ------------------------------STAGE-2-------------------------------------------------
# --------------------------------------------------------------------------------------

#!/bin/bash
set -euo pipefail

# Stage 2: Parallel restores with concurrency control, collision checks, retries, and safe aggregation.

echo "======================================"
echo "Stage 2 - Parallel RDS Point-in-Time Restore (resilient)"
echo "======================================"

# Load artifact
ARTIFACT_FILE="${bamboo.build.working.directory}/restore_timestamp.txt"
if [[ ! -f "$ARTIFACT_FILE" ]]; then
  echo "[ERROR] Artifact file not found: $ARTIFACT_FILE"
  exit 1
fi

# Parse artifact lines of form: RDS|timestamp|iops
declare -A RESTORE_TIMES
declare -A IOPS_TICKETS
while IFS='|' read -r RDS_NAME TIMESTAMP IOPS; do
  [[ -z "$RDS_NAME" || -z "$TIMESTAMP" ]] && continue
  RDS_NAME="$(echo "$RDS_NAME" | xargs)"
  RESTORE_TIMES["$RDS_NAME"]="$TIMESTAMP"
  IOPS_TICKETS["$RDS_NAME"]="$IOPS"
done < "$ARTIFACT_FILE"

# Bamboo variables
REGION="${bamboo.AWS_REGION}"
RDS_INSTANCE_NAMES="${bamboo.RDS_INSTANCE_NAMES}"
export AWS_ACCESS_KEY_ID="${bamboo.AWS_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${bamboo.AWS_SECRET_ACCESS_KEY}"
export AWS_DEFAULT_OUTPUT=json

IFS=',' read -r -a DB_ARRAY <<< "$RDS_INSTANCE_NAMES"

# concurrency control
MAX_CONCURRENCY="${bamboo.MAX_CONCURRENCY}"   # optional Bamboo var, default 5
if ! [[ "$MAX_CONCURRENCY" =~ ^[0-9]+$ ]]; then MAX_CONCURRENCY=5; fi
echo "[INFO] Max concurrency: $MAX_CONCURRENCY"

# helpers
aws_retry() {
  local tries=0
  local max=3
  local delay=3
  local cmd=("$@")
  until (( tries >= max )); do
    if "${cmd[@]}"; then
      return 0
    fi
    ((tries++))
    echo "[WARN] Command failed, attempt $tries/$max. Retrying in ${delay}s..."
    sleep $delay
    delay=$((delay * 2))
  done
  echo "[ERROR] Command failed after $max attempts: ${cmd[*]}"
  return 1
}

run_jobs_count() {
  jobs -rp | wc -l
}

# temp dir for per-RDS output
TMPDIR=$(mktemp -d)
RESTORED_ENDPOINTS_FILE="restored_endpoints.txt"
: > "$RESTORED_ENDPOINTS_FILE"

# track failures
FAILURES=0

echo "--------------------------------------"
echo "[INFO] Initiating restores (parallel)..."
echo "--------------------------------------"

for RDS_INSTANCE in "${DB_ARRAY[@]}"; do
  RDS_INSTANCE="$(echo "$RDS_INSTANCE" | xargs)"
  RESTORE_TIMESTAMP="${RESTORE_TIMES[$RDS_INSTANCE]:-}"
  IOPS_TICKET="${IOPS_TICKETS[$RDS_INSTANCE]:-}"

  if [[ -z "$RESTORE_TIMESTAMP" ]]; then
    echo "[WARNING] No timestamp for $RDS_INSTANCE; skipping."
    continue
  fi

  RESTORE_DATE=$(echo "$RESTORE_TIMESTAMP" | cut -d'T' -f1)
  TARGET_DB="Temp-${RDS_INSTANCE}-${RESTORE_DATE}-${IOPS_TICKET}-restored"

  # concurrency control: wait until a slot is free
  while (( $(run_jobs_count) >= MAX_CONCURRENCY )); do
    sleep 5
  done

  (
    set -e
    LOG_PREFIX="[$RDS_INSTANCE]"

    echo "$LOG_PREFIX Fetching source DB config..."
    if ! DB_INFO=$(aws_retry aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$RDS_INSTANCE" --query "DBInstances[0]" --output json); then
      echo "$LOG_PREFIX [ERROR] describe-db-instances failed"
      echo "ERROR" > "${TMPDIR}/${RDS_INSTANCE}.status"
      exit 1
    fi

    INSTANCE_CLASS=$(echo "$DB_INFO" | jq -r '.DBInstanceClass')
    SUBNET_GROUP=$(echo "$DB_INFO" | jq -r '.DBSubnetGroup.DBSubnetGroupName')
    VPC_SG_IDS=$(echo "$DB_INFO" | jq -r '.VpcSecurityGroups[].VpcSecurityGroupId' | paste -sd "," -)
    STORAGE_TYPE=$(echo "$DB_INFO" | jq -r '.StorageType')

    echo "$LOG_PREFIX Checking for existing target DB: $TARGET_DB"
    if aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$TARGET_DB" >/dev/null 2>&1; then
      echo "$LOG_PREFIX Found existing $TARGET_DB — will delete before restore"
      # delete existing target (skip final snapshot), with retry
      aws_retry aws rds delete-db-instance --region "$REGION" --db-instance-identifier "$TARGET_DB" --skip-final-snapshot --delete-automated-backups
      # wait for deletion
      aws_retry aws rds wait db-instance-deleted --region "$REGION" --db-instance-identifier "$TARGET_DB"
      echo "$LOG_PREFIX Existing $TARGET_DB deleted"
    fi

    echo "$LOG_PREFIX Initiating restore to $TARGET_DB with time $RESTORE_TIMESTAMP"
    aws_retry aws rds restore-db-instance-to-point-in-time \
      --region "$REGION" \
      --source-db-instance-identifier "$RDS_INSTANCE" \
      --target-db-instance-identifier "$TARGET_DB" \
      --restore-time "$RESTORE_TIMESTAMP" \
      --no-multi-az \
      --db-instance-class "$INSTANCE_CLASS" \
      --db-subnet-group-name "$SUBNET_GROUP" \
      --vpc-security-group-ids $VPC_SG_IDS \
      --storage-type "$STORAGE_TYPE" \
      --publicly-accessible \
      --tags Key=RestoredBy,Value=BambooPipeline Key=IOPS,Value="$IOPS_TICKET"

    echo "$LOG_PREFIX Restore initiated for $TARGET_DB"

    # wait until available
    echo "$LOG_PREFIX Waiting for $TARGET_DB to become available..."
    aws_retry aws rds wait db-instance-available --region "$REGION" --db-instance-identifier "$TARGET_DB"

    # get endpoint
    ENDPOINT=$(aws_retry aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$TARGET_DB" --query "DBInstances[0].Endpoint.Address" --output text && true)
    # note: aws_retry returns 0 on success, but we need captured endpoint; run without aws_retry for describe to get output
    if ! ENDPOINT=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$TARGET_DB" --query "DBInstances[0].Endpoint.Address" --output text 2>/dev/null); then
      echo "$LOG_PREFIX [WARN] Could not get endpoint for $TARGET_DB"
      echo "ERROR" > "${TMPDIR}/${RDS_INSTANCE}.status"
      exit 1
    fi

    echo "$LOG_PREFIX $TARGET_DB is available — endpoint: $ENDPOINT"
    echo "${RDS_INSTANCE} | ${TARGET_DB} | ${ENDPOINT}" > "${TMPDIR}/${RDS_INSTANCE}.out"
    echo "OK" > "${TMPDIR}/${RDS_INSTANCE}.status"
    exit 0
  ) &

done

# wait for all background restore jobs
wait

# Gather outputs and statuses
for RDS_INSTANCE in "${DB_ARRAY[@]}"; do
  RDS_INSTANCE="$(echo "$RDS_INSTANCE" | xargs)"
  STATUS_FILE="${TMPDIR}/${RDS_INSTANCE}.status"
  OUT_FILE="${TMPDIR}/${RDS_INSTANCE}.out"
  if [[ -f "$STATUS_FILE" ]]; then
    STATUS_CONTENT=$(cat "$STATUS_FILE")
    if [[ "$STATUS_CONTENT" == "OK" ]]; then
      if [[ -f "$OUT_FILE" ]]; then
        cat "$OUT_FILE" >> "$RESTORED_ENDPOINTS_FILE"
      else
        echo "[WARN] Missing output file for $RDS_INSTANCE despite OK status"
        ((FAILURES++))
      fi
    else
      echo "[ERROR] Restore failed for $RDS_INSTANCE"
      ((FAILURES++))
    fi
  else
    echo "[ERROR] No status recorded for $RDS_INSTANCE — treated as failure"
    ((FAILURES++))
  fi
done

# cleanup tmpdir listing
echo "--------------------------------------"
echo "[INFO] Restored endpoints summary:"
cat "$RESTORED_ENDPOINTS_FILE"
echo "--------------------------------------"

# remove tmpdir
rm -rf "$TMPDIR"

if (( FAILURES > 0 )); then
  echo "[ERROR] $FAILURES restores failed. Check logs above."
  exit 1
fi

echo "[SUCCESS] All RDS restores completed successfully."

# --------------------------------------------------------------------------------------
# ------------------------------STAGE-3-------------------------------------------------
# --------------------------------------------------------------------------------------

#!/bin/bash
set -euo pipefail

echo "======================================"
echo "Stage 3 - Data Anonymization via Bastion Tunnel"
echo "======================================"

AWS_REGION="${bamboo_AWS_REGION}"
ENDPOINT_FILE="${bamboo.build.working.directory}/restored_endpoints.txt"
SCRIPT_DIR="${bamboo.build.working.directory}/anonymization-scripts/anonymization-scripts"

DB_USERNAME="${bamboo_DB_USER}"
SECRET_NAME="${bamboo_DB_SECRET_NAME}"
IFS=',' read -r -a DB_LIST <<< "${bamboo_DB_NAMES}"

# Bastion details
BASTION_HOST="${bamboo_BASTION_HOST}"
BASTION_USER="${bamboo_BASTION_SSH_USER}"
BASTION_KEY="${bamboo_BASTION_SSH_KEY_PATH}"
LOCAL_TUNNEL_PORT=3307

# Optional wait tuning
WAIT_MAX_ATTEMPTS="${bamboo_MYSQL_WAIT_ATTEMPTS:-60}"  # ~10 min at 10s
WAIT_SLEEP_SECONDS="${bamboo_MYSQL_WAIT_SLEEP:-10}"

# AWS creds
export AWS_ACCESS_KEY_ID="${bamboo_AWS_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${bamboo_AWS_SECRET_ACCESS_KEY}"
export AWS_DEFAULT_OUTPUT=json

if [[ -z "${BASTION_HOST:-}" || -z "${BASTION_USER:-}" || -z "${BASTION_KEY:-}" ]]; then
  echo "[ERROR] Missing Bastion vars: BASTION_HOST / BASTION_SSH_USER / BASTION_SSH_KEY_PATH"
  exit 1
fi

if [[ ! -f "$ENDPOINT_FILE" ]]; then
  echo "[ERROR] Missing restored_endpoints.txt; run Stage-2 first."
  exit 1
fi

if [[ ! -d "$SCRIPT_DIR" ]]; then
  echo "[ERROR] Missing anonymization-scripts directory at: $SCRIPT_DIR"
  exit 1
fi

chmod 400 "$BASTION_KEY" || true

echo "[INFO] Fetching DB password from Secrets Manager..."
DB_PASSWORD="$(aws secretsmanager get-secret-value \
  --region "$AWS_REGION" \
  --secret-id "$SECRET_NAME" \
  --query SecretString \
  --output text)"
if [[ -z "$DB_PASSWORD" ]]; then
  echo "[ERROR] Could not retrieve DB password."
  exit 1
fi

# Helper: wait until mysql is ready on the local tunnel port
wait_for_mysql() {
  local host="$1"    # always 127.0.0.1
  local port="$2"    # tunnel port
  for ((i=1; i<=WAIT_MAX_ATTEMPTS; i++)); do
    if mysql -h "$host" -P "$port" -u "$DB_USERNAME" -p"$DB_PASSWORD" -e "SELECT 1;" >/dev/null 2>&1; then
      echo "[INFO] MySQL is ready on $host:$port"
      return 0
    fi
    echo "[WAIT] MySQL not ready on $host:$port (attempt $i/$WAIT_MAX_ATTEMPTS)"
    sleep "$WAIT_SLEEP_SECONDS"
  done
  echo "[ERROR] MySQL did not become ready on $host:$port"
  return 1
}

echo "--------------------------------------"
cat "$ENDPOINT_FILE"
echo "--------------------------------------"

while IFS='|' read -r SOURCE_RDS RESTORED_RDS ENDPOINT; do
  RESTORED_RDS="$(echo "$RESTORED_RDS" | xargs)"
  ENDPOINT="$(echo "$ENDPOINT" | xargs)"
  [[ -z "$RESTORED_RDS" || -z "$ENDPOINT" ]] && continue

  echo ""
  echo "--------------------------------------"
  echo "[INFO] Target (restored): $RESTORED_RDS"
  echo "Endpoint: $ENDPOINT"
  echo "--------------------------------------"

  # Start tunnel: local:3307 -> ENDPOINT:3306 via bastion
  echo "[INFO] Establishing SSH tunnel via bastion: ${BASTION_USER}@${BASTION_HOST}"
  # Free the local port if occupied
  if lsof -iTCP:${LOCAL_TUNNEL_PORT} -sTCP:LISTEN -Pn >/dev/null 2>&1; then
    echo "[INFO] Local port ${LOCAL_TUNNEL_PORT} in use; killing existing listener."
    fuser -k "${LOCAL_TUNNEL_PORT}/tcp" || true
    sleep 2
  fi
  ssh -o StrictHostKeyChecking=no -i "$BASTION_KEY" -N -L ${LOCAL_TUNNEL_PORT}:${ENDPOINT}:3306 ${BASTION_USER}@${BASTION_HOST} &
  TUNNEL_PID=$!
  sleep 3

  # Confirm tunnel is up
  if ! ps -p $TUNNEL_PID >/dev/null 2>&1; then
    echo "[ERROR] Failed to establish SSH tunnel (PID not running)."
    exit 1
  fi

  # Wait for MySQL on the tunnel
  if ! wait_for_mysql "127.0.0.1" "${LOCAL_TUNNEL_PORT}"; then
    echo "[ERROR] Skipping $RESTORED_RDS due to MySQL readiness timeout."
    kill $TUNNEL_PID || true
    continue
  fi

  # Process DBs
  for DB in "${DB_LIST[@]}"; do
    DB="$(echo "$DB" | xargs)"
    echo "[INFO] Checking DB '$DB' on $RESTORED_RDS via tunnel..."
    DB_EXISTS=$(mysql -h 127.0.0.1 -P ${LOCAL_TUNNEL_PORT} -u "$DB_USERNAME" -p"$DB_PASSWORD" -Nse "SHOW DATABASES LIKE '$DB';" || true)

    if [[ "$DB_EXISTS" != "$DB" ]]; then
      echo "[SKIP] DB '$DB' not present on $RESTORED_RDS"
      continue
    fi

    SCRIPT_PATH="$SCRIPT_DIR/${DB}.sql"
    if [[ ! -f "$SCRIPT_PATH" ]]; then
      echo "[SKIP] No anonymization script found for '$DB' at $SCRIPT_PATH"
      continue
    fi

    echo "[RUN] Executing anonymization for '$DB' using: $SCRIPT_PATH"
    mysql -h 127.0.0.1 -P ${LOCAL_TUNNEL_PORT} -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB" < "$SCRIPT_PATH"

    # Optional verification: if script name equals table name, try a count
    TABLE_CANDIDATE="$(basename "$SCRIPT_PATH" .sql)"
    if [[ -n "$TABLE_CANDIDATE" ]]; then
      COUNT_OUT=$(mysql -h 127.0.0.1 -P ${LOCAL_TUNNEL_PORT} -u "$DB_USERNAME" -p"$DB_PASSWORD" -Nse "SELECT COUNT(*) FROM \`${DB}\`.\`${TABLE_CANDIDATE}\`;" 2>/dev/null || echo "")
      [[ -n "$COUNT_OUT" ]] && echo "[VERIFY] Rows in ${DB}.${TABLE_CANDIDATE}: ${COUNT_OUT}"
    fi

    echo "[SUCCESS] Anonymization completed for '$DB' on '$RESTORED_RDS'"
  done

  echo "[INFO] Closing tunnel PID $TUNNEL_PID"
  kill $TUNNEL_PID || true
  sleep 1

done < "$ENDPOINT_FILE"

echo "--------------------------------------"
echo "[SUCCESS] Stage 3 Completed Successfully"
echo "--------------------------------------"

# --------------------------------------------------------------------------------------
# ------------------------------STAGE-4-------------------------------------------------
# --------------------------------------------------------------------------------------

#!/usr/bin/env bash
set -euo pipefail

echo "======================================"
echo "Stage 4 - Backup Restored DBs to S3 (via Bastion Tunnel)"
echo "======================================"

RESTORED_ENDPOINTS_FILE="${bamboo.build.working.directory}/restored_endpoints.txt"
S3_BUCKET="${bamboo.S3_BUCKET}"
AWS_REGION="${bamboo.AWS_REGION}"

IFS=',' read -r -a DB_LIST <<< "${bamboo.DB_NAMES}"

# ==========================
# 1) CLEANUP OLD DBs IN NON-PROD
# ==========================
echo "[INFO] Cleaning old DB schemas in Non-Prod..."

export AWS_ACCESS_KEY_ID="${bamboo.NONPROD_AWS_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${bamboo.NONPROD_AWS_SECRET_ACCESS_KEY}"

NONPROD_RDS_IDENTIFIER="${bamboo.NONPROD_RDS_IDENTIFIER}"
NONPROD_BASTION_HOST="${bamboo.NONPROD_BASTION_HOST}"
NONPROD_BASTION_SSH_USER="${bamboo.NONPROD_BASTION_SSH_USER}"
NONPROD_BASTION_SSH_KEY_PATH="${bamboo.NONPROD_BASTION_SSH_KEY_PATH}"
NONPROD_DB_SECRET_NAME="${bamboo.NONPROD_DB_SECRET_NAME}"
NONPROD_DB_USERNAME="${bamboo.NONPROD_DB_USERNAME}"
NONPROD_LOCAL_PORT=4407

echo "[INFO] Retrieving Non-Prod DB endpoint..."
NONPROD_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$NONPROD_RDS_IDENTIFIER" \
  --region "$AWS_REGION" \
  --query "DBInstances[0].Endpoint.Address" \
  --output text)

echo "[INFO] Fetching Non-Prod DB password..."
NONPROD_DB_PASSWORD=$(aws secretsmanager get-secret-value \
  --region "$AWS_REGION" \
  --secret-id "$NONPROD_DB_SECRET_NAME" \
  --query SecretString \
  --output text)

echo "[INFO] Establishing Non-Prod SSH tunnel..."
ssh -f -N -o StrictHostKeyChecking=no \
  -i "$NONPROD_BASTION_SSH_KEY_PATH" \
  -L ${NONPROD_LOCAL_PORT}:${NONPROD_ENDPOINT}:3306 \
  ${NONPROD_BASTION_SSH_USER}@${NONPROD_BASTION_HOST}

sleep 3

for DB in "${DB_LIST[@]}"; do
  DB="$(echo "$DB" | xargs)"
  echo "[CLEANUP] Dropping old database if exists → $DB"
  mysql -h 127.0.0.1 -P ${NONPROD_LOCAL_PORT} -u "$NONPROD_DB_USERNAME" -p"$NONPROD_DB_PASSWORD" \
    -e "DROP DATABASE IF EXISTS \`${DB}\`;" || true
done

echo "[INFO] Closing Non-Prod tunnel..."
pkill -f "${NONPROD_LOCAL_PORT}:${NONPROD_ENDPOINT}:3306" || true

# ==========================
# 2) SWITCH TO PROD CREDS FOR BACKUP
# ==========================
echo "[INFO] Switching to PROD account for backup upload..."

export AWS_ACCESS_KEY_ID="${bamboo.AWS_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${bamboo.AWS_SECRET_ACCESS_KEY}"
unset AWS_SESSION_TOKEN || true

DB_USERNAME="${bamboo.DB_USER}"
SECRET_NAME="${bamboo.DB_SECRET_NAME}"

echo "[INFO] Fetching PROD DB password..."
DB_PASSWORD=$(aws secretsmanager get-secret-value \
  --region "$AWS_REGION" \
  --secret-id "$SECRET_NAME" \
  --query SecretString \
  --output text)

LOCAL_PORT=3307
BASTION_HOST="${bamboo.BASTION_HOST}"
BASTION_USER="${bamboo.BASTION_SSH_USER}"
BASTION_KEY_PATH="${bamboo.BASTION_SSH_KEY_PATH}"

[[ ! -f "$RESTORED_ENDPOINTS_FILE" ]] && { echo "[ERROR] restored_endpoints.txt not found."; exit 1; }

# ==========================
# 3) BACKUP EACH RESTORED INSTANCE
# ==========================
while IFS='|' read -r _ RESTORED_RDS ENDPOINT; do
  RESTORED_RDS="$(echo "$RESTORED_RDS" | xargs)"
  ENDPOINT="$(echo "$ENDPOINT" | xargs)"
  [[ -z "$RESTORED_RDS" || -z "$ENDPOINT" ]] && continue

  echo "--------------------------------------"
  echo "[INFO] Processing instance: $RESTORED_RDS"
  echo "[INFO] Endpoint: $ENDPOINT"
  echo "--------------------------------------"

  ssh -f -N -o StrictHostKeyChecking=no \
     -i "$BASTION_KEY_PATH" \
     -L ${LOCAL_PORT}:${ENDPOINT}:3306 \
     ${BASTION_USER}@${BASTION_HOST}
  sleep 3

  for DB in "${DB_LIST[@]}"; do
    DB="$(echo "$DB" | xargs)"

    DB_EXISTS=$(mysql -h 127.0.0.1 -P ${LOCAL_PORT} -u "$DB_USERNAME" -p"$DB_PASSWORD" \
      -se "SHOW DATABASES LIKE '$DB';" || true)

    [[ "$DB_EXISTS" != "$DB" ]] && { echo "[SKIP] $DB not found on $RESTORED_RDS"; continue; }

    BACKUP_FILE="${DB}.sql.gz"
    S3_PATH="s3://${S3_BUCKET}/restores/${RESTORED_RDS}/${BACKUP_FILE}"

    echo "[DUMP] Creating backup of $DB..."
    mysqldump --single-transaction --set-gtid-purged=OFF \
      -h 127.0.0.1 -P ${LOCAL_PORT} -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB" | gzip > "$BACKUP_FILE"

    echo "[UPLOAD] → $S3_PATH"
    aws s3 cp "$BACKUP_FILE" "$S3_PATH" --region "$AWS_REGION" --sse AES256

    rm -f "$BACKUP_FILE"
  done

  echo "[INFO] Closing PROD SSH tunnel..."
  pkill -f "${LOCAL_PORT}:${ENDPOINT}:3306" || true

done < "$RESTORED_ENDPOINTS_FILE"

echo "======================================"
echo "[SUCCESS] Stage 4 Completed Successfully"
echo "======================================"

# --------------------------------------------------------------------------------------
# ------------------------------STAGE-5-------------------------------------------------
# --------------------------------------------------------------------------------------

#!/bin/bash
set -euo pipefail

echo "======================================"
echo "Stage 5 - Cross-Account Restore to Non-Prod"
echo "======================================"

AWS_REGION="${bamboo.AWS_REGION}"
S3_BUCKET="${bamboo.S3_BUCKET}"
TARGET_RDS_IDENTIFIER="${bamboo.NONPROD_RDS_IDENTIFIER}"

IFS=',' read -r -a DB_LIST <<< "${bamboo.DB_NAMES}"

export AWS_ACCESS_KEY_ID="${bamboo.NONPROD_AWS_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${bamboo.NONPROD_AWS_SECRET_ACCESS_KEY}"

RESTORE_ROLE_ARN="arn:aws:iam::${bamboo.NONPROD_ACCOUNT_ID}:role/NonProd-RDS-Restore-Role"

echo "[INFO] Assuming restore role: $RESTORE_ROLE_ARN"
CREDS=$(aws sts assume-role \
  --role-arn "$RESTORE_ROLE_ARN" \
  --role-session-name RestoreSession \
  --region "$AWS_REGION" \
  --output json)

export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r '.Credentials.SessionToken')

aws sts get-caller-identity --output json

TARGET_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$TARGET_RDS_IDENTIFIER" \
  --region "$AWS_REGION" \
  --query "DBInstances[0].Endpoint.Address" \
  --output text)

echo "[INFO] Non-prod RDS Endpoint: $TARGET_ENDPOINT"

NONPROD_DB_SECRET_NAME="${bamboo.NONPROD_DB_SECRET_NAME}"
NONPROD_DB_USERNAME="${bamboo.NONPROD_DB_USERNAME}"

DB_PASSWORD=$(aws secretsmanager get-secret-value \
  --region "$AWS_REGION" \
  --secret-id "$NONPROD_DB_SECRET_NAME" \
  --query SecretString \
  --output text)

NONPROD_BASTION_HOST="${bamboo.NONPROD_BASTION_HOST}"
NONPROD_BASTION_USER="${bamboo.NONPROD_BASTION_SSH_USER}"
NONPROD_BASTION_KEY="${bamboo.NONPROD_BASTION_SSH_KEY_PATH}"
LOCAL_PORT=3317

echo "[INFO] Establishing SSH Tunnel..."
ssh -o StrictHostKeyChecking=no -i "$NONPROD_BASTION_KEY" -N \
  -L ${LOCAL_PORT}:${TARGET_ENDPOINT}:3306 \
  ${NONPROD_BASTION_USER}@${NONPROD_BASTION_HOST} &
TUNNEL_PID=$!
sleep 5

echo "[INFO] Checking DB connectivity..."
mysql -h 127.0.0.1 -P ${LOCAL_PORT} -u "$NONPROD_DB_USERNAME" -p"$DB_PASSWORD" -e "SELECT 1;" >/dev/null
echo "[SUCCESS] Database reachable over tunnel."

for DB in "${DB_LIST[@]}"; do
  DB="$(echo "$DB" | xargs)"
  echo "--------------------------------------"
  echo "[INFO] Restoring DB: $DB"

  # ✅ Correct listing (No double restores)
  LATEST_FILE=$(aws s3 ls s3://${S3_BUCKET}/restores/ --recursive --region "$AWS_REGION" \
    | grep "/${DB}.sql.gz" | sort | tail -n 1 | awk '{print $4}')

  if [[ -z "$LATEST_FILE" ]]; then
    echo "[ERROR] No backup found for '$DB'"
    continue
  fi

  S3_URI="s3://${S3_BUCKET}/${LATEST_FILE}"
  echo "[INFO] Using backup: $S3_URI"

  mysql -h 127.0.0.1 -P ${LOCAL_PORT} -u "$NONPROD_DB_USERNAME" -p"$DB_PASSWORD" \
    -e "DROP DATABASE IF EXISTS \`${DB}\`; CREATE DATABASE \`${DB}\`;"

  echo "[INFO] Importing dump (no pv)..."
  aws s3 cp "$S3_URI" - --region "$AWS_REGION" | gunzip \
    | mysql -h 127.0.0.1 -P ${LOCAL_PORT} -u "$NONPROD_DB_USERNAME" -p"$DB_PASSWORD" "$DB"

  echo "[SUCCESS] Restore completed: $DB"
done

kill $TUNNEL_PID || true
echo "--------------------------------------"
echo "[SUCCESS] Stage 5 Completed Successfully"
echo "--------------------------------------"

# --------------------------------------------------------------------------------------
# ------------------------------STAGE-6-------------------------------------------------
# --------------------------------------------------------------------------------------

#!/usr/bin/env bash
set -euo pipefail

echo "======================================"
echo "Stage 6 - Verify Restored Databases & Records in Non-Prod"
echo "======================================"

AWS_REGION="${bamboo.AWS_REGION}"
IFS=',' read -r -a DB_LIST <<< "${bamboo.DB_NAMES}"

# Non-prod Access
export AWS_ACCESS_KEY_ID="${bamboo.NONPROD_AWS_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${bamboo.NONPROD_AWS_SECRET_ACCESS_KEY}"

NONPROD_RDS_IDENTIFIER="${bamboo.NONPROD_RDS_IDENTIFIER}"
NONPROD_DB_SECRET_NAME="${bamboo.NONPROD_DB_SECRET_NAME}"
NONPROD_DB_USERNAME="${bamboo.NONPROD_DB_USERNAME}"

NONPROD_BASTION_HOST="${bamboo.NONPROD_BASTION_HOST}"
NONPROD_BASTION_USER="${bamboo.NONPROD_BASTION_SSH_USER}"
NONPROD_BASTION_KEY="${bamboo.NONPROD_BASTION_SSH_KEY_PATH}"

LOCAL_PORT=3321   # fixed stable local tunnel port

echo "[INFO] Resolving Non-Prod RDS endpoint..."
TARGET_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$NONPROD_RDS_IDENTIFIER" \
  --region "$AWS_REGION" \
  --query "DBInstances[0].Endpoint.Address" \
  --output text)

echo "[INFO] Fetching DB password..."
DB_PASSWORD=$(aws secretsmanager get-secret-value \
  --region "$AWS_REGION" \
  --secret-id "$NONPROD_DB_SECRET_NAME" \
  --query SecretString \
  --output text)

echo "[INFO] Establishing SSH Tunnel..."
ssh -o StrictHostKeyChecking=no -f -N \
  -i "$NONPROD_BASTION_KEY" \
  -L ${LOCAL_PORT}:${TARGET_ENDPOINT}:3306 \
  ${NONPROD_BASTION_USER}@${NONPROD_BASTION_HOST}

sleep 4

for DB in "${DB_LIST[@]}"; do
  DB=$(echo "$DB" | xargs)

  echo "--------------------------------------"
  echo "[CHECK] Validating database: $DB"

  EXISTS=$(mysql -h 127.0.0.1 -P ${LOCAL_PORT} -u "$NONPROD_DB_USERNAME" -p"$DB_PASSWORD" \
      -se "SHOW DATABASES LIKE '${DB}';" || true)

  if [[ "$EXISTS" != "$DB" ]]; then
    echo "[FAIL] Database '$DB' NOT found "
    FAILED=true
    continue
  fi

  echo "[OK] Database '$DB' exists "
  echo "[INFO] Fetching record counts..."

  TABLES=$(mysql -h 127.0.0.1 -P ${LOCAL_PORT} -u "$NONPROD_DB_USERNAME" -p"$DB_PASSWORD" \
      -se "SHOW TABLES IN \`${DB}\`;" || true)

  if [[ -z "$TABLES" ]]; then
    echo "[WARN] No tables found in $DB (possible empty restore) ️"
    continue
  fi

  for TABLE in $TABLES; do
    COUNT=$(mysql -h 127.0.0.1 -P ${LOCAL_PORT} -u "$NONPROD_DB_USERNAME" -p"$DB_PASSWORD" \
      -se "SELECT COUNT(*) FROM \`${DB}\`.\`${TABLE}\`;")

    printf "  - %-40s : %s rows\n" "$TABLE" "$COUNT"
  done

done

echo "[INFO] Closing tunnel..."
pkill -f "${LOCAL_PORT}:${TARGET_ENDPOINT}:3306" || true

echo "======================================"

if [[ "${FAILED:-false}" == true ]]; then
  echo "[ERROR] One or more databases failed validation."
  exit 1
else
  echo "[SUCCESS] All databases & record counts verified "
fi

echo "======================================"
echo "[SUCCESS] Stage 6 Completed"
echo "======================================"

# --------------------------------------------------------------------------------------
# ------------------------------STAGE-7-------------------------------------------------
# --------------------------------------------------------------------------------------

#!/usr/bin/env bash
set -euo pipefail

echo "======================================"
echo "Stage 7 - Cleanup Temporary RDS Instances"
echo "======================================"

AWS_REGION="${bamboo.AWS_REGION}"
RESTORED_ENDPOINTS_FILE="${bamboo.build.working.directory}/restored_endpoints.txt"

# Use PROD credentials (where temporary RDS were created)
export AWS_ACCESS_KEY_ID="${bamboo.AWS_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${bamboo.AWS_SECRET_ACCESS_KEY}"
unset AWS_SESSION_TOKEN || true

if [[ ! -f "$RESTORED_ENDPOINTS_FILE" ]]; then
  echo "[WARN] restored_endpoints.txt not found → Skipping RDS cleanup."
  exit 0
fi

while IFS='|' read -r _ TEMP_RDS _; do
  TEMP_RDS="$(echo "$TEMP_RDS" | xargs)"
  [[ -z "$TEMP_RDS" ]] && continue

  echo "--------------------------------------"
  echo "[DELETE] Requesting deletion of temporary RDS → $TEMP_RDS"
  echo "--------------------------------------"

  # Check existence before delete
  if ! aws rds describe-db-instances \
        --db-instance-identifier "$TEMP_RDS" \
        --region "$AWS_REGION" >/dev/null 2>&1; then
     echo "[INFO] $TEMP_RDS does not exist → Skipping."
     continue
  fi

  aws rds delete-db-instance \
    --db-instance-identifier "$TEMP_RDS" \
    --skip-final-snapshot \
    --region "$AWS_REGION" \
    --no-cli-pager

  echo "[WAIT] Waiting for RDS deletion to complete... (this may take 5–20 minutes)"
  
  # Progress loop
  while aws rds describe-db-instances \
          --db-instance-identifier "$TEMP_RDS" \
          --region "$AWS_REGION" >/dev/null 2>&1; do
      echo "[WAIT] Still deleting $TEMP_RDS ... checking again in 45s"
      sleep 45
  done

  echo "[SUCCESS] Temporary RDS deleted → $TEMP_RDS"
done < "$RESTORED_ENDPOINTS_FILE"

echo "======================================"
echo "[SUCCESS] Stage 7 Completed Successfully"
echo "======================================"
# -----------------------------------------------------------------------------
# ---------------------SCRIPT COMPLETION---------------------------------------
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# ----------------------S3 BUCKET POLICY---------------------------------------
# -----------------------------------------------------------------------------

{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "RequireTLS",
            "Effect": "Deny",
            "Principal": "*",
            "Action": "s3:*",
            "Resource": [
                "arn:aws:s3:::backup-bucket-temp-rds-1",
                "arn:aws:s3:::backup-bucket-temp-rds-1/*"
            ],
            "Condition": {
                "Bool": {
                    "aws:SecureTransport": "false"
                }
            }
        },
        {
            "Sid": "AllowRestoreRoleList",
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::891377400738:role/NonProd-RDS-Restore-Role"
            },
            "Action": "s3:ListBucket",
            "Resource": "arn:aws:s3:::backup-bucket-temp-rds-1",
            "Condition": {
                "StringLike": {
                    "s3:prefix": "restores/*"
                }
            }
        },
        {
            "Sid": "AllowRestoreRoleObjectAccess",
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::891377400738:role/NonProd-RDS-Restore-Role"
            },
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListMultipartUploadParts",
                "s3:AbortMultipartUpload"
            ],
            "Resource": "arn:aws:s3:::backup-bucket-temp-rds-1/restores/*"
        }
    ]
}

#-------------------------------------------------------------------------------
#-----------------------S3 POLICY COMPLETION------------------------------------
#-------------------------------------------------------------------------------
