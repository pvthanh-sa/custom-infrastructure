# CloudFront distribution for ALB

locals {
  # Create the basic-auth CloudFront Function only when auth is actually used — by the default
  # cache behavior or by any ordered cache behavior. Prevents an orphan function when auth is off.
  create_auth_function = var.enable_default_auth || anytrue([for b in var.cache_behaviors : b.enable_auth])

  # Deprecated alias resolution, in ONE place. forwarded_headers feeds the ORIGIN REQUEST policy
  # only; it can never reach the cache key. null on both -> allViewer.
  origin_request_headers = var.origin_request_headers != null ? var.origin_request_headers : var.forwarded_headers
}

# VPC origin — lets CloudFront reach a PRIVATE (internal) ALB through AWS-managed ENIs inside the
# VPC. The origin never gets a public IP, so nothing on the internet can bypass CloudFront; this
# replaces the origin-mTLS lock for in-VPC origins. No additional charge. Requires aws >= 5.77.
resource "aws_cloudfront_vpc_origin" "main" {
  count = var.enable_vpc_origin ? 1 : 0

  vpc_origin_endpoint_config {
    name                   = "${var.app_name}-vpc-origin"
    arn                    = var.vpc_origin_endpoint_arn
    http_port              = 80
    https_port             = var.vpc_origin_https_port
    origin_protocol_policy = var.vpc_origin_protocol_policy

    origin_ssl_protocols {
      items    = var.vpc_origin_ssl_protocols
      quantity = length(var.vpc_origin_ssl_protocols)
    }
  }

  lifecycle {
    precondition {
      condition     = var.vpc_origin_endpoint_arn != ""
      error_message = "vpc_origin_endpoint_arn is required when enable_vpc_origin = true."
    }
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.app_name}-vpc-origin"
    }
  )
}

