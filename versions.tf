terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.79.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }

    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }

    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}

# =============================================================================
# Provider Configuration
# =============================================================================

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = "Langfuse"
      ManagedBy = "Terraform"
    }
  }
}

# Kubernetes provider -- connects to the EKS cluster after creation
provider "kubernetes" {
  host                   = aws_eks_cluster.langfuse.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.langfuse.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.langfuse.name, "--region", "us-east-1"]
  }
}

# Helm provider -- uses same EKS cluster connection
provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.langfuse.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.langfuse.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.langfuse.name, "--region", "us-east-1"]
    }
  }
}
