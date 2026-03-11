data "aws_eks_cluster_auth" "langfuse" {
  name = aws_eks_cluster.langfuse.name
}

resource "aws_eks_cluster" "langfuse" {
  name     = var.name
  role_arn = aws_iam_role.eks.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = local.private_subnets
    endpoint_private_access = true
    endpoint_public_access  = true
    security_group_ids      = [aws_security_group.eks.id]
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  tags = {
    Name = local.tag_name
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_service_policy,
    aws_cloudwatch_log_group.eks
  ]
}

# Enable IRSA
resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.langfuse.identity[0].oidc[0].issuer

  tags = {
    Name = local.tag_name
  }
}

# Get EKS OIDC certificate
data "tls_certificate" "eks" {
  url = aws_eks_cluster.langfuse.identity[0].oidc[0].issuer
}

# Fargate Profile Role
resource "aws_iam_role" "fargate" {
  name = "${var.name}-fargate"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks-fargate-pods.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${local.tag_name} Fargate"
  }
}

resource "aws_iam_role_policy_attachment" "fargate_pod_execution_role_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
  role       = aws_iam_role.fargate.name
}

# Fargate Profiles for all configured namespaces
resource "aws_eks_fargate_profile" "namespaces" {
  for_each = toset(var.fargate_profile_namespaces)

  cluster_name           = aws_eks_cluster.langfuse.name
  fargate_profile_name   = "${var.name}-${each.value}"
  pod_execution_role_arn = aws_iam_role.fargate.arn
  subnet_ids             = local.private_subnets

  selector {
    namespace = each.value
  }

  tags = {
    Name = local.tag_name
  }
}

resource "aws_security_group" "eks" {
  name        = "${var.name}-eks"
  description = "Security group for Langfuse EKS cluster"
  vpc_id      = local.vpc_id

  tags = {
    Name = "${local.tag_name} EKS"
  }
}

resource "aws_security_group_rule" "eks_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.eks.id
}

resource "aws_security_group_rule" "eks_vpc" {
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
  cidr_blocks       = [local.vpc_cidr_block]
  security_group_id = aws_security_group.eks.id
}

resource "aws_iam_role" "eks" {
  name = "${var.name}-eks"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${local.tag_name} EKS"
  }
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks.name
}

resource "aws_iam_role_policy_attachment" "eks_service_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
  role       = aws_iam_role.eks.name
}

resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = 30
}

# =============================================================================
# CoreDNS Fargate Scheduling Fix
# =============================================================================
# Current EKS guidance still requires CoreDNS to be restarted onto Fargate, and
# recent platform versions can also require the Fargate taint toleration to be
# present. This patch removes the legacy EC2-only annotation and ensures the
# toleration exists before restarting CoreDNS.
resource "terraform_data" "coredns_fargate_patch" {
  # Re-run only when the EKS cluster or Fargate profiles change
  triggers_replace = [
    aws_eks_cluster.langfuse.id,
    join(",", [for k, v in aws_eks_fargate_profile.namespaces : v.id]),
  ]

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-Command"]
    command     = <<-EOT
      $ErrorActionPreference = "Stop"
      aws eks update-kubeconfig --name ${aws_eks_cluster.langfuse.name} --region ${data.aws_region.current.id}

      $deployment = "deployment/coredns"
      for ($attempt = 0; $attempt -lt 20; $attempt++) {
        kubectl -n kube-system get $deployment | Out-Null
        if ($LASTEXITCODE -eq 0) {
          break
        }

        if ($attempt -eq 19) {
          throw "CoreDNS deployment was not created in time."
        }

        Start-Sleep -Seconds 15
      }

      kubectl -n kube-system annotate deployment coredns eks.amazonaws.com/compute-type- --overwrite | Out-Null

      $patch = '{"spec":{"template":{"spec":{"tolerations":[{"key":"eks.amazonaws.com/compute-type","operator":"Equal","value":"fargate","effect":"NoSchedule"}]}}}}'
      kubectl -n kube-system patch deployment coredns --type=strategic -p $patch | Out-Null

      kubectl -n kube-system rollout restart $deployment
      kubectl -n kube-system rollout status deployment/coredns --timeout=300s
    EOT
  }

  depends_on = [
    aws_eks_fargate_profile.namespaces,
  ]
}

# =============================================================================
# Fargate Logging ConfigMap (aws-logging)
# =============================================================================
# Required by the Fargate scheduler to enable pod logging to CloudWatch.
# Without this, every Fargate pod emits a warning:
#   "Disabled logging because aws-logging configmap was not found"
resource "kubernetes_config_map" "aws_logging" {
  metadata {
    name      = "aws-logging"
    namespace = "aws-observability"
  }

  data = {
    "output.conf" = <<-EOT
      [OUTPUT]
          Name              cloudwatch_logs
          Match             *
          region            ${data.aws_region.current.id}
          log_group_name    /aws/eks/${var.name}/fargate
          log_stream_prefix fargate-
          auto_create_group true
    EOT
  }

  depends_on = [
    kubernetes_namespace.aws_observability,
  ]
}

resource "kubernetes_namespace" "aws_observability" {
  metadata {
    name = "aws-observability"
    labels = {
      "aws-observability" = "enabled"
    }
  }
}
