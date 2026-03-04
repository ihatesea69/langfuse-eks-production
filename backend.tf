# =============================================================================
# Terraform Backend Configuration
# =============================================================================
# Stores Terraform state in S3 with DynamoDB locking for team collaboration.
#
# Before running `terraform init`, create the backend infrastructure:
#   PowerShell: .\scripts\bootstrap-backend.ps1
#   Bash:       ./scripts/bootstrap-backend.sh
#
# Then replace <ACCOUNT_ID> below with your AWS account ID and run:
#   terraform init
# =============================================================================

terraform {
  backend "s3" {
    bucket         = "langfuse-terraform-state-<ACCOUNT_ID>"
    key            = "langfuse/eks/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "langfuse-terraform-locks"
    encrypt        = true
  }
}
