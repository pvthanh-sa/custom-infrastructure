# ECS Server Module

This module deploys an ECS Fargate service with Application Load Balancer (ALB) or Network Load Balancer (NLB) integration, supporting Blue/Green deployments via AWS CodeDeploy.

> ## 🚨 UPGRADE NOTE — 2026-09-24. One permission removed. Check before you upgrade.
>
> **`ssm:GetParameters` and `kms:Decrypt` are gone from the ECS TASK role.** Both were granted on
> `Resource "*"`, which meant every SSM parameter in the account and every key that could decrypt
> them.
>
> **If your application reads SSM Parameter Store at runtime, it will start failing with
> AccessDenied after this upgrade.** Re-attach the permission yourself, scoped to your parameters —
> the new `ecs_task_role_name` output (below) exists so you can, without hardcoding the role name.
>
> Runtime secrets pulled through the task definition's `secrets` block are **not** affected: those
> are fetched by the *execution* role, which is untouched. `kms:Decrypt` on the task role is needed
> only when ECS Exec session encryption is configured with a CMK
> (`executeCommandConfiguration.kmsKeyId` on the cluster). If you set that, re-add `kms:Decrypt`
> scoped to **that key ARN** with a `kms:ViaService` condition — never back to `"*"`.
>
> The four `ssmmessages:*` actions stay on `Resource "*"` and must: the SSM Messages API defines no
> resource-level permissions for them, so any ARN there denies every ECS Exec session.
>
> ### Also new (additive, nothing breaks)
>
> - **`ecs_task_role_name` output** — attach your own policies to the task role without hardcoding
>   its name. Its absence is why an assets-bucket policy once shipped orphaned.
> - **`desired_count` added to `lifecycle.ignore_changes`** — when an `aws_appautoscaling_target` is
>   registered against the service, Application Auto Scaling owns the count. Without this, every
>   apply reset the service to `var.desired_task_count`, *including mid scale-out*, removing capacity
>   during the load event that caused it. If you do NOT use autoscaling and relied on Terraform to
>   set the count, note that changes to `desired_task_count` no longer take effect after creation.

## Features

- ✅ ECS Fargate tasks with customizable CPU/Memory
- ✅ ALB or NLB integration with health checks
- ✅ Blue/Green deployment support (CODE_DEPLOY controller)
- ✅ Optional secrets via AWS Secrets Manager (container-only; values managed out-of-band, never in Terraform state)
- ✅ CloudWatch Logs integration (configurable retention)
- ✅ ARM64 (Graviton) or X86_64 Fargate runtime — ARM64 is ~20% cheaper
- ✅ **Flexible network configuration (private or public subnets)**
- ✅ Auto-scaling ready with target groups
- ✅ ECR integration for container images

## Network Deployment Options

This module supports **two deployment strategies** based on your network architecture and cost requirements:

### 1. Private Subnet Deployment (Production Recommended)

**Use Case:** Production environments requiring enhanced security and isolation.

**Network Architecture:**
```
Internet → IGW → ALB (Public Subnet) → ECS Tasks (Private Subnet) → NAT Gateway → Internet
                                      ↓
                                   RDS/ElastiCache (Database Subnet)
```

**Configuration:**
```hcl
module "ecs_server" {
  source = "../../modules/ecs"
  
  # Network - PRIVATE subnets (with NAT Gateway)
  subnet_ids       = module.vpc.private_subnet_ids
  assign_public_ip = false  # Tasks do NOT get public IPs
  
  # ... other configuration
}
```

**Characteristics:**
- ✅ **Security:** ECS tasks have no direct internet access, protected by NAT Gateway
- ✅ **Best Practice:** Recommended for production workloads
- ✅ **Database Access:** Direct access to RDS/ElastiCache in private subnets
- ❌ **Cost:** NAT Gateway charges (~$32/month per AZ + data transfer)
- ✅ **AWS Services:** Access AWS services (Secrets Manager, ECR, S3) via NAT Gateway
- ✅ **Outbound Only:** NAT Gateway provides outbound internet access only

