# =============================================================================
# Bootstrap Script: Create S3 Backend + DynamoDB Lock Table
# =============================================================================
# Run this ONCE before `terraform init` to create the backend infrastructure.
#
# Usage:
#   .\scripts\bootstrap-backend.ps1
#   .\scripts\bootstrap-backend.ps1 -Region us-west-2
# =============================================================================

param(
    [string]$Region = "us-east-1"
)

# Auto-detect AWS Account ID from CLI
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Langfuse Terraform Backend Bootstrap" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Detecting AWS Account ID..." -ForegroundColor Yellow
$AccountId = (aws sts get-caller-identity --query "Account" --output text 2>$null)

if (-not $AccountId -or $LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Could not get AWS Account ID. Make sure AWS CLI is configured and authenticated." -ForegroundColor Red
    Write-Host "  Run: aws configure  or  aws sso login" -ForegroundColor Red
    exit 1
}

Write-Host "  AWS Account ID: $AccountId" -ForegroundColor Green

$BucketName = "langfuse-terraform-state-$AccountId"
$TableName  = "langfuse-terraform-locks"

# --- Step 1: Create S3 Bucket ---
Write-Host "[1/4] Creating S3 bucket: $BucketName ..." -ForegroundColor Yellow
aws s3api create-bucket `
    --bucket $BucketName `
    --region $Region 2>$null

if ($LASTEXITCODE -ne 0) {
    Write-Host "  Bucket may already exist, continuing..." -ForegroundColor DarkYellow
}

# --- Step 2: Enable Versioning ---
Write-Host "[2/4] Enabling versioning on bucket..." -ForegroundColor Yellow
aws s3api put-bucket-versioning `
    --bucket $BucketName `
    --versioning-configuration Status=Enabled

# --- Step 3: Enable Encryption ---
Write-Host "[3/4] Enabling server-side encryption..." -ForegroundColor Yellow
aws s3api put-bucket-encryption `
    --bucket $BucketName `
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

# --- Step 4: Block Public Access ---
Write-Host "[3.5/4] Blocking public access on bucket..." -ForegroundColor Yellow
aws s3api put-public-access-block `
    --bucket $BucketName `
    --public-access-block-configuration '{
        "BlockPublicAcls": true,
        "IgnorePublicAcls": true,
        "BlockPublicPolicy": true,
        "RestrictPublicBuckets": true
    }'

# --- Step 5: Create DynamoDB Table ---
Write-Host "[4/4] Creating DynamoDB table: $TableName ..." -ForegroundColor Yellow
aws dynamodb create-table `
    --table-name $TableName `
    --attribute-definitions AttributeName=LockID,AttributeType=S `
    --key-schema AttributeName=LockID,KeyType=HASH `
    --billing-mode PAY_PER_REQUEST `
    --region $Region 2>$null

if ($LASTEXITCODE -ne 0) {
    Write-Host "  Table may already exist, continuing..." -ForegroundColor DarkYellow
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host " Bootstrap Complete!" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor White
Write-Host "  1. Update 'backend.tf' bucket name to: $BucketName" -ForegroundColor White
Write-Host "  2. Run: terraform init" -ForegroundColor White
Write-Host "  3. Run: terraform plan" -ForegroundColor White
Write-Host ""
