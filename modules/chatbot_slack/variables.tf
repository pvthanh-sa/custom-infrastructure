variable "app_name" {
  type = string
}

variable "slack_workspace_id" {
  type = string
}

variable "slack_channel_id" {
  type = string
}

variable "slack_channel_name" {
  type = string
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to resources"
  default     = {}
}

# AWS Chatbot allows exactly ONE Slack channel configuration per (Slack channel, AWS account):
# a second one fails with "Slack channel with ID <id> ... has already been configured for AWS
# account <id>". Set this false to get the SNS topic + IAM role without claiming the channel —
# needed whenever two stacks (e.g. two regions during a migration) must publish to one channel,
# or while ownership of a channel is being handed from one stack to another.
variable "create_slack_channel_config" {
  description = "Create the Slack channel configuration. False yields only the SNS topic + IAM role (the channel stays owned by whichever stack has it)."
  type        = bool
  default     = true
}

variable "allow_eventbridge_publish" {
  description = <<-EOT
    Attach an explicit topic policy that lets EventBridge (events.amazonaws.com) publish to this
    topic, for rules that notify Slack directly rather than through a CloudWatch alarm.

    Read this before enabling it. An aws_sns_topic_policy REPLACES the default policy AWS attaches to
    a new topic, and that default is what currently lets CloudWatch alarms publish. The policy
    written here therefore restates account-owner access and grants cloudwatch.amazonaws.com
    explicitly as well -- leaving either out silently kills every alarm notification on this topic,
    which is the exact failure mode an alerting change must never introduce.

    Both service grants are scoped with aws:SourceAccount so another account's EventBridge or
    CloudWatch cannot publish here.
  EOT
  type        = bool
  default     = false
}

variable "read_policy_arn" {
  description = <<-EOT
    IAM policy ARN attached to the channel role and also applied as its guardrail. This is everything
    the channel (and anyone running @aws commands in it) can read.

    The default, AWS-managed ReadOnlyAccess, keeps the module's historical behaviour. It is
    account-wide read, including s3:GetObject on every bucket (Terraform state among them). A channel
    that only receives notifications needs far less: AWS's own notifications template is
    cloudwatch:Describe*/Get*/List*. Pass a narrow customer-managed policy when nobody runs commands
    in the channel.
  EOT
  type        = string
  default     = "arn:aws:iam::aws:policy/ReadOnlyAccess"

  validation {
    condition     = can(regex("^arn:aws[a-zA-Z-]*:iam::(aws|[0-9]{12}):policy/.+$", var.read_policy_arn))
    error_message = "read_policy_arn must be an IAM policy ARN (arn:aws:iam::<account|aws>:policy/<name>)."
  }
}

variable "allow_lambda_invoke" {
  description = "Allow lambda:InvokeFunction / InvokeAsync on \"*\" from the channel. Off by default: invoke-any-Lambda is rarely wanted, and in a shared account it reaches other projects' functions. BREAKING for consumers that ran @aws lambda invoke: set true to keep it."
  type        = bool
  default     = false
}

variable "user_authorization_required" {
  description = "Require each Slack user to choose their own IAM user role before running commands (Chatbot UserRoleRequired). null leaves the AWS default (false)."
  type        = bool
  default     = null
}

variable "logging_level" {
  description = "Chatbot logging level to CloudWatch Logs: ERROR, INFO or NONE. null leaves the AWS default (NONE)."
  type        = string
  default     = null

  validation {
    condition     = var.logging_level == null || contains(["ERROR", "INFO", "NONE"], coalesce(var.logging_level, "NONE"))
    error_message = "logging_level must be ERROR, INFO or NONE (or null for the AWS default)."
  }
}
