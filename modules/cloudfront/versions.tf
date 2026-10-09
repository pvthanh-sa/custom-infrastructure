terraform {
  # 1.4.0, not 1.0. Two separate reasons, and the first one is a PRE-EXISTING BUG being fixed here,
  # not something the 2026-09-24 fork introduced:
  #
  #   · variables.tf uses the two-argument `optional(string, "")` form inside object() (lines
  #     140-143). That form needs Terraform >= 1.3 — 1.2 has `optional()` but it takes no default.
  #     Those four lines are upstream at 8517e03 and older, so this module has silently required
  #     1.3 while declaring 1.0: a caller on 1.0-1.2 got a parse error, not a version error.
  #   · the aws_cloudfront_cache_policy lifecycle.precondition added with the forwarded_headers
  #     split needs >= 1.2. It is NOT the binding constraint — optional() already outranks it.
  #
  # The binding minimum is therefore 1.3, and the floor is set at 1.4.0 rather than 1.3 because
  # that is this library's house floor: of ~45 modules carrying a versions.tf, cloudfront at 1.0
  # was the only one below 1.3, and 1.4.0 is the most common value. Nothing here needs 1.4 over
  # 1.3; matching the rest of the library is worth more than the 0.1.
  required_version = ">= 1.4.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Floor raised 4.0 -> 6.51.0: the optional origin_mtls_config block (origin mTLS,
      # var.origin_client_certificate_arn) is only in the provider schema from v6.51.0
      # (PR #46421), and a dynamic block must exist in the schema even when unused.
      version = ">= 6.51.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
  }
}
