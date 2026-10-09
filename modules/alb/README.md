# AWS Application Load Balancer (ALB) Terraform Module

Terraform module which creates Application Load Balancer resources on AWS.

> ## 🚨 UPGRADE NOTE — 2026-09-24. Two breaking changes. Read before you plan.
>
> ### 1. Your NEXT APPLY REPLACES THE SECURITY GROUP. Every consumer, no exception.
>
> `aws_security_group.security_group` moved from a fixed `name` to `name_prefix`. `name` is ForceNew
> in the EC2 API, so this one change replaces the SG. Expect, in your plan:
>
> - `aws_security_group.security_group` **replaced** (created first — `create_before_destroy`)
> - `aws_lb.alb` **updated in place** to point at the new SG id
> - any rule you declared elsewhere that *references* this SG id **recreated**
>
> There is a **brief window during the swap in which the new SG carries no ingress yet.** In-flight
> connections survive; new ones may be refused for a few seconds. Plan it like a change, not a
> no-op.
>
> Why it had to happen now, and not later: a fixed `name` together with `create_before_destroy`
> means *any* future ForceNew change (adding a resource-level `description`, for instance) deadlocks
> on `InvalidGroup.Duplicate` — both SGs exist at once under the same name — and the only way out is
> `terraform untaint`. We hit exactly that on 2026-09-17. Shipping the trap and the fix in separate
> releases would have handed the deadlock to whoever changed the SG next. The `Name` **tag** is
> still pinned to `${var.app_name}-alb`, so the console and your scripts find it the same way.
>
> ### 2. `test_listener_source_ips` FAILS CLOSED. The VPC-CIDR fallback is gone.
>
> The `:10443` blue/green test listener used to fall back to **every CIDR associated with the VPC**
> when the caller named no source. That fallback was the defect — a module default that grants
> access — and it is removed. **Empty now means no `:10443` ingress at all.**
>
> If you never set this variable, you are relying on the old fallback and **you lose test-listener
> reachability on upgrade**: CodeDeploy blue/green still deploys, but nothing can reach the green
> target group on `:10443` to validate it. Set `test_listener_source_ips` to the sources that
> genuinely need it.
>
> This port is not an inert stub: its listener rule forwards `path_pattern ["*"]` to the green
> target group, so anything allowed here reaches the whole application, unauthenticated, during
> every deployment — bypassing CloudFront, WAF and any edge auth.
>
> ### Also new (additive, nothing breaks)
>
> `ingress_source_security_group_ids` — grant `:443` from source security groups, for in-VPC callers
> whose address is not worth expressing as a CIDR. It has to be declared in-line inside the SG
> resource, because the AWS provider does not support mixing in-line ingress blocks with standalone
> `aws_security_group_rule` resources: the in-line set silently strips them on every apply.

> ⚠️ **When this ALB is a CloudFront origin: Origin mTLS is MANDATORY.** The HTTPS listener MUST run
> `mutual_authentication { mode = "verify" }` against a trust store (CA bundle in S3) so only your
> CloudFront distribution — presenting its client certificate — can connect. A CloudFront **prefix
> list alone is NOT sufficient**: the origin-facing CloudFront IP ranges are shared across *all* AWS
> accounts, so anyone can point their own distribution at this ALB and pass the prefix-list rule.
> **Implemented (since 2026-06-26).** Enable it with `enable_mutual_auth = true`, then either pass an
> existing `mutual_auth_trust_store_arn` **or** let the module create the trust store from
> `mutual_auth_ca_bundle_s3_bucket` + `mutual_auth_ca_bundle_s3_key` (the :443 listener then runs
> `mutual_authentication { mode = "verify" }`). The caller owns the S3 bucket and uploads the CA bundle.

## Features

This module supports creating:

- **Application Load Balancer** - Internal or Internet-facing
- **Security Group** - With configurable ingress rules
- **HTTPS Listeners** - Production (443) and Test (10443) ports
- **HTTP Redirect** - Automatic HTTP to HTTPS redirect
- **Route53 DNS Record** - Optional A record for the ALB
- **CloudFront Integration** - CloudFront prefix list (network layer; ⚠️ NOT sufficient access control alone — pair with Origin mTLS, see note above)

## Usage

### Example 1: Internal ALB (Private Services)

```terraform
module "alb_internal" {
  source = "../../modules/alb"

  app_name = "${var.environment}-${var.app_name}-api"
  vpc_id   = module.network.vpc_id

  restricted_source_ips = concat(
    [for subnet in data.aws_subnet.public_subnets : subnet.cidr_block],
    var.alb_restricted_source_ips
  )

  subnet_ids          = [for subnet in data.aws_subnet.private_subnets : subnet.id]
  alb_internal        = true
  route_53_zone_id    = data.aws_route53_zone.internal.id
  acm_certificate_arn = module.internal_acm.certificate_arn
  alb_domain          = var.alb_api_domain

  tags = {
    Environment = "staging"
    Terraform   = "true"
  }
}
```

### Example 2: Internet-Facing ALB (Public Services)

