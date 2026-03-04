#!/usr/bin/env bash
# =============================================================================
# Bootstrap Script: Create S3 Backend + DynamoDB Lock Table
# =============================================================================
# Run this ONCE before `terraform init` to create the backend infrastructure.
#
# Usage:
#   ./scripts/bootstrap-backend.sh
#   ./scripts/bootstrap-backend.sh --region us-west-2
# =============================================================================

set -euo pipefail

REGION="${1:-us-east-1}"

echo "============================================="
echo " Langfuse Terraform Backend Bootstrap"
echo "============================================="
echo ""

echo "Detecting AWS Account ID..."
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null)

if [ -z "$ACCOUNT_ID" ]; then
  echo "ERROR: Could not get AWS Account ID."
  echo "  Run: aws configure  or  aws sso login"
  exit 1
fi

echo "  AWS Account ID: $ACCOUNT_ID"

BUCKET_NAME="langfuse-terraform-state-${ACCOUNT_ID}"
TABLE_NAME="langfuse-terraform-locks"

echo ""
echo "[1/4] Creating S3 bucket: ${BUCKET_NAME} ..."
if [ "$REGION" = "us-east-1" ]; then
  aws s3api create-bucket \
    --bucket "$BUCKET_NAME" \
    --region "$REGION" 2>/dev/null || echo "  Bucket may already exist, continuing..."
else
  aws s3api create-bucket \
    --bucket "$BUCKET_NAME" \
    --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION" 2>/dev/null || echo "  Bucket may already exist, continuing..."
fi

echo "[2/4] Enabling versioning on bucket..."
aws s3api put-bucket-versioning \
  --bucket "$BUCKET_NAME" \
  --versioning-configuration Status=Enabled

echo "[3/4] Enabling server-side encryption..."
aws s3api put-bucket-encryption \
  --bucket "$BUCKET_NAME" \
  --server-side-encryption-configuration '{
    "Rules": [
      {
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "aws:kms"
        },
        "BucketKeyEnabled": true
      }
    ]
  }'

echo "      Blocking public access on bucket..."
aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration '{
    "BlockPublicAcls": true,
    "IgnorePublicAcls": true,
    "BlockPublicPolicy": true,
    "RestrictPublicBuckets": true
  }'

echo "[4/4] Creating DynamoDB table: ${TABLE_NAME} ..."
aws dynamodb create-table \
  --table-name "$TABLE_NAME" \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region "$REGION" 2>/dev/null || echo "  Table may already exist, continuing..."

echo ""
echo "============================================="
echo " Bootstrap Complete!"
echo "============================================="
echo ""
echo "Next steps:"
echo "  1. Update backend.tf bucket name to: ${BUCKET_NAME}"
echo "  2. Run: terraform init"
echo "  3. Run: terraform plan"
echo ""
