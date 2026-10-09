variable "app_name" {}
variable "region" {
  type = string
}
variable "container_names" {
  type        = list(string)
  description = "Names of the containers to run in the task"
}
variable "container_port" {
  type        = number
  description = "The port number on the container"
}
variable "vpc_id" {}
variable "cluster_name" {}
variable "http_prod_listener_arn" {
  description = "ARN of the production listener (ALB or NLB)"
  type        = string
}
variable "http_test_listener_arn" {
  description = "ARN of the test listener (ALB or NLB)"
  type        = string
}
variable "alb_security_group_id" {
  description = "Security group ID of the load balancer"
  type        = string
}

variable "ecs_security_group_id" {
  description = "Security group ID for ECS tasks. Must be created externally to avoid cycle dependencies with RDS/ElastiCache."
  type        = string
}

variable "load_balancer_type" {
  description = "Type of load balancer (alb or nlb)"
  type        = string
  default     = "alb"
  validation {
    condition     = contains(["alb", "nlb"], var.load_balancer_type)
    error_message = "Load balancer type must be either 'alb' or 'nlb'."
  }
}

variable "nlb_arn" {
  description = "ARN of the Network Load Balancer (required when load_balancer_type is 'nlb')"
  type        = string
  default     = null
}

variable "acm_certificate_arn" {
  description = "ARN of the ACM certificate for TLS termination (required when load_balancer_type is 'nlb')"
  type        = string
  default     = null
}

variable "subnet_ids" {}
variable "desired_task_count" {}
variable "task_cpu_size" {}
variable "task_memory_size" {}
variable "app_health_check_path" {}
variable "repository_url" {}

variable "bootstrap_image_tag" {
  type        = string
  nullable    = false
  description = <<-EOT
    Image tag of the BOOTSTRAP task definition only. CI/CD registers the real revisions (full-SHA
    tags) and the service ignores task_definition changes, so this tag is used only when the service
    is first created and by the S3 appspec this stack writes. A tag that is never pushed (e.g.
    "bootstrap") makes that state explicit: tasks fail with CannotPullContainerError until CI deploys.
    No default and "latest" is rejected: a mutable tag makes "what would run" unanswerable.
  EOT

  validation {
    condition     = can(regex("^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$", var.bootstrap_image_tag)) && var.bootstrap_image_tag != "latest"
    error_message = "bootstrap_image_tag must be a valid image tag (1-128 of [A-Za-z0-9._-], not starting with . or -) and must not be \"latest\"."
  }
}

variable "deregistration_delay" {
  type        = number
  description = <<-EOT
    Seconds the ALB keeps a deregistering target in "draining" (no new requests, in-flight requests
    allowed to finish) before ECS sends SIGTERM. Defaults to 300 — the AWS default — so other
    consumers keep today's behaviour on upgrade.

    Size it against the load balancer's idle timeout, not against the app's shutdown: once draining
    ends, ECS sends SIGTERM and the app's own graceful shutdown (bounded by the container stopTimeout)
    handles whatever is left. A value at or just above the ALB idle timeout lets the ALB close every
    keepalive connection it holds before the task is signalled; anything far above it only slows
    scale-in and the end of a blue/green deployment.
  EOT
  default     = 300
  nullable    = false

  validation {
    condition     = var.deregistration_delay >= 0 && var.deregistration_delay <= 3600
    error_message = "deregistration_delay must be between 0 and 3600 seconds (the ALB limit)."
  }
}
variable "enable_execute_command" {
  type        = bool
  description = <<-EOT
    Turn on ECS Exec for the service's tasks. Defaults to true so existing consumers keep today's
    behaviour on upgrade.

    Turn it OFF where it buys nothing: with a read-only root filesystem there is little to do inside
    the container, and an exec session is an interactive way in that is not session-logged unless the
    cluster has executeCommandConfiguration logging set up.

    With a CODE_DEPLOY deployment controller the flag changes on the service without starting a
    deployment, and takes effect for tasks started AFTER it — i.e. from the next CodeDeploy deployment.
    Tasks already running keep their current setting until they are replaced.
  EOT
  default     = true
  nullable    = false
}
variable "assign_public_ip" {
  type        = bool
  description = "Assign public IP to ECS tasks (required when running in public subnets without NAT Gateway)"
  default     = false
}
variable "repository_arn" {
  type        = string
  description = "The ARN of the ECR repository"
}

variable "cloudwatch_log_retention_in_days" {
  type        = number
  description = "Number of days to retain ECS CloudWatch logs"
  default     = 30

  validation {
    condition     = var.cloudwatch_log_retention_in_days >= 1 && var.cloudwatch_log_retention_in_days <= 3653
    error_message = "cloudwatch_log_retention_in_days must be between 1 and 3653 days."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to resources"
  default     = {}
}

variable "secret_arns" {
  type        = list(string)
  description = "Additional Secrets Manager secret ARNs the task execution role may read — e.g. externally-managed secrets referenced by the task definition's `secrets` entries (registered by CI/CD via taskdef.json). Combined with the managed app-secret container when `create_app_secret = true`. Empty list (and create_app_secret = false) = no Secrets Manager statement in the execution policy."
  default     = []
}

variable "create_app_secret" {
  type        = bool
  description = <<-EOT
    Create a single empty Secrets Manager container named "<app_name>-secrets" for
    the app's runtime secrets. The container-only model: Terraform creates just the
    container and grants the task read access — it NEVER generates or reads any
    secret value, so nothing sensitive is stored in Terraform state. Populate the
    JSON value out-of-band (console or a gitignored file; see secrets.example.json).
    The execution role is automatically granted read access to it and its ARN is
    exposed via the `app_secrets_arn` output for the task definition's `secrets`
    entries (valueFrom = "<arn>:<key>::"). Leave false to manage secrets purely via
    `secret_arns`.
  EOT
  default     = false
}

variable "cpu_architecture" {
  type        = string
  description = "CPU architecture for the Fargate runtime platform. ARM64 (Graviton) is ~20% cheaper than X86_64 — the container image must be built for the matching architecture."
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture must be X86_64 or ARM64."
  }
}

# Enviroment variables
