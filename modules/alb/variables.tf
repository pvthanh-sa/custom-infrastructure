variable "allow_cloudfront_prefix_list" {
  description = "Enable ingress from AWS managed CloudFront global origin-facing prefix list."
  type        = bool
  default     = false
}
variable "app_name" {
  type        = string
  description = "Name of the application"
}
variable "create_route53_record" {
  type        = bool
  description = "Whether to create Route 53 DNS record for the ALB. Set to false when using CloudFront."
  default     = true
}
variable "alb_domain" {
  type        = string
  description = "Domain name for the ALB. Required when create_route53_record is true, can be null when create_route53_record is false."
  default     = null
}
variable "acm_certificate_arn" {
  type        = string
  description = "ARN of the ACM certificate to use for HTTPS listeners"
}
variable "route_53_zone_id" {
  type        = string
  description = "Route 53 hosted zone ID for creating DNS records. Required when create_route53_record is true."
  default     = null
}
variable "vpc_id" {
  type        = string
  description = "ID of the VPC where the ALB will be created"
}
variable "restricted_source_ips" {
  type        = list(string)
  description = <<-EOT
    CIDR blocks allowed to reach the listeners. A /0 is rejected outright -- see the validation.
  EOT

  validation {
    condition     = length([for c in var.restricted_source_ips : c if can(regex("/0$", c))]) == 0
    error_message = "restricted_source_ips must not contain a /0 (0.0.0.0/0 or ::/0). This list IS the network boundary in front of the load balancer; opening it to the internet is a decision that must be made deliberately in the module, not passed in as a value. If an ALB genuinely should be public, remove this validation in a commit that says why."
  }

  validation {
    condition     = length(var.restricted_source_ips) > 0
    error_message = "restricted_source_ips must not be empty. An empty list produces a security group with no ingress at all, which looks like a locked-down ALB and is actually an unreachable one -- the failure is silent until someone tries to use the service."
  }
}
variable "subnet_ids" {
  type        = list(string)
  description = "List of subnet IDs where the ALB will be deployed"
}
variable "alb_internal" {
  type        = bool
  description = "Whether the ALB is internal or not"
  default     = false
}

variable "enable_test_listener" {
  type        = bool
  description = "Create the :10443 test listener + the 10443/ICMP SG ingress (ECS blue-green test path). Set false for a single-target ALB that only needs 443 (reduces attack surface)."
  default     = true
}

variable "access_logs_bucket" {
  type        = string
  description = "S3 bucket name for ALB access logs. Empty = access logging disabled. The bucket must allow the regional ELB log-delivery principal to write."
  default     = ""
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to resources"
  default     = {}
}

variable "web_acl_arn" {
  description = "ARN of the WAFv2 Web ACL to associate with this ALB. Must be REGIONAL scope in the same region as the ALB. Leave empty to disable WAF."
  type        = string
  default     = ""
}

variable "ssl_policy" {
  description = "TLS security policy for the HTTPS listeners. Defaults to a TLS 1.2/1.3-only policy (the ALB API default is the legacy ELBSecurityPolicy-2016-08, which still allows TLS 1.0/1.1 — avoid it)."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  validation {
    condition     = !can(regex("TLS-1-0|TLS-1-1|2015-05|2016-08$", var.ssl_policy))
    error_message = "ssl_policy must enforce TLS 1.2 or newer (legacy ELB policies are not allowed)."
  }
}

variable "forward_target_group_arn" {
  description = "If set, the production :443 listener FORWARDS to this target group instead of returning the default fixed 'ok' response. Use for a simple ALB→target deployment (the caller creates the target group + attachments). Empty = fixed-response (ECS/CodeDeploy blue-green pattern)."
  type        = string
  default     = ""
}

# ── Origin mTLS (production :443 listener) ─────────────────────────────────────────────────────────
variable "enable_mutual_auth" {
  description = "Enable origin mTLS on the production HTTPS (:443) listener — it verifies the client certificate the caller (e.g. CloudFront via origin mTLS) presents. MANDATORY when this ALB is a CloudFront origin: a prefix list / shared-secret header alone is NOT sufficient access control (CloudFront origin-facing IP ranges are shared across all AWS accounts)."
  type        = bool
  default     = false
}

variable "mutual_auth_mode" {
  description = "mTLS mode for the :443 listener when enable_mutual_auth = true: 'verify' (reject handshakes without a cert chaining to the trust store) or 'passthrough' (forward the client cert to targets without verifying)."
  type        = string
  default     = "verify"
  validation {
    condition     = contains(["verify", "passthrough"], var.mutual_auth_mode)
    error_message = "mutual_auth_mode must be 'verify' or 'passthrough'."
  }
}

variable "mutual_auth_trust_store_arn" {
  description = "ARN of an EXISTING aws_lb_trust_store for verify mode. Leave empty to have this module create one from mutual_auth_ca_bundle_s3_bucket/key. Ignored unless enable_mutual_auth = true and mode = verify."
  type        = string
  default     = ""
}

variable "mutual_auth_ca_bundle_s3_bucket" {
  description = "S3 bucket holding the CA-bundle PEM that backs a module-created trust store (used only when enable_mutual_auth = true, mode = verify, and mutual_auth_trust_store_arn is empty). The caller owns the bucket + uploads the bundle."
  type        = string
  default     = ""
}

variable "mutual_auth_ca_bundle_s3_key" {
  description = "S3 key of the CA-bundle PEM for the module-created trust store (see mutual_auth_ca_bundle_s3_bucket)."
  type        = string
  default     = ""
}

variable "mutual_auth_ca_bundle_s3_object_version" {
  description = "Optional exact S3 object version to pin the module-created trust store to, so a bucket overwrite can't silently change what's trusted. Empty = latest."
  type        = string
  default     = ""
}

variable "mutual_auth_ignore_client_certificate_expiry" {
  description = "If true, the verify-mode listener accepts expired client certificates (default false = expired certs are rejected)."
  type        = bool
  default     = false
}