```terraform
module "alb_public" {
  source = "../../modules/alb"

  app_name = "${var.environment}-${var.app_name}-public"
  vpc_id   = module.network.vpc_id

  # NOTE: a /0 is REJECTED by this module's validation. An internet-facing ALB must name the
  # sources deliberately, or sit behind CloudFront (allow_cloudfront_prefix_list = true).
  restricted_source_ips = ["203.0.113.0/24"] # example: your egress ranges

  subnet_ids          = [for subnet in data.aws_subnet.public_subnets : subnet.id]
  alb_internal        = false
  route_53_zone_id    = data.aws_route53_zone.public.id
  acm_certificate_arn = module.acm.certificate_arn
  alb_domain          = var.alb_public_domain

  tags = {
    Environment = "production"
    Terraform   = "true"
  }
}
```

### Example 3: ALB with CloudFront (CDN)

```terraform
module "alb_with_cloudfront" {
  source = "../../modules/alb"

  app_name = "${var.environment}-${var.app_name}-cdn"
  vpc_id   = module.network.vpc_id

  # Only allow traffic from CloudFront
  restricted_source_ips        = []
  allow_cloudfront_prefix_list = true

  subnet_ids          = [for subnet in data.aws_subnet.public_subnets : subnet.id]
  alb_internal        = false
  acm_certificate_arn = module.acm.certificate_arn

  # Skip Route53 record - CloudFront will handle DNS
  # route_53_zone_id and alb_domain are optional when create_route53_record = false
  create_route53_record = false

  tags = {
    Environment = "production"
    Terraform   = "true"
  }
}
```

## ALB Placement Options

| Option                 | Description                             | Use Case                    |
| ---------------------- | --------------------------------------- | --------------------------- |
| `alb_internal = true`  | Internal ALB accessible only within VPC | Backend APIs, microservices |
| `alb_internal = false` | Internet-facing ALB publicly accessible | Public websites, APIs       |

## Idle timeout — and the 502 it causes if the app is not configured

`idle_timeout` defaults to **60** (the AWS default), set explicitly so it is readable from code
instead of requiring an AWS lookup.

It is a **contract with the application**, not only a tuning knob. The ALB pools and reuses backend
connections. If the target closes an idle connection first, the ALB can put a request onto a socket
the target already closed and return **502** — intermittent, not tied to any endpoint, and usually
seen after a user idles for tens of seconds and then acts again.

The target must always outlive the ALB:

```
headersTimeout  >  keepAliveTimeout  >  idle_timeout
```

| `idle_timeout` | Node `keepAliveTimeout` | Node `headersTimeout` |
| -------------- | ----------------------- | --------------------- |
| 60 (default)   | 65_000                  | 66_000                |
| 120            | 125_000                 | 126_000               |
| N              | (N + 5) × 1000          | (N + 6) × 1000        |

Node's own defaults — `keepAliveTimeout` 5 s, `headersTimeout` 60 s — are **below** 60, so a Node
service behind this module hits the race unless it sets both on the underlying `http.Server`.
Express/Nest expose that server directly; Nitro (Nuxt) does not, so reaching it there takes a build
step — and in either case **log the effective `keepAliveTimeout` at startup**, because a hook that
silently failed to attach looks identical to one that worked.

### Keep the app's env in step with this value

Do not hardcode 65_000 / 66_000 in the app. Pass the ALB value to the container and let the app
derive both timeouts from it, so the two sides can only change together:

| App | Env var (in the task definition) | App computes |
| --- | -------------------------------- | ------------ |
| NestJS / Express | `ALB_IDLE_TIMEOUT_SECONDS` | `keepAliveTimeout = (N + 5) s`, `headersTimeout = (N + 6) s` |
| Nuxt (Nitro) | `NUXT_ALB_IDLE_TIMEOUT_SECONDS` (`NUXT_` prefix = Nuxt runtime config) | same |

**The env value MUST equal `idle_timeout`.** The task definition is usually registered by CI/CD
from the app repository, not by Terraform, so nothing links the two automatically: when you change
`idle_timeout`, change the env var in the app's task definition in the same release — and raise the
app side first, then the ALB.

Do **not** lower `idle_timeout` below the app's keep-alive to fix the ordering. That cuts off every
request slower than the timeout (504) and destroys connection reuse. Raise the app above the ALB,
never drop the ALB below the app.

## Security Configuration Options

| Option                                   | Description                                |
| ---------------------------------------- | ------------------------------------------ |
| `restricted_source_ips = ["0.0.0.0/0"]`  | ❌ **REJECTED** by validation — see the note below |
| `restricted_source_ips = ["10.0.0.0/8"]` | Allow only internal VPC traffic            |
| `allow_cloudfront_prefix_list = true`    | Allow traffic only from CloudFront         |
| `create_route53_record = false`          | Skip Route53 record (for CloudFront setup) |

## ⚠️ BREAKING CHANGE — the :10443 test listener now fails closed

**Before:** `test_listener_source_ips` did not exist, and the :10443 blue/green test listener took
ingress from **every CIDR associated with the VPC**.

**Now:** `test_listener_source_ips` defaults to `[]`, which means **no :10443 ingress at all**.