**Requirements:**
- NAT Gateway must be configured in VPC
- Private subnets must route `0.0.0.0/0` to NAT Gateway
- VPC endpoints (optional but recommended for cost optimization)

---

### 2. Public Subnet Deployment (Cost-Optimized)

**Use Case:** Development, demo, or staging environments where cost optimization is priority.

**Network Architecture:**
```
Internet → IGW → ALB (Public Subnet) → ECS Tasks (Public Subnet with Public IP) → IGW → Internet
                                      ↓
                                   RDS/ElastiCache (Database Subnet)
```

**Configuration:**
```hcl
module "ecs_server" {
  source = "../../modules/ecs"
  
  # Network - PUBLIC subnets (no NAT Gateway)
  subnet_ids       = module.vpc.public_subnet_ids
  assign_public_ip = true  # Required! Tasks MUST get public IPs
  
  # ... other configuration
}
```

**Characteristics:**
- ✅ **Cost Saving:** No NAT Gateway charges (saves ~$32-96/month)
- ✅ **AWS Services:** Direct access to Secrets Manager, ECR, S3 via Internet Gateway
- ✅ **Database Access:** Can access RDS/ElastiCache in private subnets (same VPC)
- ⚠️ **Security:** Tasks have public IPs but protected by Security Groups
- ⚠️ **Exposure:** Each task has a public IP (inbound blocked by Security Group)
- ✅ **Simple Routing:** Public subnet routes `0.0.0.0/0` to Internet Gateway

**Requirements:**
- **`assign_public_ip = true` is MANDATORY** - Without public IP, tasks cannot reach AWS services
- Public subnets must route `0.0.0.0/0` to Internet Gateway
- Security Group must allow outbound traffic to `0.0.0.0/0`
- ALB/NLB must be in public subnets

**⚠️ Common Error:**
If `assign_public_ip = false` in public subnets, you'll see:
```
ResourceInitializationError: unable to pull secrets or registry auth: 
unable to retrieve secret from asm: There is a connection issue between 
the task and AWS Secrets Manager.
```

---

## Comparison Table

| Feature | Private Subnet + NAT Gateway | Public Subnet + Public IP |
|---------|------------------------------|---------------------------|
| **Monthly Cost (NAT)** | ~$32-96/month | $0 (no NAT) |
| **Security Posture** | ⭐⭐⭐⭐⭐ High | ⭐⭐⭐ Medium |
| **Production Ready** | ✅ Yes (Recommended) | ⚠️ Acceptable for non-critical |
| **Task Public IP** | ❌ No | ✅ Yes (auto-assigned) |
| **Internet Access** | Via NAT Gateway | Direct via IGW |
| **AWS Service Access** | Via NAT Gateway | Direct via IGW |
| **Database Access** | ✅ Direct (private) | ✅ Direct (private) |
| **Use Cases** | Production, Staging | Dev, Demo, Cost-sensitive |
| **assign_public_ip** | `false` | `true` (required) |

---

## Usage Examples

### Example 1: Production (Private Subnet)

