#!/bin/bash
# Usage: ./deploy.sh "<project_folder>"
# Example: ./deploy.sh "RDS-Setup-Prod"

set -e

PROJECT_DIR=$1

if [ -z "$PROJECT_DIR" ]; then
  echo "❌ Please provide the Terraform project folder."
  exit 1
fi

# Switch to the project directory
echo "📁 Switching to Terraform project folder: $PROJECT_DIR"
cd "$PROJECT_DIR" || { echo "❌ Directory not found: $PROJECT_DIR"; exit 1; }

# Deploy Terraform
echo "🚀 Starting Terraform deployment in $(pwd)..."
terraform init -input=false
terraform validate
terraform plan -out=tfplan -input=false
terraform apply -auto-approve tfplan

echo "✅ Deployment complete!"
terraform output
