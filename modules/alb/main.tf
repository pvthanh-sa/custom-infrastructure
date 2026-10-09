resource "aws_security_group" "security_group" {
  # name_prefix, NOT name (changed 2026-09-24 — see the migration note in README.md).
  #
  # aws_security_group.name is ForceNew: the EC2 API cannot rename a security group, so any change
  # that forces replacement destroys and recreates it. Combined with create_before_destroy below —
  # which this module needs, because the SG is referenced by an aws_lb that cannot be left without
  # one — the new SG is created BEFORE the old one is destroyed. With a fixed name both exist at
  # once under the same name, and EC2 rejects that with InvalidGroup.Duplicate. The apply then
  # deadlocks: Terraform cannot go forward (name taken) or back (resource tainted). Recovering it
  # takes `terraform untaint`, which is not something a consumer should have to know.
  #
  # name_prefix lets AWS append a unique suffix, so the two can coexist during the swap. The Name
  # TAG below stays pinned to "${var.app_name}-alb" so operators still find it by the name they
  # expect — only the API-level name becomes generated.
  name_prefix = "${var.app_name}-alb-"
  vpc_id      = var.vpc_id

  # Every block below is gated on THE LIST THAT FEEDS IT, never on an unrelated flag.
  #
  # These three were previously emitted unconditionally (the :443/:80 pair) or gated on
  # enable_test_listener (the ICMP one) while all three draw their source from
  # restricted_source_ips. With restricted_source_ips = [] that produced ingress rules with
  # cidr_blocks = [] and no other source either — an IpPermission with nothing in it. The EC2 API
  # rejects that, so "SG-only ingress", the capability this fork exists to provide, could not
  # actually be used. Gate each block on its own source list and the rule simply is not emitted.

  # Production port, from CIDRs.
  dynamic "ingress" {
    for_each = length(var.restricted_source_ips) > 0 ? [1] : []
    content {
      from_port   = local.prod_listener_port
      to_port     = local.prod_listener_port
      protocol    = "tcp"
      cidr_blocks = var.restricted_source_ips
      description = "HTTPS from restricted_source_ips"
    }
  }

  # Port 80, from CIDRs, for the HTTP->HTTPS redirect.
  dynamic "ingress" {
    for_each = length(var.restricted_source_ips) > 0 ? [1] : []
    content {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = var.restricted_source_ips
      description = "HTTP from restricted_source_ips (redirected to HTTPS)"
    }
  }

  # ICMP, from CIDRs — troubleshooting alongside the test path. Needs BOTH a source to draw from
  # and the test path to be enabled.
  dynamic "ingress" {
    for_each = var.enable_test_listener && length(var.restricted_source_ips) > 0 ? [1] : []
    content {
      from_port   = -1
      to_port     = -1
      protocol    = "icmp"
      cidr_blocks = var.restricted_source_ips
      description = "ICMP from restricted_source_ips (network troubleshooting)"
    }
  }

  # Test-listener port, from CIDRs the caller NAMES. FAIL CLOSED: an empty list means no ingress,
  # never "the whole VPC".
  #
  # This is not a spare debug port. The consuming stack points a listener rule with
  # path_pattern ["*"] at the green target group, so every source allowed here reaches the entire
  # application, unauthenticated, during every blue/green shift — bypassing CloudFront, WAF and any
  # edge authentication. The previous default resolved [] to every CIDR associated with the VPC,
  # which handed that reach to any host in a consumer's VPC without anyone asking for it.
  # A module default must never grant access; a consumer that wants test traffic says where from.
  dynamic "ingress" {
    for_each = var.enable_test_listener && length(var.test_listener_source_ips) > 0 ? [1] : []
    content {
      from_port   = local.test_listener_port
      to_port     = local.test_listener_port
      protocol    = "tcp"
      cidr_blocks = var.test_listener_source_ips
      description = "Blue/green test listener"
    }
  }

  # Allow traffic to port 443 from specific source security groups (in-VPC callers).
  # Declared in-line on purpose: a standalone aws_security_group_rule would be wiped by every
  # apply of this resource — see var.ingress_source_security_group_ids.
  dynamic "ingress" {
    for_each = length(var.ingress_source_security_group_ids) > 0 ? [1] : []
    content {
      from_port       = local.prod_listener_port
      to_port         = local.prod_listener_port
      protocol        = "tcp"
      security_groups = var.ingress_source_security_group_ids
      description     = "Allow HTTPS from the given source security groups"
    }
  }

  # Allow traffic from CloudFront prefix list if provided
  dynamic "ingress" {
    for_each = var.allow_cloudfront_prefix_list ? [1] : []
    content {
      from_port       = local.prod_listener_port
      to_port         = local.prod_listener_port
      protocol        = "tcp"
      prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront[0].id]
      description     = "Allow CloudFront managed prefix list"
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound (ALB health checks and target connections)"
  }


  tags = merge(
    var.tags,
    {
      Name = "${var.app_name}-alb"
    }
  )

  lifecycle {
    create_before_destroy = true

    # At least one source that can reach the PRODUCTION port must be supplied. Three things can:
    # restricted_source_ips (CIDRs), ingress_source_security_group_ids (source SGs), and
    # allow_cloudfront_prefix_list (the managed prefix list). Any one of them is enough.
    #
    # test_listener_source_ips is deliberately NOT accepted here: it only opens :10443, so a caller
    # supplying nothing else would get an ALB whose real service port is unreachable while the
    # precondition said everything was fine.
    #
    # allow_cloudfront_prefix_list IS accepted, because an internet-facing origin fronted only by
    # CloudFront is a legitimate shape this module supports; rejecting it would fail a caller who
    # is correct.
    #
    # A precondition rather than a variable validation on purpose: a validation block that reads
    # another variable needs Terraform >= 1.9, and this module supports >= 1.4.
    precondition {
      condition     = length(var.restricted_source_ips) > 0 || length(var.ingress_source_security_group_ids) > 0 || var.allow_cloudfront_prefix_list
      error_message = "No ingress source for the production listener. Supply at least one of restricted_source_ips, ingress_source_security_group_ids, or allow_cloudfront_prefix_list. All three empty produces a load balancer nothing can reach — that is not a locked-down ALB, it is a broken one, and the failure is silent until someone tries to use the service. (test_listener_source_ips does not count: it opens only the blue/green test port.)"
    }
  }
}