```hcl
# VPC with NAT Gateway
module "vpc" {
  source = "../../modules/network"
  
  enable_nat_gateway = true
  single_nat_gateway = true  # or false for HA (multi-AZ)
  
  # ... other config
}

# ECS Server in Private Subnets
module "ecs_server" {
  source = "../../modules/ecs"
  
  app_name = "prod-my-app"
  region   = "ap-northeast-1"
  vpc_id   = module.vpc.vpc_id
  
  # Container
  container_names       = ["server"]
  container_port        = 8000
  app_health_check_path = "/health"
  
  # Network - PRIVATE with NAT Gateway
  subnet_ids       = module.vpc.private_subnet_ids
  assign_public_ip = false
  
  # Load Balancer (ALB)
  load_balancer_type     = "alb"
  http_prod_listener_arn = module.alb.lb_listener_http_prod_arn
  http_test_listener_arn = module.alb.lb_listener_http_test_arn
  alb_security_group_id  = module.alb.alb_security_group_id
  
  # Security
  ecs_security_group_id = aws_security_group.ecs_tasks.id
  
  # ECR
  repository_url = module.ecr.repository_url
  repository_arn = module.ecr.repository_arn
  
  # Resources
  desired_task_count = 2
  task_cpu_size      = 512
  task_memory_size   = 1024
  cpu_architecture   = "ARM64" # Graviton — ~20% cheaper (image must match)

  # Secrets — create the "<app_name>-secrets" container; populate its value
  # out-of-band (see the "Secrets" section). Non-sensitive env vars and the
  # secret `valueFrom` wiring are set in CI/CD's taskdef.json at deploy time.
  create_app_secret = true

  tags = local.tags
}
```

### Example 2: Demo/Dev (Public Subnet - Cost Optimized)

```hcl
# VPC without NAT Gateway
module "vpc" {
  source = "../../modules/network"
  
  enable_nat_gateway = false  # No NAT Gateway for cost saving
  single_nat_gateway = false
  
  # ... other config
}

# ECS Server in Public Subnets
module "ecs_server" {
  source = "../../modules/ecs"
  
  app_name = "demo-my-app"
  region   = "ap-northeast-1"
  vpc_id   = module.vpc.vpc_id
  
  # Container
  container_names       = ["server"]
  container_port        = 8000
  app_health_check_path = "/health"
  
  # Network - PUBLIC without NAT Gateway
  subnet_ids       = module.vpc.public_subnet_ids
  assign_public_ip = true  # REQUIRED for public subnet deployment!
  
  # Load Balancer (ALB)
  load_balancer_type     = "alb"
  http_prod_listener_arn = module.alb.lb_listener_http_prod_arn
  http_test_listener_arn = module.alb.lb_listener_http_test_arn
  alb_security_group_id  = module.alb.alb_security_group_id
  
  # Security
  ecs_security_group_id = aws_security_group.ecs_tasks.id
  
  # ECR
  repository_url = module.ecr.repository_url
  repository_arn = module.ecr.repository_arn
  
  # Resources (minimal for demo)
  desired_task_count = 1
  task_cpu_size      = 256
  task_memory_size   = 512

  # Secrets — create the "<app_name>-secrets" container; populate out-of-band.
  create_app_secret = true

  tags = local.tags
}
```

---

## ⚠️ BREAKING CHANGE — the task role no longer grants `ssm:GetParameters` or `kms:Decrypt`

**Before:** `data.aws_iam_policy_document.ecs_task` granted `ssm:GetParameters`, `kms:Decrypt` and
four `ssmmessages:*` actions, all on `Resource: "*"`.

**Now:** only the four `ssmmessages:*` ECS Exec channel actions remain, still on `"*"` — the SSM
Messages API defines no resource-level permissions for them, so any ARN there would deny every
session. That wildcard is required, not an oversight; do not "tighten" it.

**What a consumer must do:** if your task code reads SSM Parameter Store or calls `kms:Decrypt`
directly, it will now get AccessDenied. Attach those permissions yourself, scoped to the parameters
and keys you actually use — `ecs_task_role_name` (below) exists so you can.

**Why:** on `Resource: "*"` those two actions let any code execution inside a container read **every**
SSM parameter in the account, SecureStrings included, because `kms:Decrypt` on `*` covers the keys
protecting them. `kms:Decrypt` is only genuinely needed when ECS Exec session encryption is
configured with a CMK (`executeCommandConfiguration.kmsKeyId`); if you enable that, re-add it scoped
to **that key ARN** with a `kms:ViaService` condition — never back to `"*"`.

## Attaching your own policies: `ecs_task_role_name`

The module outputs `ecs_task_role_arn` and, since 2026-09-18, `ecs_task_role_name`. Use the **name**
with `aws_iam_role_policy_attachment`; without it a caller had to hardcode the role name, which is
why an assets-bucket policy once shipped created-but-attached-to-nothing.

