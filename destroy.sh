#!/bin/bash
# Usage: ./destroy.sh "<project_folder>"
# Example: ./destroy.sh "RDS-Setup-Prod"

set -e

PROJECT_DIR=$1

if [ -z "$PROJECT_DIR" ]; then
  echo "❌ Please provide the Terraform project folder."
  exit 1
fi

# Switch to the project directory
echo "📁 Switching to Terraform project folder: $PROJECT_DIR"
cd "$PROJECT_DIR" || { echo "❌ Directory not found: $PROJECT_DIR"; exit 1; }

# Destroy Terraform resources
echo "💣 Destroying Terraform resources in $(pwd)..."
terraform destroy -auto-approve
echo "🧹 Cleanup complete!"