resource "aws_lb" "alb" {
  name               = "${var.app_name}-alb"
  load_balancer_type = "application"

  security_groups = [aws_security_group.security_group.id]
  subnets         = var.subnet_ids
  internal        = var.alb_internal

  # Backend (ALB -> target) idle timeout. Explicit at the AWS default so it is readable from code.
  # It is a contract with the application: a Node target MUST hold connections longer than this
  # (keepAliveTimeout = idle_timeout + 5s, headersTimeout = +6s) or the ALB reuses a socket the
  # target already closed and returns an intermittent 502. See var.idle_timeout.
  idle_timeout = var.idle_timeout

  drop_invalid_header_fields = true

  dynamic "access_logs" {
    for_each = var.access_logs_bucket != "" ? [1] : []
    content {
      bucket  = var.access_logs_bucket
      enabled = true
    }
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.app_name}-alb"
    }
  )
}

# Origin mTLS trust store (created only when mTLS=verify and no existing trust store was passed).
resource "aws_lb_trust_store" "this" {
  count = local.create_trust_store ? 1 : 0

  name_prefix                              = substr("${var.app_name}-ts-", 0, 26)
  ca_certificates_bundle_s3_bucket         = var.mutual_auth_ca_bundle_s3_bucket
  ca_certificates_bundle_s3_key            = var.mutual_auth_ca_bundle_s3_key
  ca_certificates_bundle_s3_object_version = var.mutual_auth_ca_bundle_s3_object_version != "" ? var.mutual_auth_ca_bundle_s3_object_version : null

  tags = merge(var.tags, { Name = "${var.app_name}-alb-trust-store" })

  lifecycle {
    precondition {
      condition     = var.mutual_auth_ca_bundle_s3_bucket != "" && var.mutual_auth_ca_bundle_s3_key != ""
      error_message = "enable_mutual_auth (verify) with no mutual_auth_trust_store_arn requires mutual_auth_ca_bundle_s3_bucket and mutual_auth_ca_bundle_s3_key."
    }
  }
}