```terraform
resource "aws_iam_role_policy_attachment" "app" {
  role       = module.ecs.ecs_task_role_name
  policy_arn = aws_iam_policy.app.arn
}
```

## `desired_count` is owned by autoscaling

`aws_ecs_service.lifecycle.ignore_changes` includes `desired_count`. If you register an
`aws_appautoscaling_target` against this service — the `cloudwatch_alarm_ecs` module does — then
Application Auto Scaling owns that field. Without this, every apply resets the service to
`var.desired_task_count`, **including mid scale-out**, removing capacity during the load event that
caused it, and "plan is clean" stops being a truthful convergence signal.

`desired_task_count` therefore sets only the INITIAL count.

## ⚠️ BREAKING CHANGE — the bootstrap task definition, and a required `bootstrap_image_tag`

This module registers a **bootstrap** task definition. The service ignores `task_definition`, so
CI/CD registers the real revisions; the bootstrap one runs only when the service is first created,
and it is the revision the CodeDeploy module's S3 appspec (`create_deployment_script`) points at.
It used to describe an image nobody deploys: `command ["node","dist/main"]`, a `curl` health check,
image `:latest`, root user, writable root filesystem.

**Now:**

| Field | Before | Now |
|-------|--------|-----|
| image | `<repo>:latest` | `<repo>:${var.bootstrap_image_tag}` — **required, no default, `latest` rejected** |
| `command` | `["node","dist/main"]` | none — the image's own `CMD` |
| health check | `curl -f http://localhost:<port><path>` | `wget -q -T 4 -O /dev/null http://127.0.0.1:<port><path>` (interval 10, timeout 5, retries 10, startPeriod 10) |
| `user` | (image default, often root) | `1000:1000` |
| root filesystem | writable | `readonlyRootFilesystem = true`, task volume `tmp` mounted at `/tmp` |
| `stopTimeout` | ECS default (30) | `30`, explicit |

**What a consumer must do:**

1. Set `bootstrap_image_tag`. A tag that is never pushed (e.g. `"bootstrap"`) is a good choice: until
   CI deploys, a task fails with `CannotPullContainerError` — a clear signal — instead of silently
   pulling a mutable tag. Do not point it at `latest`.
2. Check that your image fits the template's **assumptions**: BusyBox `wget` on the PATH (Alpine
   images have it; Debian-slim does not, and `curl` is gone), a user with **UID 1000**, and writes
   **only under `/tmp`**. If you deploy with the S3 appspec + `create_deployment_script`, the bootstrap
   revision is what runs — an image that breaks an assumption fails its health check and CodeDeploy
   rolls back (loud, not silent). If you register your own task definitions from CI, nothing running
   changes: Terraform registers a new bootstrap revision and deregisters the previous bootstrap one.

## ECS Exec: `enable_execute_command`

Was hardcoded `true`. Now a variable, **default `true`** so upgrading changes nothing. Set `false`
when the container runs a read-only root filesystem (an exec session can do very little) or when no
session logging is configured. With a `CODE_DEPLOY` controller the flag flips on the service without
a deployment and takes effect for tasks started by the next deployment.

## Target-group draining: `deregistration_delay`

Was unset, so both target groups used the AWS default of **300 s** — every scale-in and every
blue/green termination drained for five minutes. Now a variable, **default 300** (unchanged
behaviour), validated 0–3600. Size it against the ALB `idle_timeout`: a value ≥ the idle timeout
lets the ALB close every keep-alive connection it holds before ECS sends SIGTERM, so 60 is a good
choice behind an ALB at the default idle timeout of 60.

## Required Variables