resource "aws_cloudfront_distribution" "main" {

  origin {
    domain_name = var.alb_domain_name
    origin_id   = "ALB-${var.app_name}"

    # Private path: route origin fetches through the VPC origin (internal ALB, no public exposure).
    dynamic "vpc_origin_config" {
      for_each = var.enable_vpc_origin ? [1] : []
      content {
        vpc_origin_id = aws_cloudfront_vpc_origin.main[0].id
      }
    }

    # Public path (backward-compatible default): custom origin over the internet — MUST be locked
    # with origin mTLS when the origin is an ALB/custom origin you control.
    dynamic "custom_origin_config" {
      for_each = var.enable_vpc_origin ? [] : [1]
      content {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "https-only"
        origin_ssl_protocols   = ["TLSv1.2"]

        # Origin mTLS — CloudFront presents this ACM client cert (us-east-1, EKU clientAuth) to the
        # origin on every origin TLS handshake; the origin verifies it. MANDATORY when fronting a
        # public origin you control — a prefix list / shared-secret header alone is NOT sufficient
        # (CloudFront IP ranges are shared across all AWS accounts). Empty arn = disabled.
        # Requires aws >= 6.51.0 + ALB mutual_authentication mode=verify on the origin side.
        dynamic "origin_mtls_config" {
          for_each = var.origin_client_certificate_arn != "" ? [1] : []
          content {
            client_certificate_arn = var.origin_client_certificate_arn
          }
        }
      }
    }
  }

  enabled = true
  comment = "CloudFront distribution for ${var.app_name} with CloudFront Function auth"

  # Custom domain aliases (optional)
  aliases = var.custom_domain != "" ? [var.custom_domain] : []

  default_cache_behavior {
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "ALB-${var.app_name}"
    compress               = true
    viewer_protocol_policy = "redirect-to-https"

    # Modern approach using cache policies instead of deprecated forwarded_values
    cache_policy_id          = var.cache_policy_id != "" ? var.cache_policy_id : aws_cloudfront_cache_policy.main[0].id
    origin_request_policy_id = var.origin_request_policy_id != "" ? var.origin_request_policy_id : aws_cloudfront_origin_request_policy.main[0].id

    # Optional response headers policy
    response_headers_policy_id = var.response_headers_policy_id != "" ? var.response_headers_policy_id : null

    # Optional CloudFront Function for authentication
    dynamic "function_association" {
      for_each = var.enable_default_auth ? [1] : []
      content {
        event_type   = "viewer-request"
        function_arn = aws_cloudfront_function.basic_auth[0].arn
      }
    }
  }

  # Additional cache behaviors for specific paths (optional)
  dynamic "ordered_cache_behavior" {
    for_each = var.cache_behaviors
    content {
      path_pattern           = ordered_cache_behavior.value.path_pattern
      allowed_methods        = ordered_cache_behavior.value.allowed_methods
      cached_methods         = ordered_cache_behavior.value.cached_methods
      target_origin_id       = "ALB-${var.app_name}"
      compress               = true
      viewer_protocol_policy = "redirect-to-https"

      # Modern approach using cache policies instead of deprecated forwarded_values
      cache_policy_id          = lookup(ordered_cache_behavior.value, "cache_policy_id", "") != "" ? ordered_cache_behavior.value.cache_policy_id : aws_cloudfront_cache_policy.main[0].id
      origin_request_policy_id = lookup(ordered_cache_behavior.value, "origin_request_policy_id", "") != "" ? ordered_cache_behavior.value.origin_request_policy_id : aws_cloudfront_origin_request_policy.main[0].id

      # Optional response headers policy for ordered cache behaviors
      response_headers_policy_id = lookup(ordered_cache_behavior.value, "response_headers_policy_id", "") != "" ? ordered_cache_behavior.value.response_headers_policy_id : null

      # Add function association support for ordered cache behaviors
      dynamic "function_association" {
        for_each = lookup(ordered_cache_behavior.value, "enable_auth", false) ? [1] : []
        content {
          event_type   = "viewer-request"
          function_arn = aws_cloudfront_function.basic_auth[0].arn
        }
      }
    }
  }

  # Geographic restrictions
  restrictions {
    geo_restriction {
      restriction_type = var.geo_restriction_type
      locations        = var.geo_restriction_locations
    }
  }

  # SSL Certificate configuration
  viewer_certificate {
    # Use custom domain certificate if provided, otherwise use default
    acm_certificate_arn            = var.custom_domain != "" ? var.acm_certificate_arn : null
    ssl_support_method             = var.custom_domain != "" ? "sni-only" : null
    minimum_protocol_version       = var.custom_domain != "" ? "TLSv1.2_2021" : null
    cloudfront_default_certificate = var.custom_domain == "" ? true : null
  }

  # Price class - controls which edge locations to use
  price_class = var.price_class

  # WAF Web ACL association (must be CLOUDFRONT scope, created in us-east-1)
  web_acl_id = var.web_acl_arn != "" ? var.web_acl_arn : null

  # Logging configuration (optional)
  dynamic "logging_config" {
    for_each = var.enable_logging ? [1] : []
    content {
      include_cookies = false
      bucket          = var.logging_bucket
      prefix          = var.logging_prefix
    }
  }

  tags = var.tags
}

# CloudFront Function for basic authentication (optional) — created only when auth is used
# (var.enable_default_auth, or any cache_behaviors[*].enable_auth). See local.create_auth_function.
resource "aws_cloudfront_function" "basic_auth" {
  count = local.create_auth_function ? 1 : 0

  name    = "${var.app_name}-cloudfront-auth"
  runtime = "cloudfront-js-1.0"
  comment = "Basic authentication for ${var.app_name}"
  publish = true
  code = templatefile(
    "${path.module}/basic_auth.js",
    {
      authString = base64encode("${var.basic_auth_username}:${var.basic_auth_password}")
    }
  )
}

