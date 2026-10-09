locals {
  # Attached to the channel role AND used as its guardrail. See var.read_policy_arn.
  readonly_policy_arn = var.read_policy_arn
}

resource "awscc_chatbot_slack_channel_configuration" "this" {
  count = var.create_slack_channel_config ? 1 : 0

  configuration_name = "${var.app_name}-${var.slack_channel_name}-slack"
  iam_role_arn       = aws_iam_role.chatbot.arn
  slack_channel_id   = var.slack_channel_id
  slack_workspace_id = var.slack_workspace_id
  guardrail_policies = [
    aws_iam_policy.chatbot.arn,
    local.readonly_policy_arn
  ]
  sns_topic_arns = [aws_sns_topic.chatbot.arn]

  # null leaves the attribute unset, so AWS keeps its own default (false / NONE).
  user_role_required = var.user_authorization_required
  logging_level      = var.logging_level

  tags = [
    for k, v in merge(var.tags, { Name = "${var.app_name}-${var.slack_channel_name}-chatbot-slack" }) :
    {
      key   = k
      value = v
    }
  ]
}

resource "aws_iam_role" "chatbot" {
  name = "${var.app_name}-${var.slack_channel_name}-AWSChatbot-Role"

  assume_role_policy = <<-EOS
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Service": "chatbot.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
      }
    ]
  }
  EOS
}

data "aws_iam_policy_document" "chatbot" {
  statement {
    effect = "Deny"
    actions = [
      "iam:*",
      "s3:GetBucketPolicy",
      "ssm:*",
      "sts:*",
      "kms:*",
      "cognito-idp:GetSigningCertificate",
      "ec2:GetPasswordData",
      "ecr:GetAuthorizationToken",
      "gamelift:RequestUploadCredentials",
      "gamelift:GetInstanceAccess",
      "lightsail:DownloadDefaultKeyPair",
      "lightsail:GetInstanceAccessDetails",
      "lightsail:GetKeyPair",
      "lightsail:GetKeyPairs",
      "redshift:GetClusterCredentials",
      "storagegateway:DescribeChapCredentials"
    ]
    resources = ["*"]
  }

  # Invoke-any-Lambda from Slack. Off unless asked for; see var.allow_lambda_invoke.
  dynamic "statement" {
    for_each = var.allow_lambda_invoke ? [1] : []
    content {
      effect = "Allow"
      actions = [
        "lambda:invokeAsync",
        "lambda:invokeFunction"
      ]
      resources = ["*"]
    }
  }
}

resource "aws_iam_policy" "chatbot" {
  name   = "${var.app_name}-${var.slack_channel_name}-chatbot-policy"
  policy = data.aws_iam_policy_document.chatbot.json
  tags = merge(
    var.tags,
    {
      Name = "${var.app_name}-${var.slack_channel_name}-chatbot-policy"
    }
  )
}

resource "aws_iam_role_policy_attachment" "chatbot" {
  policy_arn = aws_iam_policy.chatbot.arn
  role       = aws_iam_role.chatbot.name
}

resource "aws_iam_role_policy_attachment" "chatbot_readonly" {
  policy_arn = local.readonly_policy_arn
  role       = aws_iam_role.chatbot.name
}

resource "aws_sns_topic" "chatbot" {
  name = "${var.app_name}-${var.slack_channel_name}-chatbot-sns-topic"
  tags = merge(
    var.tags,
    {
      Name = "${var.app_name}-${var.slack_channel_name}-chatbot-sns-topic"
    }
  )
}

# =============================================================================
# Explicit topic policy. Only created when the caller needs a non-alarm publisher (EventBridge);
# otherwise the topic keeps AWS's default policy, which already permits CloudWatch alarms.
#
# The danger here is what is MISSING rather than what is present: attaching any policy discards the
# default, so this document must restate everything the default provided. See
# var.allow_eventbridge_publish.
# =============================================================================
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "topic" {
  count = var.allow_eventbridge_publish ? 1 : 0

  # Equivalent of the default statement AWS attaches to a new topic: the owning account may manage
  # and publish to it. Dropping this would break console and Terraform management of the topic.
  statement {
    sid    = "OwnerFullControl"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions = [
      "SNS:GetTopicAttributes", "SNS:SetTopicAttributes", "SNS:AddPermission",
      "SNS:RemovePermission", "SNS:DeleteTopic", "SNS:Subscribe",
      "SNS:ListSubscriptionsByTopic", "SNS:Publish",
    ]
    resources = [aws_sns_topic.chatbot.arn]
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceOwner"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  # Granted explicitly rather than relying on the default: every alarm on this topic depends on it.
  statement {
    sid    = "AllowCloudWatchAlarms"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.chatbot.arn]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid    = "AllowEventBridgeRules"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.chatbot.arn]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "chatbot" {
  count = var.allow_eventbridge_publish ? 1 : 0

  arn    = aws_sns_topic.chatbot.arn
  policy = data.aws_iam_policy_document.topic[0].json
}
