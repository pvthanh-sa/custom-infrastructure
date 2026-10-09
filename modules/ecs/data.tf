data "aws_caller_identity" "user" {}

# Get VPC information including CIDR block
data "aws_vpc" "selected" {
  id = var.vpc_id
}

# ECS Task Execution Role
data "aws_iam_policy_document" "ecs_task_execution_policy_document" {
  # ECR permissions - specific to your repositories
  statement {
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken"
    ]
    resources = ["*"] # This must be * for GetAuthorizationToken
  }

  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:GetRepositoryPolicy",
      "ecr:DescribeRepositories",
      "ecr:ListImages",
      "ecr:DescribeImages",
      "ecr:BatchGetImage"
    ]
    resources = [
      "${var.repository_arn}",
      "${var.repository_arn}/*"
    ]
  }

  # CloudWatch Logs permissions - specific to your log groups
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = [
      "arn:aws:logs:${var.region}:${data.aws_caller_identity.user.account_id}:log-group:/ecs_server/${var.app_name}",
      "arn:aws:logs:${var.region}:${data.aws_caller_identity.user.account_id}:log-group:/ecs_server/${var.app_name}/*"
    ]
  }

  # Secrets Manager permissions for the app secrets referenced by the task definition's `secrets`
  # entries: the optional managed "<app_name>-secrets" container (create_app_secret = true) plus
  # any externally-managed ARNs passed via var.secret_arns. Emitted only when at least one applies —
  # a statement with an empty resources list renders an invalid IAM policy.
  dynamic "statement" {
    for_each = length(local.execution_secret_arns) > 0 ? [1] : []
    content {
      effect = "Allow"
      actions = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ]
      resources = local.execution_secret_arns
    }
  }
}

data "aws_iam_policy_document" "ecs_task" {
  # source_policy_documents = [data.aws_iam_policy.ecs_task_role_policy.policy]

  # ECS Exec session channels.
  #
  # These four actions MUST stay on Resource "*": the SSM Messages API defines no resource-level
  # permissions for them, so any ARN here would deny every session. Do not "tighten" this — the
  # scoping that matters was done by removing the two actions below.
  #
  # REMOVED 2026-09-18 (G4 High finding):
  #   - ssm:GetParameters — nothing in this stack reads SSM Parameter Store. Runtime secrets come
  #     from Secrets Manager, pulled by the EXECUTION role via the task definition's `secrets`
  #     block, not by the TASK role. On Resource "*" it granted every parameter in an account
  #     shared with the WMS project.
  #   - kms:Decrypt — only required when ECS Exec session encryption is configured with a CMK
  #     (cluster `executeCommandConfiguration.kmsKeyId`). Verified 2026-09-18: neither cluster sets
  #     executeCommandConfiguration at all, so sessions use the AWS-managed default and the task
  #     role needs no KMS grant. On Resource "*" it unlocked every SecureString the line above
  #     could read.
  # If Exec session encryption is ever enabled with a CMK, re-add kms:Decrypt scoped to THAT key
  # ARN with a kms:ViaService condition — never back to "*".
  statement {
    sid    = "ECSExecSessionChannels"
    effect = "Allow"
    actions = [
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:CreateControlChannel"
    ]
    resources = ["*"]
  }

  # S3 permissions for backend storage bucket
  # statement {
  #   effect = "Allow"
  #   actions = [
  #     "s3:GetObject",
  #     "s3:PutObject",
  #     "s3:DeleteObject",
  #     "s3:ListBucket",
  #     "s3:GetBucketLocation"
  #   ]
  #   resources = [
  #     "arn:aws:s3:::${var.aws_bucket}",
  #     "arn:aws:s3:::${var.aws_bucket}/*"
  #   ]
  # }

  # SES permissions for sending emails
  # statement {
  #   effect = "Allow"
  #   actions = [
  #     "ses:SendEmail",
  #     "ses:SendRawEmail",
  #     "ses:SendTemplatedEmail",
  #     "ses:SendBulkTemplatedEmail"
  #   ]
  #   resources = ["*"]
  # }
}
