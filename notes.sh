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


# Stage-2

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