**What a consumer must do:** if you use blue/green and need to reach the test listener, name the
sources — `test_listener_source_ips = ["10.0.1.0/24"]`. If you do nothing, the listener still
exists and CodeDeploy keeps working; only the security-group ingress is gone.

**Why:** the test listener is not a spare debug port. The consuming stack points a listener rule
with `path_pattern ["*"]` at the green target group, so every source allowed on :10443 reaches the
**entire application, unauthenticated**, during every blue/green shift — bypassing CloudFront, WAF
and any edge authentication. A module default must never grant that; the consumer says where from.

## Granting ingress from a security group

`ingress_source_security_group_ids` lets an in-VPC caller reach the production listener without
inventing a CIDR for it — a Fargate task in another subnet calling this ALB server-side, for example.

```terraform
ingress_source_security_group_ids = [aws_security_group.app.id]
```

It is declared **in-line inside the module's security group**, not as a separate
`aws_security_group_rule`, and that is not a style choice: the AWS provider does not support mixing
in-line rules with standalone rules on the same group. Applying the in-line set **removes** whatever
a standalone rule added, so a rule attached from outside is stripped on every apply and re-added by
every plan — a stack that never converges.

`restricted_source_ips` may be empty **only** if this is non-empty (or
`allow_cloudfront_prefix_list = true`). At least one source must be able to reach the production
port; a security group with no ingress at all is not a locked-down ALB, it is an unreachable one.
That is enforced by a `lifecycle.precondition`, so it fails at plan, not at apply.

## Listeners Created

| Port  | Protocol | Description             |
| ----- | -------- | ----------------------- |
| 443   | HTTPS    | Production traffic      |
| 10443 | HTTPS    | Test/staging traffic    |
| 80    | HTTP     | Redirect to HTTPS (301) |

## Inputs

| Name                         | Description                                | Type           | Default | Required                                |
| ---------------------------- | ------------------------------------------ | -------------- | ------- | --------------------------------------- |
| app_name                     | Name of the application                    | `string`       | n/a     | yes                                     |
| vpc_id                       | ID of the VPC where ALB will be created    | `string`       | n/a     | yes                                     |
| subnet_ids                   | List of subnet IDs for ALB deployment      | `list(string)` | n/a     | yes                                     |
| acm_certificate_arn          | ARN of ACM certificate for HTTPS listeners | `string`       | n/a     | yes                                     |
| route_53_zone_id             | Route 53 hosted zone ID for DNS records    | `string`       | `null`  | yes (when `create_route53_record=true`) |
| restricted_source_ips        | List of CIDR blocks allowed to access ALB  | `list(string)` | n/a     | yes                                     |
| alb_domain                   | Domain name for the ALB                    | `string`       | `null`  | yes (when `create_route53_record=true`) |
| alb_internal                 | Whether the ALB is internal                | `bool`         | `false` | no                                      |
| allow_cloudfront_prefix_list | Allow traffic from CloudFront prefix list  | `bool`         | `false` | no                                      |
| create_route53_record        | Whether to create Route 53 DNS record      | `bool`         | `true`  | no                                      |
| tags                         | Tags to apply to resources                 | `map(string)`  | `{}`    | no                                      |

> **Note:** When `create_route53_record = false` (e.g., using CloudFront), both `route_53_zone_id` and `alb_domain` become optional and can be omitted.

| `ingress_source_security_group_ids` | Security groups allowed to reach the production listener. Lets `restricted_source_ips` be empty. | `list(string)` | `[]` | no |
| `test_listener_source_ips` | CIDRs allowed on the :10443 blue/green test listener. **`[]` = no ingress (fail closed)** — see the BREAKING CHANGE section. | `list(string)` | `[]` | no |
| `enable_test_listener` | Create the :10443 test listener at all. Keep `true` for blue/green — CodeDeploy references its ARN. | `bool` | `true` | no |
| `ssl_policy` | TLS policy for the HTTPS listeners. Must be TLS 1.2+; legacy policies are rejected. | `string` | `ELBSecurityPolicy-TLS13-1-2-2021-06` | no |
| `idle_timeout` | Backend (ALB → target) idle timeout in seconds, 1–4000. A contract with the app — see "Idle timeout". | `number` | `60` | no |
| `access_logs_bucket` | S3 bucket for ALB access logs. Empty = disabled. | `string` | `""` | no |
## Outputs

| Name                          | Description                           |
| ----------------------------- | ------------------------------------- |
| id                            | The ID of the ALB                     |
| domain                        | The DNS name of the ALB               |
| alb_arn_suffix                | The ARN suffix for CloudWatch metrics |
| alb_security_group_id         | Security group ID of the ALB          |
| lb_listener_http_arn          | ARN of the HTTP listener              |
| lb_listener_http_prod_arn     | ARN of the production HTTPS listener  |
| lb_listener_http_test_arn     | ARN of the test HTTPS listener        |
| lb_listener_http_redirect_arn | ARN of the HTTP redirect listener     |

## Requirements

| Name      | Version  |
| --------- | -------- |
| terraform | >= 1.4.0 |
| aws       | >= 5.0.0 |

## License

Apache 2 Licensed. See LICENSE for full details.
