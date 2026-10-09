# AWS CloudFront Distribution Terraform Module

Terraform module which creates CloudFront distribution with ALB origin on AWS.

> ## UPGRADE NOTE — 2026-10-09. Three behaviour fixes, no new inputs.
>
> 1. **`enable_ipv6` now turns IPv6 on.** The distribution never set `is_ipv6_enabled`, so it took
>    the provider default `false` while `enable_ipv6` (default `true`) still published the AAAA
>    alias. Consumers on the default will see an in-place `is_ipv6_enabled: false -> true` in their
>    next plan. Set `enable_ipv6 = false` to keep IPv6 off; that also drops the AAAA record.
> 2. **Basic auth no longer forwards the credential.** The function now deletes `Authorization`
>    after checking it, so the origin never receives the shared basic-auth password. An origin
>    that read `Authorization` on a basic-auth-gated behaviour will stop seeing it. That includes
>    a Bearer scheme, which could never coexist with basic auth on the same request anyway. See
>    [Where does `Authorization` go?](#where-does-authorization-go).
> 3. **The VPC origin is `create_before_destroy`.** No plan change for existing stacks. See
>    [VPC origin replacement](#vpc-origin-replacement) for what it does and does not protect.

> ## 🚨 UPGRADE NOTE — 2026-09-24. A required variable, and a raised Terraform floor.
>
> ### 1. `cache_key_headers` is MANDATORY — unless you pin `cache_policy_id`
>
> `forwarded_headers` fed **both** the cache policy and the origin-request policy, which want
> opposite values, so every caller was wrong in one direction:
>
> - Include `Authorization` (which this README used to instruct API callers to do) and the bearer
>   token entered the **cache key**. Every token got its own entry, so the cache bought nothing, and
>   an authenticated response was then served from the edge for up to `max_ttl` — **one year by
>   default** — after the token was revoked.
> - Omit it and `Authorization` never reached the origin, while per-user responses were cached and
>   served **across** users.
>
> It is now split: `cache_key_headers` (the cache key) and `origin_request_headers` (forwarding to
> the origin, default `null` → `allViewer`). `forwarded_headers` still works as a **deprecated alias
> that maps to `origin_request_headers` ONLY** — never the cache key. Headers keep reaching your
> origin so nothing functional breaks; they stop entering the cache key, which was the vulnerability.
> Expect **one cold cache**.
>
> **`cache_key_headers` has no default and a `lifecycle.precondition` will stop your plan until you
> set it.** That is deliberate: a consumer who never touched `forwarded_headers` was *also* keying on
> five headers, so gating on `forwarded_headers` would have missed exactly the people who never read
> this note. No default can preserve everyone's behaviour, because the old variable did two jobs.
> To reproduce the old cache key exactly:
>
> ```hcl
> cache_key_headers = ["Host", "CloudFront-Forwarded-Proto", "CloudFront-Is-Desktop-Viewer",
>                      "CloudFront-Is-Mobile-Viewer", "CloudFront-Is-Tablet-Viewer"]
> ```
>
> `[]` is usually the right answer. **Never put a credential there.** If you pass `cache_policy_id`
> (e.g. the managed `CachingDisabled`), this module builds no cache policy and never asks you.
>
> ### 2. `required_version` is now `>= 1.4.0`
>
> This corrects a **pre-existing** declaration, not a new requirement: `variables.tf` has used the
> two-argument `optional(string, "")` form — which needs Terraform >= 1.3 — since well before this
> change, while the module declared `>= 1.0`. A caller on 1.0–1.2 got an HCL **parse error**, not a
> version error. 1.4.0 is this library's common floor.
>
> ### ⚠️ STILL OPEN — do not assume this area is finished
>
> The fix above covers *which headers* enter the cache key. Two neighbouring defects are **untouched**:
>
> - **`cookie_behavior = "all"` is hardcoded INTO THE CACHE KEY** and no variable exists to change
>   it. A session cookie is a credential: every session gets its own entries (so the cache does
>   nothing), and an authenticated response lives at the edge for that cookie value up to `max_ttl`,
>   surviving logout. Same shape as the `Authorization` defect, one door over.
> - **`default_ttl = 300` with `max_ttl = 31536000`** (one year) on a module that may front an API.
>   The split removes the credential-keyed entry; it does not shorten how long a correctly-keyed one
>   lives.
>
> Both change behaviour for every consumer and are held for their own decision.

> ⚠️ **MANDATORY — Origin mTLS for any origin you control.** When this distribution fronts an origin
> you own (ALB / custom origin), you **MUST** set `origin_client_certificate_arn` so CloudFront
> presents a client certificate that the origin verifies. A CloudFront **prefix list** or a
> **shared-secret header** alone is **NOT** sufficient access control — both only prove the request
> came from *some* CloudFront (the origin-facing IP ranges are shared across *all* AWS accounts, so
> anyone can point their own distribution at your origin and pass). Origin mTLS is the cryptographic
> proof that it is **this** distribution. Requires `aws >= 6.51.0` **and** the origin enforcing
> `mutual_authentication { mode = "verify" }` (ALB) against a trust store. Reference implementation:
> the `cloudfront-mtls-origins` project. (S3 origins → use OAC instead; in-VPC origins → prefer VPC
> origins/PrivateLink.)

## Features

This module supports creating:

- **CloudFront Distribution** - CDN distribution with ALB origin
- **Cache Policy** - Custom caching configuration
- **Origin Request Policy** - Header forwarding configuration
- **Route53 DNS Record** - Custom domain alias
- **Lambda@Edge** - Optional basic authentication
- **CloudFront Function** - Lightweight edge functions

## Usage

### Example 1: Basic CloudFront with ALB Origin

```terraform
module "cloudfront" {
  source = "../../modules/cloudfront"

  app_name        = "${var.environment}-${var.app_name}-web"
  alb_domain_name = module.alb.domain

  # Custom domain configuration
  custom_domain       = "www.example.com"
  acm_certificate_arn = module.acm.virginia_certificate_arn
  route_53_zone_id    = data.aws_route53_zone.public.id

  # Cache settings
  min_ttl     = 0
  default_ttl = 300    # 5 minutes
  max_ttl     = 86400  # 24 hours

  tags = {
    Environment = "production"
    Terraform   = "true"
  }
}
```

### Example 2: CloudFront with Basic Authentication

```terraform
module "cloudfront" {
  source = "../../modules/cloudfront"

  app_name        = "${var.environment}-${var.app_name}-staging"
  alb_domain_name = module.alb.domain

  custom_domain       = "staging.example.com"
  acm_certificate_arn = module.acm.virginia_certificate_arn
  route_53_zone_id    = data.aws_route53_zone.public.id

  # Enable basic authentication
  enable_default_auth = true
  basic_auth_username = var.cloudfront_auth_username
  basic_auth_password = var.cloudfront_auth_password

  # Cache settings
  min_ttl     = 0
  default_ttl = 300
  max_ttl     = 86400

  tags = {
    Environment = "staging"
    Terraform   = "true"
  }
}
```

### Example 3: CloudFront with Custom Cache Behaviors

```terraform
module "cloudfront" {
  source = "../../modules/cloudfront"

  app_name        = "${var.environment}-${var.app_name}-web"
  alb_domain_name = module.alb.domain

  custom_domain       = "www.example.com"
  acm_certificate_arn = module.acm.virginia_certificate_arn
  route_53_zone_id    = data.aws_route53_zone.public.id

  # Default cache settings
  min_ttl     = 0
  default_ttl = 300
  max_ttl     = 86400

  # Cache key: keep it short, never a credential. There is NO default — [] means "none".
  cache_key_headers = [
    "CloudFront-Is-Desktop-Viewer",
    "CloudFront-Is-Mobile-Viewer",
    "CloudFront-Is-Tablet-Viewer",
  ]

  # Origin forwarding: unset = allViewer, which already includes Authorization.
  # origin_request_headers = null

  # Additional cache behaviors
  cache_behaviors = [
    {
      path_pattern    = "/api/*"
      allowed_methods = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
      cached_methods  = ["GET", "HEAD"]
      cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
      enable_auth     = false
    },
    {
      path_pattern    = "/admin/*"
      allowed_methods = ["GET", "HEAD"]
      cached_methods  = ["GET", "HEAD"]
      enable_auth     = true  # Enable auth for admin paths
    }
  ]

  price_class = "PriceClass_200"

  tags = {
    Environment = "production"
    Terraform   = "true"
  }
}
```

### Example 4: CloudFront with Geographic Restrictions

```terraform
module "cloudfront" {
  source = "../../modules/cloudfront"

  app_name        = "${var.environment}-${var.app_name}-web"
  alb_domain_name = module.alb.domain

  custom_domain       = "www.example.com"
  acm_certificate_arn = module.acm.virginia_certificate_arn
  route_53_zone_id    = data.aws_route53_zone.public.id

  # Geographic restrictions
  geo_restriction_type      = "whitelist"
  geo_restriction_locations = ["JP", "US", "GB"]

  price_class = "PriceClass_200"

  tags = {
    Environment = "production"
    Terraform   = "true"
  }
}
```

## Price Class Options

| Price Class      | Edge Locations                                 | Cost    |
| ---------------- | ---------------------------------------------- | ------- |
| `PriceClass_100` | USA, Canada, Europe, Israel                    | Lowest  |
| `PriceClass_200` | PriceClass_100 + Asia (Japan, Singapore, etc.) | Medium  |
| `PriceClass_All` | All worldwide edge locations                   | Highest |

## AWS Managed Policies vs Custom Policies

This module supports both **AWS Managed Policies** and **Custom Policies**. For most use cases, **AWS Managed Policies are recommended** as they handle edge cases and restricted headers properly.

📚 **Official Documentation:**

- [Managed Cache Policies](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-cache-policies.html)
- [Managed Origin Request Policies](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-origin-request-policies.html)

### When to use Managed Policies

| Use Case                                         | Cache Policy       | Origin Request Policy       |
| ------------------------------------------------ | ------------------ | --------------------------- |
| **API Server (no cache, forward Authorization)** | `CachingDisabled`  | `AllViewerExceptHostHeader` |
| **Static Website**                               | `CachingOptimized` | `CORS-S3Origin`             |
| **Web App with dynamic content**                 | `CachingOptimized` | `AllViewer`                 |

### Managed Cache Policy IDs

| Policy Name                              | ID                                     | Description                                              |
| ---------------------------------------- | -------------------------------------- | -------------------------------------------------------- |
| `CachingDisabled`                        | `4135ea2d-6df8-44a3-9df3-4b5a84be39ad` | No caching, forward all query strings. **Use for APIs.** |
| `CachingOptimized`                       | `658327ea-f89d-4fab-a63d-7e88639e58f6` | Optimized for static content                             |
| `CachingOptimizedForUncompressedObjects` | `b2884449-e4de-46a7-ac36-70bc7f1ddd6d` | Large uncompressed files                                 |
| `Amplify`                                | `2e54312d-136d-493c-8eb9-b001f22f67d2` | AWS Amplify applications                                 |

### Managed Origin Request Policy IDs

| Policy Name                             | ID                                     | Description                                                                                 |
| --------------------------------------- | -------------------------------------- | ------------------------------------------------------------------------------------------- |
| `AllViewerExceptHostHeader`             | `b689b0a8-53d0-40ab-baf2-68738e2966ac` | Forwards all headers **including Authorization** (except Host). **Use for APIs with auth.** |
| `AllViewer`                             | `216adef6-5c7f-47e4-b989-5492eafa07d3` | Forwards all viewer headers                                                                 |
| `AllViewerAndCloudFrontHeaders-2022-06` | `33f36d7e-f396-46d9-90e0-52428a34d9dc` | All headers + CloudFront headers                                                            |
| `CORS-S3Origin`                         | `88a5eaf4-2fd4-4709-b370-b4c650ea3fcf` | CORS headers for S3 origin                                                                  |
| `CORS-CustomOrigin`                     | `59781a5b-3903-41f3-afcb-af62929ccde1` | CORS headers for custom origin                                                              |
| `UserAgentRefererHeaders`               | `acba4595-bd28-49b8-b9fe-13317c0390fa` | Only User-Agent and Referer                                                                 |

### Example: API Server with Authentication

```terraform
module "cloudfront_api" {
  source = "../../modules/cloudfront"

  app_name        = "${var.environment}-${var.app_name}-api"
  alb_domain_name = module.alb.domain

  custom_domain       = "api.example.com"
  acm_certificate_arn = module.acm.virginia_certificate_arn
  route_53_zone_id    = data.aws_route53_zone.public.id

  # Use AWS Managed Policies (RECOMMENDED for APIs)
  cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
  origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # AllViewerExceptHostHeader

  price_class = "PriceClass_200"
  tags        = local.tags
}
```

> ⚠️ **Important:** When using `cache_policy_id` and `origin_request_policy_id`, the module will skip creating custom policies and use the managed ones instead.

> ⚠️ **Warning:** `Authorization` header is a **restricted header** in CloudFront. You cannot add it to custom Origin Request Policies. Use managed policy `AllViewerExceptHostHeader` instead!

## Inputs

| Name                      | Description                                | Type           | Default            | Required |
| ------------------------- | ------------------------------------------ | -------------- | ------------------ | :------: |
| app_name                  | Application name for resource naming       | `string`       | n/a                |   yes    |
| alb_domain_name           | ALB DNS name (origin)                      | `string`       | n/a                |   yes    |
| custom_domain             | Custom domain for CloudFront               | `string`       | `""`               |    no    |
| acm_certificate_arn       | ACM certificate ARN (must be in us-east-1) | `string`       | `""`               |    no    |
| origin_client_certificate_arn | Origin mTLS: ACM client-cert ARN (us-east-1, EKU clientAuth) CloudFront presents to the origin. `""` disables. Needs aws >= 6.51.0 | `string` | `""`     |    no    |
| route_53_zone_id          | Route 53 hosted zone ID                    | `string`       | `""`               |    no    |
| cache_key_headers         | Headers in the CACHE KEY (never a credential) | `list(string)` | **none — required** |   yes    |
| origin_request_headers    | Headers forwarded TO THE ORIGIN            | `list(string)` | `null` (allViewer) |    no    |
| forwarded_headers         | **DEPRECATED** — alias for origin_request_headers | `list(string)` | `null`     |    no    |
| min_ttl                   | Minimum TTL for cache                      | `number`       | `0`                |    no    |
| default_ttl               | Default TTL for cache                      | `number`       | `300`              |    no    |
| max_ttl                   | Maximum TTL for cache                      | `number`       | `31536000`         |    no    |
| cache_behaviors           | Additional cache behaviors                 | `list(object)` | `[]`               |    no    |
| geo_restriction_type      | Geographic restriction type                | `string`       | `"none"`           |    no    |
| geo_restriction_locations | Country codes for restrictions             | `list(string)` | `[]`               |    no    |
| price_class               | CloudFront price class                     | `string`       | `"PriceClass_All"` |    no    |
| enable_logging            | Enable access logging                      | `bool`         | `false`            |    no    |
| enable_ipv6               | IPv6 on the distribution (`is_ipv6_enabled`) and the AAAA alias | `bool` | `true`   |    no    |
| enable_default_auth       | Enable basic authentication                | `bool`         | `false`            |    no    |
| basic_auth_username       | Username for basic auth                    | `string`       | `"admin"`          |    no    |
| basic_auth_password       | Password for basic auth                    | `string`       | `""`               |    no    |
| tags                      | Tags to apply to resources                 | `map(string)`  | `{}`               |    no    |

## Outputs

| Name                        | Description                                |
| --------------------------- | ------------------------------------------ |
| cloudfront_distribution_id  | ID of the CloudFront distribution          |
| cloudfront_distribution_arn | ARN of the CloudFront distribution         |
| cloudfront_domain_name      | Domain name of the CloudFront distribution |
| cloudfront_hosted_zone_id   | Hosted zone ID of CloudFront               |
| custom_domain               | Custom domain name (if configured)         |
| cloudfront_status           | Status of the CloudFront distribution      |
| cloudfront_function_arn     | ARN of the CloudFront Function             |
| access_urls                 | Map of available access URLs               |

## Headers: cache key vs origin forwarding

These are **two different questions** and they want opposite answers. The module used to ask them
with one variable, `forwarded_headers`, which meant every caller was wrong in one direction:

- Put `Authorization` in it — as an earlier version of this README instructed — and the bearer token
  entered the **cache key**. Every token got its own cache entry, so the cache bought nothing, and
  an authenticated response was then served from the edge for up to `max_ttl` (one year by default)
  after the token was revoked or the data changed.
- Leave it out and `Authorization` **never reached the origin**, while responses that vary per user
  were cached and served **across** users.

So the variable was split.

| Variable | Feeds | Default | Rule of thumb |
| --- | --- | --- | --- |
| `cache_key_headers` | the **cache key** | **none — you must set it** | as SHORT as possible. **Never a credential.** `[]` is usually right. |
| `origin_request_headers` | what **reaches the origin** | `null` → `allViewer` | leave it alone unless you mean to withhold something |

### Where does `Authorization` go?

**`origin_request_headers`, never `cache_key_headers`** — and with the default (`null` → `allViewer`)
you do not need to name it at all. It already reaches the origin.

Putting a credential in the cache key is not a tuning mistake, it is a data-leak shape: responses
keyed by token, served from the edge long after the token stops being valid.

**Behind basic auth, `Authorization` never reaches the origin.** On a behaviour with basic auth
enabled (`enable_default_auth`, or `enable_auth` on a cache behaviour), the viewer's `Authorization`
header *is* the basic-auth credential. The function checks it and then deletes it, so the origin
sees no `Authorization` at all. An application that needs its own `Authorization` scheme (for
example Bearer) cannot share a behaviour with basic auth. It would need the gate removed, or a
different header.

### ⚠️ Upgrading across the split: `cache_key_headers` has NO default

It is deliberately required. Before the split this module keyed the cache on five headers by
default; if `cache_key_headers` defaulted to `[]` an upgrade would silently NARROW every existing
consumer's cache key to `none`. A `lifecycle.precondition` on the cache policy fails at **plan**
until you choose:

```terraform
cache_key_headers = []                      # no header in the key — usually right
# or, to reproduce the pre-split behaviour exactly:
cache_key_headers = ["Host", "CloudFront-Forwarded-Proto", "CloudFront-Is-Desktop-Viewer",
                     "CloudFront-Is-Mobile-Viewer", "CloudFront-Is-Tablet-Viewer"]
```

A caller passing `cache_policy_id` skips the module's cache policy entirely and is never asked.

### API server (NestJS, Express, …)

```terraform
cache_key_headers = [] # decide explicitly; an API keys on nothing
# Otherwise nothing to configure. allViewer forwards Authorization, Origin,
# Access-Control-Request-*, Content-Type and the rest; the cache key stays empty.
# If the API must never be cached, pass the AWS-managed CachingDisabled policy instead:
#   cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
```

### Web application (Nuxt/Next SSR)

```terraform
# Only if the server renders DIFFERENT HTML per device class. If it ships responsive CSS and the
# HTML is identical, leave this empty — these headers would triple the cache entries for nothing.
cache_key_headers = [
  "CloudFront-Is-Desktop-Viewer",
  "CloudFront-Is-Mobile-Viewer",
  "CloudFront-Is-Tablet-Viewer",
]
# origin_request_headers: leave unset (allViewer).
```

Note what is **not** in that list. `Host` is constant on a single-alias distribution and
`CloudFront-Forwarded-Proto` is constant when the viewer policy is `redirect-to-https`; a constant
header in a cache key fragments nothing and buys nothing.

### `forwarded_headers` is DEPRECATED

It still works and now maps to **`origin_request_headers` only** — never to the cache key. Headers
keep reaching your origin, so nothing functional breaks; they stop entering the cache key, which was
the vulnerability. Expect **one cold cache** after upgrading. Its default also changed from a
five-header list to `null`, so a caller who sets nothing now gets `allViewer` instead of a whitelist
that silently dropped `Authorization`.

It is deliberately **not** mapped to both variables: that would preserve the defect under a new name.

## VPC origin replacement

`aws_cloudfront_vpc_origin` is `create_before_destroy`. AWS creates a service-managed security
group, `CloudFront-VPCOrigins-Service-SG`, the first time a VPC origin is created in a VPC. AWS also
**deletes** that group when the last VPC origin in the VPC is deleted. Consumers that allow
CloudFront into their ALB by looking that group up by name (`data "aws_security_group"`) depend
on it existing. With destroy-first, replacing the only VPC origin in a VPC would remove the group
mid-apply.

What this does **not** cover. These limits are real, so read them before relying on it:

- **It narrows the window. It does not decouple the lookup from the resource.** If the last VPC
  origin in the VPC is ever removed rather than replaced (for example `enable_vpc_origin = false`,
  or a destroy), AWS deletes the service SG. Any `data` lookup of it then fails at **plan** time,
  whatever this lifecycle says.
- **It propagates to dependencies.** Terraform applies `create_before_destroy` to everything this
  resource depends on, which in practice is the ALB whose ARN it carries. An ALB with a fixed `name`
  that ever has to be **replaced** would then try to create its successor under the same name and
  fail. In-place ALB changes are unaffected.
- **Duplicate VPC origins are unverified.** `CreateVpcOrigin` documents `EntityAlreadyExists` but
  not which field must be unique. If AWS refuses a second VPC origin with the same name or origin ARN
  while the old one exists, the replacement fails at the create step. The old origin and the
  service SG are left intact, so nothing is lost, but the apply does not complete.

## Requirements

| Name      | Version  |
| --------- | -------- |
| terraform | >= 1.4.0 |
| aws       | >= 5.0.0 |

## Notes

- ACM certificate must be in `us-east-1` region for CloudFront
- Basic authentication uses CloudFront Functions (lighter than Lambda@Edge)
- Distribution deployment may take 15-30 minutes

## When to Use CloudFront

CloudFront is **NOT always necessary**. Consider your use case:

### ✅ **USE CloudFront when:**

| Scenario                                | Benefit                                            |
| --------------------------------------- | -------------------------------------------------- |
| **Users worldwide** (US, EU, Asia)      | AWS Private Backbone reduces latency significantly |
| **Static content** (S3, images, JS/CSS) | Caching at edge = faster + cheaper                 |
| **DDoS protection needed**              | AWS Shield Standard (free) included                |
| **WAF (Web Application Firewall)**      | Easy to attach                                     |
| **Basic auth for staging**              | CloudFront Functions for authentication            |

### ❌ **SKIP CloudFront when:**

| Scenario                                                             | Reason                                       |
| -------------------------------------------------------------------- | -------------------------------------------- |
| **Users only in same region as ALB** (e.g., Japan users + Tokyo ALB) | No latency benefit, just adds cost           |
| **API with no caching**                                              | CloudFront adds ~$8-10/month with no benefit |
| **Low budget staging**                                               | Direct ALB is simpler and cheaper            |

### 💰 **Cost Comparison (1000 users/day, ~100K requests/day):**

| Setup                            | Monthly Cost |
| -------------------------------- | ------------ |
| ALB only                         | ~$20         |
| ALB + CloudFront (API, no cache) | ~$28-30      |
| CloudFront + S3 (static)         | ~$3-6        |

### 🌏 **Latency Comparison:**

```
Users in JAPAN → Tokyo ALB:
  Without CloudFront: ~10-15ms ✅
  With CloudFront:    ~10-15ms ✅ (no difference)

Users in USA → Tokyo ALB:
  Without CloudFront: ~150-200ms (public internet, unstable)
  With CloudFront:    ~100-130ms ✅ (AWS backbone, stable)
```

### 📋 **Decision Guide:**

```
┌─────────────────────────────────────────┐
│         Where are your users?          │
└─────────────────┬───────────────────────┘
                  │
        ┌─────────┴─────────┐
        ▼                   ▼
   Same region          Global
   (e.g., Japan)        (US, EU, Asia)
        │                   │
        ▼                   ▼
┌───────────────┐   ┌───────────────────┐
│ Static files? │   │ Use CloudFront ✅ │
└───────┬───────┘   │ - Caching benefit │
        │           │ - AWS backbone    │
   ┌────┴────┐      │ - DDoS protection │
   ▼         ▼      └───────────────────┘
  Yes       No (API)
   │         │
   ▼         ▼
┌────────┐ ┌─────────────────┐
│Use CF ✅│ │Skip CloudFront ❌│
│Caching │ │Use ALB directly │
└────────┘ │Cost saving      │
           └─────────────────┘
```

### Example: Japan-only API (No CloudFront)

```terraform
# Direct ALB without CloudFront - for Japan-only users
module "alb_server" {
  source = "../../modules/alb"

  app_name = "${var.environment}-${var.app_name}-server"
  vpc_id   = module.vpc.vpc_id

  # Allow from anywhere (or restrict to specific IPs)
  restricted_source_ips = ["0.0.0.0/0"]

  subnet_ids          = module.vpc.public_subnet_ids
  alb_internal        = false
  acm_certificate_arn = module.acm.certificate_arn

  # Create Route53 record directly for ALB
  create_route53_record = true
  route_53_zone_id      = data.aws_route53_zone.public.id
  alb_domain            = "api.example.com"

  tags = local.tags
}
```

### Example: Global API (With CloudFront)

```terraform
# ALB behind CloudFront - for global users
module "alb_server" {
  source = "../../modules/alb"

  app_name = "${var.environment}-${var.app_name}-server-cdn"
  vpc_id   = module.vpc.vpc_id

  # Only allow traffic from CloudFront
  restricted_source_ips        = []
  allow_cloudfront_prefix_list = true

  subnet_ids          = module.vpc.public_subnet_ids
  alb_internal        = false
  acm_certificate_arn = module.acm.certificate_arn

  # Skip Route53 - CloudFront will handle DNS
  create_route53_record = false

  tags = local.tags
}

module "cloudfront_api" {
  source = "../../modules/cloudfront"

  app_name        = "${var.environment}-${var.app_name}-api"
  alb_domain_name = module.alb_server.domain

  custom_domain       = "api.example.com"
  acm_certificate_arn = module.acm.virginia_certificate_arn
  route_53_zone_id    = data.aws_route53_zone.public.id

  # Use AWS Managed Policies for API
  cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
  origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # AllViewerExceptHostHeader

  price_class = "PriceClass_200"
  tags        = local.tags
}
```

## License

Apache 2 Licensed. See LICENSE for full details.