# CloudFront Cache Policy
resource "aws_cloudfront_cache_policy" "main" {
  count = var.cache_policy_id == "" ? 1 : 0

  name        = "${var.app_name}-cache-policy"
  comment     = "Cache policy for ${var.app_name}"
  default_ttl = var.default_ttl
  max_ttl     = var.max_ttl
  min_ttl     = var.min_ttl

  # Upgrading across the forwarded_headers split must not silently narrow anyone's cache key.
  # Before the split this module keyed on five headers by default; after it, an unset value would
  # mean "none". A consumer is not allowed to inherit that change — they decide once, explicitly.
  #
  # A lifecycle.precondition rather than a variable validation because a validation block cannot
  # read another variable below Terraform 1.9, and this module supports older callers. A
  # precondition needs 1.2, which costs nothing here: versions.tf already floors this module at
  # 1.4.0 for the two-argument optional() in variables.tf, so the precondition adds no requirement
  # a caller does not already meet.
  #
  # This fires only when the module actually builds the cache policy. A caller passing
  # cache_policy_id skips the resource entirely (count = 0 above) and is never asked.
  lifecycle {
    precondition {
      condition     = var.cache_key_headers != null
      error_message = "cache_key_headers must be set explicitly. This module used to key the cache on five headers by default; leaving it unset after the forwarded_headers split would silently narrow your cache key to 'none'. Choose: [] for no headers in the key (usually right), or name the headers that genuinely vary the response. To keep the old behaviour exactly, pass [\"Host\", \"CloudFront-Forwarded-Proto\", \"CloudFront-Is-Desktop-Viewer\", \"CloudFront-Is-Mobile-Viewer\", \"CloudFront-Is-Tablet-Viewer\"]. NEVER put a credential (Authorization, Cookie) here."
    }
  }

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true

    query_strings_config {
      query_string_behavior = "all"
    }

    # CACHE KEY. Driven by cache_key_headers alone — forwarded_headers can no longer reach here,
    # which is the whole point of the split: a credential in this list gives every token its own
    # cache entry and then serves an authenticated response from the edge for up to max_ttl.
    headers_config {
      header_behavior = length(coalesce(var.cache_key_headers, [])) > 0 ? "whitelist" : "none"
      dynamic "headers" {
        for_each = length(coalesce(var.cache_key_headers, [])) > 0 ? [1] : []
        content {
          items = var.cache_key_headers
        }
      }
    }

    cookies_config {
      cookie_behavior = "all"
    }
  }
}

# CloudFront Origin Request Policy
resource "aws_cloudfront_origin_request_policy" "main" {
  count = var.origin_request_policy_id == "" ? 1 : 0

  name    = "${var.app_name}-origin-request-policy"
  comment = "Origin request policy for ${var.app_name}"

  cookies_config {
    cookie_behavior = "all"
  }

  # ORIGIN FORWARDING. Defaults to allViewer so a header the origin needs is never silently
  # withheld; an explicit list withholds on purpose.
  headers_config {
    header_behavior = local.origin_request_headers != null && length(local.origin_request_headers) > 0 ? "whitelist" : "allViewer"
    dynamic "headers" {
      for_each = local.origin_request_headers != null && length(local.origin_request_headers) > 0 ? [1] : []
      content {
        items = local.origin_request_headers
      }
    }
  }

  query_strings_config {
    query_string_behavior = "all"
  }
}

# Route53 record for custom domain
resource "aws_route53_record" "cloudfront_domain" {
  count = var.custom_domain != "" && var.route_53_zone_id != "" ? 1 : 0

  zone_id = var.route_53_zone_id
  name    = var.custom_domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}

# Route53 record for AAAA (IPv6) support
resource "aws_route53_record" "cloudfront_domain_ipv6" {
  count = var.custom_domain != "" && var.route_53_zone_id != "" && var.enable_ipv6 ? 1 : 0

  zone_id = var.route_53_zone_id
  name    = var.custom_domain
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}