resource "aws_lb_listener" "http_prod" {
  port              = local.prod_listener_port
  protocol          = "HTTPS"
  load_balancer_arn = aws_lb.alb.arn
  certificate_arn   = var.acm_certificate_arn
  ssl_policy        = var.ssl_policy

  # Origin mTLS (optional). When enabled, the :443 listener verifies the client certificate the caller
  # (e.g. CloudFront via origin mTLS) presents, against the trust store — a handshake without a cert
  # chaining to the trusted CA is rejected before any HTTP. MANDATORY when this ALB is a CloudFront
  # origin (prefix list / shared-secret header alone are NOT sufficient access control).
  dynamic "mutual_authentication" {
    for_each = var.enable_mutual_auth ? [1] : []
    content {
      mode                             = var.mutual_auth_mode
      trust_store_arn                  = local.mutual_auth_trust_store
      ignore_client_certificate_expiry = var.mutual_auth_mode == "verify" ? var.mutual_auth_ignore_client_certificate_expiry : null
    }
  }

  # Forward to a target group when one is supplied; otherwise return the default fixed "ok" response
  # (the ECS/CodeDeploy pattern, where target groups + listener rules are managed out-of-band).
  default_action {
    type             = local.prod_forward ? "forward" : "fixed-response"
    target_group_arn = local.prod_forward ? var.forward_target_group_arn : null

    dynamic "fixed_response" {
      for_each = local.prod_forward ? [] : [1]
      content {
        content_type = "text/plain"
        status_code  = "200"
        message_body = "ok"
      }
    }
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.app_name}-alb-http-prod"
    }
  )
}

resource "aws_lb_listener" "http_test" {
  count             = var.enable_test_listener ? 1 : 0
  port              = local.test_listener_port
  protocol          = "HTTPS"
  load_balancer_arn = aws_lb.alb.arn
  certificate_arn   = var.acm_certificate_arn
  ssl_policy        = var.ssl_policy

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      status_code  = "200"
      message_body = "ok"
    }
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.app_name}-alb-http-test"
    }
  )
}

resource "aws_lb_listener" "http_redirect" {
  port              = "80"
  protocol          = "HTTP"
  load_balancer_arn = aws_lb.alb.arn

  default_action {
    type = "redirect"

    redirect {
      # tostring(): the redirect block takes a string, the listener takes a number, and both must
      # track the same local or the redirect points at a port nothing serves.
      port        = tostring(local.prod_listener_port)
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.app_name}-alb-http-redirect"
    }
  )
}

resource "aws_route53_record" "app_domain_dns_record" {
  count   = var.create_route53_record ? 1 : 0
  name    = var.alb_domain
  type    = "A"
  zone_id = var.route_53_zone_id

  alias {
    evaluate_target_health = true
    name                   = aws_lb.alb.dns_name
    zone_id                = aws_lb.alb.zone_id
  }

  lifecycle {
    precondition {
      condition     = var.route_53_zone_id != null && var.alb_domain != null
      error_message = "When create_route53_record is true, both route_53_zone_id and alb_domain must be provided."
    }
  }
}

# WAFv2 Web ACL association (REGIONAL scope)
resource "aws_wafv2_web_acl_association" "alb" {
  count        = var.web_acl_arn != "" ? 1 : 0
  resource_arn = aws_lb.alb.arn
  web_acl_arn  = var.web_acl_arn
}
