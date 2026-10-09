# NOTE: data "aws_vpc" "selected" and local.vpc_cidrs were removed 2026-09-22. Their only consumer
# was the :10443 test-listener ingress falling back to "every CIDR in the VPC" when the caller named
# no source. That fallback was the defect (a module default that grants access); with it gone the
# lookup is dead code, and keeping it would mean an ec2:DescribeVpcs call on every plan for nothing.

# Get AWS managed CloudFront global origin-facing prefix list
data "aws_ec2_managed_prefix_list" "cloudfront" {
  count = var.allow_cloudfront_prefix_list ? 1 : 0
  name  = "com.amazonaws.global.cloudfront.origin-facing"
}

locals {
  # The production listener port, in ONE place. Previously 443 was a literal in the listener, in
  # three separate security-group ingress rules and in the HTTP->HTTPS redirect; parameterising the
  # listener later would have silently desynced them and produced an ALB nothing could reach.
  prod_listener_port = 443
  test_listener_port = 10443

  # Origin mTLS (verify mode): create a trust store from the given S3 CA bundle only when mTLS is on,
  # mode is verify, AND the caller didn't pass an existing trust store. Resolve the effective ARN.
  # When a forward target group is supplied, the :443 listener forwards to it instead of returning a
  # fixed "ok" (the default ECS/CodeDeploy shape). Lets the module serve a simple ALB→target use case.
  prod_forward = var.forward_target_group_arn != ""

  create_trust_store = var.enable_mutual_auth && var.mutual_auth_mode == "verify" && var.mutual_auth_trust_store_arn == ""
  mutual_auth_trust_store = (var.enable_mutual_auth && var.mutual_auth_mode == "verify") ? (
    var.mutual_auth_trust_store_arn != "" ? var.mutual_auth_trust_store_arn : aws_lb_trust_store.this[0].arn
  ) : null
}