| Variable | Type | Description |
|----------|------|-------------|
| `app_name` | string | Application name prefix |
| `region` | string | AWS region |
| `vpc_id` | string | VPC ID |
| `container_names` | list(string) | Container names in task definition |
| `container_port` | number | Container port number |
| `cluster_name` | string | ECS cluster name |
| `subnet_ids` | list(string) | Subnet IDs for ECS tasks (private or public) |
| `assign_public_ip` | bool | **Assign public IP to tasks (required for public subnets)** |
| `http_prod_listener_arn` | string | Production listener ARN |
| `http_test_listener_arn` | string | Test listener ARN |
| `ecs_security_group_id` | string | Security group ID for ECS tasks |
| `repository_url` | string | ECR repository URL |
| `repository_arn` | string | ECR repository ARN |
| `bootstrap_image_tag` | string | Image tag of the **bootstrap** task definition only. No default; `latest` rejected. See the breaking-change section |

## Optional Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `desired_task_count` | number | 1 | Number of tasks to run |
| `task_cpu_size` | number | 256 | Task CPU units (256 = 0.25 vCPU) |
| `task_memory_size` | number | 512 | Task memory in MB |
| `app_health_check_path` | string | `/health` | Health check endpoint |
| `load_balancer_type` | string | `"alb"` | Load balancer type (`alb` or `nlb`) |
| `cpu_architecture` | string | `"X86_64"` | Fargate CPU architecture (`X86_64` or `ARM64`). ARM64 (Graviton) is ~20% cheaper — image must match |
| `enable_execute_command` | bool | `true` | ECS Exec on the service |
| `deregistration_delay` | number | `300` | Seconds a target drains before ECS sends SIGTERM (0–3600) |
| `cloudwatch_log_retention_in_days` | number | 30 | Days to retain ECS CloudWatch logs (1–3653) |
| `create_app_secret` | bool | `false` | Create the single `<app_name>-secrets` container (see the "Secrets" section) |
| `secret_arns` | list(string) | `[]` | Extra externally-managed secret ARNs the execution role may read |
| `assign_public_ip` | bool | `false` | Assign public IP to tasks (required for public subnets) |
| `nlb_arn` | string | `null` | NLB ARN (required when `load_balancer_type = "nlb"`) |
| `acm_certificate_arn` | string | `null` | ACM cert ARN for TLS (required when `load_balancer_type = "nlb"`) |
| `tags` | map(string) | `{}` | Tags applied to resources |

---

## Outputs

| Output | Description |
|--------|-------------|
| `service_name` | ECS service name |
| `task_definition_arn` | Task definition ARN |
| `lb_target_group_blue_name` | Blue target group name |
| `lb_target_group_green_name` | Green target group name |
| `lb_target_group_blue_arn_suffix` | Blue target group ARN suffix |
| `lb_target_group_green_arn_suffix` | Green target group ARN suffix |
| `ecs_task_role_arn` | Task role ARN |
| `ecs_task_execution_role_arn` | Task execution role ARN |
| `ecs_cloudwatch_log_group_name` | CloudWatch log group name |
| `app_secrets_arn` | ARN of the `<app_name>-secrets` container (null when `create_app_secret = false`) |
| `lb_listener_tcp_prod_arn` | Prod listener ARN (NLB listener when `nlb`, else the passed-in ALB listener) |
| `lb_listener_tcp_test_arn` | Test listener ARN (NLB listener when `nlb`, else the passed-in ALB listener) |

---

## Secrets

This module can optionally create **one** empty Secrets Manager container
`<app_name>-secrets` (set `create_app_secret = true`). The **container-only**
model: Terraform creates just the container and grants the task read access — it
**never generates or reads any secret value**, so nothing sensitive lands in
Terraform state, tfvars, or git. Every secret the app needs is a key inside that
one JSON, managed out-of-band.

Referencing keys — in the task definition's `secrets` entries (typically wired in
CI/CD's `taskdef.json`, since the service ignores `task_definition` changes):

```json
{ "name": "DB_PASSWORD", "valueFrom": "<app_secrets_arn>:db_password::" }
```

`<app_secrets_arn>` is exposed via the `app_secrets_arn` output. Keys are
app-defined — add whatever your app reads.

