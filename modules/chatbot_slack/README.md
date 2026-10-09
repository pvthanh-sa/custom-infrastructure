# AWS Chatbot Slack Integration Terraform Module

Terraform module which creates AWS Chatbot Slack integration for sending notifications.

> ## UPGRADE NOTE — 2026-10-09
>
> - **BREAKING: Lambda invoke is now off by default.** The module's own policy used to allow
>   `lambda:InvokeFunction`/`InvokeAsync` on `"*"`. If anyone runs `@aws lambda invoke` in the
>   channel, set `allow_lambda_invoke = true` to keep it. Otherwise the next plan updates
>   `<app>-<channel>-chatbot-policy` in place and the Allow disappears.
> - **New: `read_policy_arn`.** Its default is still `ReadOnlyAccess`, so there is no change unless
>   you set it. Read [Permissions](#permissions) before keeping the default.
> - **New: `user_authorization_required`, `logging_level`.** Both default to `null`, which leaves
>   the AWS defaults (`false` / `NONE`). No change unless you set them.

## Features

This module supports creating:

- **SNS Topic** - Topic for receiving notifications
- **AWS Chatbot** - Slack channel configuration
- **IAM Role** - Chatbot service role with required permissions
- **Notification Integration** - CloudWatch Alarms, CodePipeline, etc.

## Usage

### Example 1: Notice Channel (General Notifications)

```terraform
module "chatbot_slack_notice" {
  source = "../../modules/chatbot_slack"

  app_name           = "${var.environment}-${var.app_name}"
  slack_workspace_id = var.slack_workspace_id
  slack_channel_id   = var.slack_notice_channel_id
  slack_channel_name = "system-notice"

  providers = {
    aws   = aws
    awscc = awscc
  }

  tags = {
    Environment = "staging"
    Terraform   = "true"
  }
}
```

### Example 2: Alert Channel (Critical Alerts)

```terraform
module "chatbot_slack_alert" {
  source = "../../modules/chatbot_slack"

  app_name           = "${var.environment}-${var.app_name}"
  slack_workspace_id = var.slack_workspace_id
  slack_channel_id   = var.slack_alert_channel_id
  slack_channel_name = "system-alerts"

  providers = {
    aws   = aws
    awscc = awscc
  }

  tags = {
    Environment = "staging"
    Terraform   = "true"
  }
}
```

### Example 3: Using with CloudWatch Alarms

```terraform
module "chatbot_slack_notice" {
  source = "../../modules/chatbot_slack"

  app_name           = "${var.environment}-${var.app_name}-notice"
  slack_workspace_id = var.slack_workspace_id
  slack_channel_id   = var.slack_notice_channel_id
  slack_channel_name = "system-notice"

  providers = {
    aws   = aws
    awscc = awscc
  }

  tags = local.tags
}

# Use with CloudWatch Alarm
module "cloudwatch_alarm_ecs" {
  source = "../../modules/cloudwatch_alarm_ecs"

  # ... other configuration ...

  chatbot_notice_sns_topic_arn = module.chatbot_slack_notice.chatbot_sns_topic_arn
  chatbot_alert_sns_topic_arn  = module.chatbot_slack_alert.chatbot_sns_topic_arn
}
```

## Slack Configuration Setup

### Step 1: Get Slack Workspace ID

1. Go to AWS Console → AWS Chatbot
2. Click "Configure new client"
3. Select "Slack" and authorize AWS Chatbot
4. Note the **Workspace ID** (format: `T0XXXXXXX`)

### Step 2: Get Slack Channel ID

1. In Slack, right-click on the channel
2. Select "View channel details"
3. At the bottom, find **Channel ID** (format: `C0XXXXXXXX`)

### Step 3: Invite AWS Chatbot to Channel

```
/invite @aws
```

## Provider Configuration

This module requires both AWS and AWSCC providers:

```terraform
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
    awscc = {
      source  = "hashicorp/awscc"
      version = ">= 0.50.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"
}

provider "awscc" {
  region = "ap-northeast-1"
}
```

## Permissions

The channel role gets `read_policy_arn` twice: as an attached policy, and as the channel
**guardrail** that caps any user role as well. Everything in it is readable by whoever can talk to
`@aws` in the channel, and with `user_authorization_required = false` that means every channel
member.

The default, `ReadOnlyAccess`, is account-wide read. That includes `s3:GetObject` on every bucket,
so a Terraform state object and any secret held in it in cleartext are readable from Slack. With
`logging_level = NONE`, those reads leave no Chatbot log.

**Notification-only channel** (nobody runs `@aws` commands). Pass a narrow customer-managed policy,
for example:

```terraform
data "aws_iam_policy_document" "chatbot_read" {
  statement {
    actions   = ["cloudwatch:DescribeAlarms", "cloudwatch:GetMetricData", "cloudwatch:GetMetricWidgetImage"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "chatbot_read" {
  name   = "${local.prefix}-chatbot-notifications-read"
  policy = data.aws_iam_policy_document.chatbot_read.json
}

module "chatbot_slack_alert" {
  source = "../../modules/chatbot_slack"
  # ...
  read_policy_arn             = aws_iam_policy.chatbot_read.arn
  user_authorization_required = true
  logging_level               = "INFO"
}
```

AWS's own notifications template (`AWS-Chatbot-NotificationsOnly-Policy`) is
`cloudwatch:Describe*`, `Get*` and `List*`. The three actions above are the subset that rendering an
alarm notification needs. **Prove it after changing**: put a real alarm into ALARM
(`aws cloudwatch set-alarm-state`) and confirm the message arrives. Chatbot also accepts a Slack
channel ID without validating it against Slack. A wrong ID applies cleanly and then sends nothing,
so a real notification is the only proof the channel works.

## Notification Types

| Source       | Notification Type          |
| ------------ | -------------------------- |
| CloudWatch   | Alarm state changes        |
| CodePipeline | Pipeline execution status  |
| CodeBuild    | Build status notifications |
| Security Hub | Security findings          |
| AWS Health   | Service health events      |

## Inputs

| Name               | Description                            | Type          | Default | Required |
| ------------------ | -------------------------------------- | ------------- | ------- | :------: |
| app_name           | Application name for resource naming   | `string`      | n/a     |   yes    |
| slack_workspace_id | Slack workspace ID (format: T0XXXXXXX) | `string`      | n/a     |   yes    |
| slack_channel_id   | Slack channel ID (format: C0XXXXXXXX)  | `string`      | n/a     |   yes    |
| slack_channel_name | Slack channel name for identification  | `string`      | n/a     |   yes    |
| tags               | Tags to apply to resources             | `map(string)` | `{}`    |    no    |
| read_policy_arn    | Policy attached to the channel role AND used as its guardrail — see [Permissions](#permissions) | `string` | `"arn:aws:iam::aws:policy/ReadOnlyAccess"` | no |
| allow_lambda_invoke | Allow invoke of any Lambda (`"*"`) from the channel | `bool` | `false` | no |
| user_authorization_required | Require a per-user IAM role for commands (Chatbot `UserRoleRequired`) | `bool` | `null` (AWS default false) | no |
| logging_level      | `ERROR`, `INFO` or `NONE` | `string` | `null` (AWS default NONE) | no |
| create_slack_channel_config | Create the Slack channel configuration (false = topic + role only) | `bool` | `true` | no |
| allow_eventbridge_publish | Explicit topic policy that also lets EventBridge publish | `bool` | `false` | no |

## Outputs

| Name                  | Description                      |
| --------------------- | -------------------------------- |
| chatbot_sns_topic_arn | ARN of the SNS topic for Chatbot |

## Best Practices

1. **Separate Channels**: Use different channels for notices vs alerts
2. **Channel Naming**: Use descriptive names like `#aws-staging-alerts`
3. **Alert Fatigue**: Configure appropriate alarm thresholds to avoid noise
4. **Permissions**: Limit who can acknowledge/silence alerts

## Requirements

| Name      | Version   |
| --------- | --------- |
| terraform | >= 1.4.0  |
| aws       | >= 5.0.0  |
| awscc     | >= 0.50.0 |

## License

Apache 2 Licensed. See LICENSE for full details.
