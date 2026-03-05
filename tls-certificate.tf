# =============================================================================
# TLS Certificate + DNS (Using EXISTING Route53 Hosted Zone)
# =============================================================================
# Instead of creating a new Route53 zone, we look up the existing zone for
# the parent domain (e.g. "example.com") and add records directly to it.
# This is simpler and avoids NS delegation steps.
# =============================================================================

# Look up the EXISTING Route53 hosted zone for the parent domain
data "aws_route53_zone" "existing" {
  name         = var.route53_zone_name
  private_zone = false
}

# ACM Certificate for the Langfuse domain
resource "aws_acm_certificate" "cert" {
  domain_name       = var.domain
  validation_method = "DNS"

  tags = {
    Name = local.tag_name
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Create DNS records for certificate validation in the EXISTING zone
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.existing.zone_id
}

# Certificate validation
resource "aws_acm_certificate_validation" "cert" {
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# =============================================================================
# Wait for ALB to be created by the AWS Load Balancer Controller
# =============================================================================
# The ALB is created asynchronously by the controller after the Kubernetes
# Ingress resource is applied (via Helm release). Terraform's data.aws_lb
# cannot find it immediately because it doesn't exist during plan/apply.
# A time_sleep gives the controller enough time to reconcile the Ingress
# resource and provision the ALB before we try to look it up.
# =============================================================================
resource "time_sleep" "wait_for_alb" {
  create_duration = "120s" # Wait 2 minutes for ALB controller to provision ALB

  depends_on = [
    helm_release.langfuse,
    helm_release.aws_load_balancer_controller,
  ]
}

# Get the ALB details (created by AWS Load Balancer Controller)
data "aws_lb" "ingress" {
  tags = {
    "elbv2.k8s.aws/cluster"    = var.name
    "ingress.k8s.aws/stack"    = "langfuse/langfuse"
    "ingress.k8s.aws/resource" = "LoadBalancer"
  }

  depends_on = [
    time_sleep.wait_for_alb,
  ]
}

# Create A record in the EXISTING zone pointing to the ALB
resource "aws_route53_record" "langfuse" {
  zone_id = data.aws_route53_zone.existing.zone_id
  name    = var.domain
  type    = "A"

  alias {
    name                   = data.aws_lb.ingress.dns_name
    zone_id                = data.aws_lb.ingress.zone_id
    evaluate_target_health = true
  }
}