### Populate / rotate the secret (out-of-band)

1. Copy `secrets.example.json` (in this module), fill in real values — generate
   with e.g. `openssl rand -base64 48`. Save as a **gitignored** file (e.g.
   `secrets/<app_name>.json`); never commit it.
2. Upload to the container:
   - Console: secret `<app_name>-secrets` → **Retrieve secret value → Edit** → paste → Save, **or**
   - CLI: `aws secretsmanager put-secret-value --secret-id <app_name>-secrets --secret-string file://secrets/<app_name>.json`
3. **Do this before the first deploy** — a missing key makes the ECS task fail at start.
4. To rotate: edit the value, then trigger a new CodeDeploy release (ECS reads secrets at task start).

> Terraform `apply` only ensures the container exists; it never touches the value,
> so `terraform plan` never shows secret values.

**Alternative — externally-managed secrets:** if the secret already exists (e.g.
the RDS-managed password secret), skip `create_app_secret` and pass its ARN via
`secret_arns` instead; the execution role is granted read access all the same.

---

## Security Considerations

### Private Subnet (Recommended)
- ✅ Tasks have no public IPs - better attack surface reduction
- ✅ All outbound traffic goes through NAT Gateway
- ✅ Can use VPC endpoints to avoid NAT Gateway data charges
- ✅ Compliant with most security frameworks

### Public Subnet (Use with Caution)
- ⚠️ Each task gets a public IP address
- ✅ Inbound traffic blocked by Security Group (only ALB can connect)
- ✅ Outbound traffic allowed for AWS service access
- ⚠️ Consider using VPC endpoints for sensitive services
- ⚠️ Monitor CloudTrail logs for unauthorized access attempts

### Security Group Configuration (Both Cases)

```hcl
resource "aws_security_group" "ecs_tasks" {
  name_prefix = "ecs-tasks-"
  vpc_id      = module.vpc.vpc_id
  
  # Allow inbound from ALB only
  ingress {
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [module.alb.alb_security_group_id]
  }
  
  # Allow all outbound (required for AWS services)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

---

## Troubleshooting

### Error: Cannot pull secrets from Secrets Manager

**Symptom:**
```
ResourceInitializationError: unable to pull secrets or registry auth: 
unable to retrieve secret from asm
```

**Cause:** Tasks in public subnets without public IPs cannot reach AWS services.

**Solution:** Set `assign_public_ip = true` when using public subnets.

### Error: Cannot pull ECR images

**Symptom:**
```
CannotPullContainerError: Error response from daemon
```

**Causes & Solutions:**
1. **Public subnet without public IP:** Set `assign_public_ip = true`
2. **Private subnet without NAT:** Enable NAT Gateway in VPC module
3. **IAM permissions:** Ensure task execution role has ECR pull permissions (automatically configured by this module)

### High NAT Gateway Costs

**Solution:** Consider using VPC endpoints for frequently accessed AWS services:
- `com.amazonaws.region.ecr.api` - ECR API
- `com.amazonaws.region.ecr.dkr` - ECR Docker
- `com.amazonaws.region.secretsmanager` - Secrets Manager
- `com.amazonaws.region.logs` - CloudWatch Logs

---

## Best Practices

1. **Production:** Use private subnets with NAT Gateway or VPC endpoints
2. **Dev/Demo:** Use public subnets with `assign_public_ip = true` to save costs
3. **Security:** Always restrict Security Group ingress to ALB/NLB only
4. **Monitoring:** Enable CloudWatch Container Insights for performance monitoring
5. **Secrets:** Never hardcode secrets. Use `create_app_secret` to have the module create only the secret *container*; values are uploaded out-of-band so nothing sensitive lands in Terraform state (see the "Secrets" section).
6. **Scaling:** Configure auto-scaling based on CloudWatch metrics
7. **Health Checks:** Implement comprehensive health check endpoints

---

## License

This module is maintained by the infrastructure team.
