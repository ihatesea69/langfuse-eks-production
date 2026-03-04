# Langfuse on AWS EKS

Production-ready Terraform configuration for deploying [Langfuse](https://langfuse.com)
on Amazon EKS with Fargate, following the AWS Well-Architected Framework.

This project is based on the upstream
[langfuse/langfuse-terraform-aws](https://github.com/langfuse/langfuse-terraform-aws)
module with the following enhancements:

- Uses an **existing Route53 hosted zone** instead of creating a new one.
- **Production-hardened defaults**: internal ALB, encrypted Redis, Multi-AZ,
  multiple replicas, higher Aurora capacity.
- **Remote state** via S3 and DynamoDB with bootstrap scripts.
- Bug fixes for the upstream module (NAT gateway logic, deprecated attributes).

---

## Table of Contents

- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Inputs](#inputs)
- [Outputs](#outputs)
- [Cost Estimate](#cost-estimate)
- [Post-Deployment](#post-deployment)
- [Troubleshooting](#troubleshooting)
- [Maintenance](#maintenance)
- [Contributing](#contributing)
- [License](#license)

---

## Architecture

```
                                Internet / VPN
                                      |
                              Route 53 (DNS)
                         langfuse.example.com -> ALB
                            ACM Certificate (TLS)
                                      |
  +-------------------------------------------------------------------+
  |                     VPC  10.0.0.0/16  (3 AZs)                    |
  |                                                                   |
  |   Public Subnets (x3)                                             |
  |   +-------------------------------------------------------------+|
  |   | Application Load Balancer (internal or internet-facing)      ||
  |   | HTTPS :443 (ACM)  |  HTTP :80 -> 301 redirect               ||
  |   | Inbound restricted to configured CIDRs                      ||
  |   +----------------------------+--------------------------------+|
  |   | NAT-a |   | NAT-b |   | NAT-c |   (one per AZ by default)   |
  |   +-------+   +-------+   +-------+                              |
  |        |           |           |                                  |
  |   Private Subnets (x3)                                           |
  |   +-------------------------------------------------------------+|
  |   |                                                             ||
  |   |  EKS Fargate Cluster                                        ||
  |   |  +-------------------------------------------------------+ ||
  |   |  | namespace: langfuse                                    | ||
  |   |  |   Langfuse Web     x2   (2 vCPU / 4 GiB)             | ||
  |   |  |   Langfuse Worker  x2   (2 vCPU / 4 GiB)             | ||
  |   |  |   ClickHouse       x3   (2 vCPU / 8 GiB)             | ||
  |   |  |   ZooKeeper        x3   (1 vCPU / 2 GiB)             | ||
  |   |  +-------------------------------------------------------+ ||
  |   |  | namespace: kube-system                                 | ||
  |   |  |   AWS Load Balancer Controller                         | ||
  |   |  |   EFS CSI Driver                                       | ||
  |   |  |   CoreDNS                                              | ||
  |   |  +-------------------------------------------------------+ ||
  |   |                                                             ||
  |   |  Aurora PostgreSQL Serverless v2   ElastiCache Redis 7.0   ||
  |   |    2 instances, 0.5-8 ACU           2 nodes, Multi-AZ      ||
  |   |    Encrypted, 7-day backup          TLS + at-rest encrypt   ||
  |   |                                                             ||
  |   |  EFS (encrypted, elastic)          VPC Endpoints            ||
  |   |    ClickHouse + ZooKeeper PVs        STS (Interface)        ||
  |   |    3 mount targets                   S3 (Gateway)           ||
  |   +-------------------------------------------------------------+|
  |                                                                   |
  |   VPC Flow Logs -> CloudWatch                                     |
  +-------------------------------------------------------------------+

         S3 Bucket (versioned, lifecycle, public access blocked)
           events/  exports/  media/
           Access via IRSA (no static credentials)
```

### Security

| Layer              | Controls                                                         |
|--------------------|------------------------------------------------------------------|
| Network            | VPC isolation, private subnets, security groups, IP whitelist    |
| Encryption transit | TLS on ALB (ACM), Redis TLS, PostgreSQL SSL                     |
| Encryption at rest | RDS, EFS, Redis, S3, Langfuse application-level encryption key   |
| Identity           | IRSA for pod-level IAM, auto-generated 64-char passwords         |
| Observability      | VPC Flow Logs, EKS audit logs, CloudWatch, Performance Insights  |

---

## Prerequisites

| Tool          | Version   | Verify                          |
|---------------|-----------|---------------------------------|
| Terraform     | >= 1.0    | `terraform version`             |
| AWS CLI       | v2        | `aws --version`                 |
| kubectl       | >= 1.28   | `kubectl version --client`      |
| AWS Account   | --        | `aws sts get-caller-identity`   |
| Route53 Zone  | existing  | `aws route53 list-hosted-zones` |

---

## Quick Start

### 1. Bootstrap the remote backend

The backend stores Terraform state in S3 with DynamoDB locking.

PowerShell:

```powershell
.\scripts\bootstrap-backend.ps1
```

Bash:

```bash
chmod +x scripts/bootstrap-backend.sh
./scripts/bootstrap-backend.sh
```

The script auto-detects your AWS account ID and creates:

- `s3://langfuse-terraform-state-<ACCOUNT_ID>` (versioned, encrypted, private)
- `langfuse-terraform-locks` DynamoDB table

Update `backend.tf` with the printed bucket name.

### 2. Configure variables

Copy the example file and fill in your values:

```bash
cp terraform.tfvars.example terraform.tfvars
```

At minimum, set the three required values:

```hcl
domain            = "langfuse.example.com"
route53_zone_name = "example.com"

ingress_inbound_cidrs = [
  "10.0.0.0/8",
]
```

See the [Inputs](#inputs) section for all available options.

### 3. Deploy

```bash
terraform init
terraform plan
terraform apply
```

Expected time: 20-30 minutes. The longest resources are the EKS cluster (~10 min),
Aurora cluster (~10 min), and ElastiCache (~8 min).

### 4. Post-deploy pod restart

Due to a race condition in the upstream Helm chart, ClickHouse pods must be
restarted after the first apply:

```bash
aws eks update-kubeconfig --name langfuse --region us-east-1

kubectl -n kube-system rollout restart deploy coredns
kubectl -n kube-system rollout status deploy coredns

kubectl -n langfuse delete pod langfuse-clickhouse-shard0-0 \
  langfuse-clickhouse-shard0-1 langfuse-clickhouse-shard0-2
kubectl -n langfuse delete pod langfuse-zookeeper-0 \
  langfuse-zookeeper-1 langfuse-zookeeper-2

kubectl -n langfuse get pods -w
```

### 5. Access Langfuse

Open `https://langfuse.example.com` in your browser. If the ALB is `internal`,
you must be connected to the VPC (for example, via VPN or a bastion host).

---

## Inputs

### Required

| Name                  | Type           | Description                                           |
|-----------------------|----------------|-------------------------------------------------------|
| `domain`              | `string`       | Full domain for Langfuse (e.g. `langfuse.example.com`)|
| `route53_zone_name`   | `string`       | Existing Route53 hosted zone (e.g. `example.com`)     |
| `ingress_inbound_cidrs` | `list(string)` | CIDR blocks allowed to access the ALB               |

### Networking

| Name                    | Type           | Default         | Description                                      |
|-------------------------|----------------|-----------------|--------------------------------------------------|
| `name`                  | `string`       | `"langfuse"`    | Name prefix for all resources                    |
| `vpc_cidr`              | `string`       | `"10.0.0.0/16"` | CIDR block for the new VPC                      |
| `vpc_id`                | `string`       | `null`          | Use an existing VPC instead of creating one      |
| `private_subnet_ids`    | `list(string)` | `null`          | Required when `vpc_id` is set                    |
| `public_subnet_ids`     | `list(string)` | `null`          | Required when `vpc_id` is set                    |
| `private_route_table_ids` | `list(string)` | `null`        | For S3 gateway endpoint in existing VPCs         |
| `use_single_nat_gateway`| `bool`         | `false`         | Single NAT (cheaper) vs one per AZ (resilient)   |
| `alb_scheme`            | `string`       | `"internal"`    | `internal` or `internet-facing`                  |

### EKS

| Name                       | Type           | Default                              | Description                        |
|----------------------------|----------------|--------------------------------------|------------------------------------|
| `kubernetes_version`       | `string`       | `"1.32"`                             | EKS Kubernetes version             |
| `fargate_profile_namespaces` | `list(string)` | `["default","langfuse","kube-system"]` | Namespaces with Fargate profiles |

### PostgreSQL (Aurora Serverless v2)

| Name                     | Type     | Default  | Description                          |
|--------------------------|----------|----------|--------------------------------------|
| `postgres_instance_count`| `number` | `2`      | Number of Aurora instances (HA)      |
| `postgres_min_capacity`  | `number` | `0.5`    | Minimum ACU                          |
| `postgres_max_capacity`  | `number` | `8.0`    | Maximum ACU                          |
| `postgres_version`       | `string` | `"15.12"`| PostgreSQL engine version            |

### Redis (ElastiCache)

| Name                     | Type     | Default            | Description                        |
|--------------------------|----------|--------------------|------------------------------------|
| `cache_node_type`        | `string` | `"cache.t4g.small"`| Node instance type                 |
| `cache_instance_count`   | `number` | `2`                | Number of replica nodes            |
| `redis_at_rest_encryption` | `bool` | `true`             | Encrypt data at rest               |
| `redis_multi_az`         | `bool`  | `true`              | Enable Multi-AZ failover           |

### Langfuse Application

| Name                          | Type     | Default    | Description                          |
|-------------------------------|----------|------------|--------------------------------------|
| `langfuse_helm_chart_version` | `string` | `"1.5.14"` | Helm chart version                  |
| `langfuse_cpu`                | `string` | `"2"`      | CPU per web/worker container         |
| `langfuse_memory`             | `string` | `"4Gi"`    | Memory per web/worker container      |
| `langfuse_web_replicas`       | `number` | `2`        | Web pod replicas                     |
| `langfuse_worker_replicas`    | `number` | `2`        | Worker pod replicas                  |
| `use_encryption_key`          | `bool`   | `true`     | Encrypt LLM API keys at rest         |
| `additional_env`              | `list`   | `[]`       | Extra environment variables for pods |

### ClickHouse

| Name                           | Type     | Default | Description                          |
|--------------------------------|----------|---------|--------------------------------------|
| `clickhouse_replicas`          | `number` | `3`     | ClickHouse pod replicas              |
| `clickhouse_instance_count`    | `number` | `3`     | EFS access points                    |
| `clickhouse_cpu`               | `string` | `"2"`   | CPU per ClickHouse container         |
| `clickhouse_memory`            | `string` | `"8Gi"` | Memory per ClickHouse container      |
| `clickhouse_keeper_cpu`        | `string` | `"1"`   | CPU per ZooKeeper container          |
| `clickhouse_keeper_memory`     | `string` | `"2Gi"` | Memory per ZooKeeper container       |
| `enable_clickhouse_log_tables` | `bool`   | `false` | Enable ClickHouse logging tables     |

---

## Outputs

| Name                     | Description                              | Sensitive |
|--------------------------|------------------------------------------|-----------|
| `cluster_name`           | EKS cluster name                         | no        |
| `cluster_host`           | EKS API server endpoint                  | no        |
| `cluster_ca_certificate` | EKS CA certificate (base64 decoded)      | yes       |
| `cluster_token`          | EKS authentication token                 | yes       |
| `route53_zone_id`        | Route53 hosted zone ID                   | no        |
| `langfuse_url`           | Full HTTPS URL for Langfuse              | no        |
| `alb_dns_name`           | DNS name of the ALB                      | no        |
| `private_subnet_ids`     | Private subnet IDs                       | no        |
| `public_subnet_ids`      | Public subnet IDs                        | no        |
| `bucket_name`            | S3 bucket name                           | no        |
| `bucket_id`              | S3 bucket ID                             | no        |

---

## Cost Estimate

Approximate monthly cost in `us-east-1` with default settings:

| Service                | Configuration               | Estimate      |
|------------------------|-----------------------------|---------------|
| EKS control plane      | 1 cluster                   | $73           |
| Fargate compute        | ~20 vCPU, ~44 GiB           | $350 -- $500  |
| Aurora PostgreSQL      | 2 instances, 0.5 -- 8 ACU   | $90 -- $200   |
| ElastiCache Redis      | 2 x cache.t4g.small         | $48           |
| NAT Gateways           | 3 (one per AZ)              | $97           |
| EFS                    | Elastic throughput           | $10 -- $30    |
| ALB                    | 1 load balancer              | $20 -- $40    |
| S3, Route53, ACM, misc | --                           | $10 -- $30    |
| **Total**              |                              | **$700 -- $1,000** |

Set `use_single_nat_gateway = true` to save approximately $65/month at the cost
of reduced availability.

---

## Post-Deployment

Verify the deployment:

```bash
# Cluster status
aws eks describe-cluster --name langfuse --query 'cluster.status'

# Pod health
kubectl -n langfuse get pods
kubectl -n kube-system get pods

# Application logs
kubectl -n langfuse logs -l app.kubernetes.io/component=web --tail=50

# Terraform outputs
terraform output langfuse_url
terraform output alb_dns_name
```

---

## Troubleshooting

**Pods stuck in Pending** -- Check Fargate scheduling and resource limits:

```bash
kubectl -n langfuse describe pod <pod-name>
```

**ClickHouse CrashLoopBackOff** -- Usually happens on first deploy. Delete the
pods and let them recreate:

```bash
kubectl -n langfuse delete pod -l app.kubernetes.io/name=clickhouse
kubectl -n langfuse delete pod -l app.kubernetes.io/name=zookeeper
```

**ACM certificate not validating** -- Verify that the Route53 zone matches
`route53_zone_name` and that validation CNAME records were created.

**Cannot reach the URL** -- If the ALB is `internal`, you must be inside the VPC.
Check that your IP is included in `ingress_inbound_cidrs`.

**Terraform state lock** -- If a previous run was interrupted:

```bash
terraform force-unlock <LOCK_ID>
```

---

## Maintenance

### Updating Langfuse

Set `langfuse_helm_chart_version` to the new version and apply:

```bash
terraform plan
terraform apply
```

### Scaling

Adjust replica counts, Aurora capacity, or Redis node types in
`terraform.tfvars` and apply.

### Backups

| Component    | Strategy              | Retention        |
|--------------|-----------------------|------------------|
| Aurora       | Automated snapshots   | 7 days           |
| S3           | Versioning            | Indefinite       |
| EFS          | AWS Backup (manual)   | Not auto-configured |
| State file   | S3 versioning + KMS   | Indefinite       |

### Destroying all resources

```bash
terraform destroy
```

---

## File Structure

```
.
|-- backend.tf                  Terraform remote state configuration
|-- versions.tf                 Provider requirements and configuration
|-- variables.tf                Input variable definitions
|-- locals.tf                   Local values
|-- vpc.tf                      VPC, subnets, NAT gateways, VPC endpoints
|-- eks.tf                      EKS Fargate cluster
|-- postgresql.tf               Aurora PostgreSQL Serverless v2
|-- redis.tf                    ElastiCache Redis
|-- efs.tf                      EFS file system and CSI driver
|-- clickhouse.tf               ClickHouse persistent volumes
|-- s3.tf                       S3 bucket and IRSA role
|-- ingress.tf                  AWS Load Balancer Controller
|-- tls-certificate.tf          ACM certificate and Route53 DNS records
|-- langfuse.tf                 Langfuse Helm release
|-- outputs.tf                  Terraform outputs
|-- terraform.tfvars            Your configuration (git-ignored)
|-- terraform.tfvars.example    Example configuration
|-- scripts/
|   |-- bootstrap-backend.ps1   Backend bootstrap (PowerShell)
|   |-- bootstrap-backend.sh    Backend bootstrap (Bash)
|-- CHANGELOG.md                Release history
|-- CONTRIBUTING.md             Contribution guidelines
|-- LICENSE                     MIT License
```

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

Based on [langfuse/langfuse-terraform-aws](https://github.com/langfuse/langfuse-terraform-aws)
(MIT License).
