# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- Replaced the old CoreDNS Fargate workaround with an idempotent patch that
  removes the EC2-only annotation, adds the Fargate toleration, and restarts
  CoreDNS during apply.
- Bumped the AWS Load Balancer Controller Helm chart from `1.7.1` to `1.7.2`
  to match AWS's documented minimum recommendation (`v2.7.2+`).
- Increased Langfuse web/worker startup grace periods to reduce first-install
  CrashLoopBackOffs while migrations complete on EKS Fargate.

## [1.0.0] - 2025-03-04

### Added

- Initial release based on the upstream `langfuse/langfuse-terraform-aws` module.
- Support for existing Route53 hosted zones (no subdomain delegation required).
- Production-hardened defaults: internal ALB, Redis encryption at rest, Multi-AZ
  Redis, 2 web replicas, 2 worker replicas, Aurora max capacity of 8 ACU.
- S3 + DynamoDB backend with bootstrap scripts for both PowerShell and Bash.
- Comprehensive README with architecture diagram, variable reference, and
  deployment guide.

### Changed

- Replaced `aws_route53_zone` resource with `data.aws_route53_zone` data source
  to use an existing hosted zone.
- Fixed inverted NAT gateway logic in VPC module (`single_nat_gateway` and
  `one_nat_gateway_per_az` were swapped).
- Replaced deprecated `data.aws_region.current.name` with `.id`.

### Removed

- Removed `route53_nameservers` output (no longer creating a zone).
