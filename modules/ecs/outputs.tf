output "service_name" {
  value = aws_ecs_service.ecs_service.name
}

output "lb_target_group_blue_name" {
  value = aws_lb_target_group.target_group_blue.name
}

output "lb_target_group_blue_arn_suffix" {
  value = aws_lb_target_group.target_group_blue.arn_suffix
}

output "lb_target_group_green_name" {
  value = aws_lb_target_group.target_group_green.name
}

output "lb_target_group_green_arn_suffix" {
  value = aws_lb_target_group.target_group_green.arn_suffix
}

output "task_definition_arn" {
  description = "The ARN of the task definition including revision number"
  value       = aws_ecs_task_definition.task_definition.arn
}

output "task_definition_family" {
  description = "The family of the task definition"
  value       = aws_ecs_task_definition.task_definition.family
}

output "task_definition_revision" {
  description = "The revision of the task definition"
  value       = aws_ecs_task_definition.task_definition.revision
}

output "ecs_task_role_arn" {
  value = module.ecs_task_role.iam_role_arn
}

# Callers need the NAME (not the ARN) to attach their own policies with
# aws_iam_role_policy_attachment. Without this the only options were hardcoding the role name or
# leaving app permissions unattached — which is what happened to the assets-bucket policy.
output "ecs_task_role_name" {
  description = "Name of the ECS task role, for attaching caller-owned policies."
  value       = module.ecs_task_role.iam_role_name
}

output "ecs_task_execution_role_arn" {
  value = module.ecs_task_execution_role.iam_role_arn
}

output "ecs_cloudwatch_log_group_name" {
  description = "The name of the CloudWatch log group for the ECS service"
  value       = aws_cloudwatch_log_group.log[0].name
}

output "ecs_security_group_id" {
  description = "The ID of the ECS security group"
  value       = var.ecs_security_group_id
}

output "lb_target_group_blue_arn" {
  value = aws_lb_target_group.target_group_blue.arn
}

output "lb_target_group_green_arn" {
  value = aws_lb_target_group.target_group_green.arn
}

output "lb_listener_tcp_prod_arn" {
  value = var.load_balancer_type == "nlb" ? aws_lb_listener.nlb_prod[0].arn : var.http_prod_listener_arn
}

output "lb_listener_tcp_test_arn" {
  value = var.load_balancer_type == "nlb" ? aws_lb_listener.nlb_test[0].arn : var.http_test_listener_arn
}

# =============================================================================
# App secret container ARN (single secret; value managed out-of-band)
# =============================================================================
# Null when create_app_secret = false. Reference keys from the task definition's
# `secrets` entries as valueFrom = "<app_secrets_arn>:<key>::".
output "app_secrets_arn" {
  description = "ARN of the optional app secret container (<app_name>-secrets). Null when create_app_secret is false. Populate its JSON value out-of-band."
  value       = var.create_app_secret ? aws_secretsmanager_secret.app_secrets[0].arn : null
}
