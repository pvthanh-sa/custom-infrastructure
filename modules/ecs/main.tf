resource "aws_iam_policy" "ecs_task_execution_policy" {
  name   = "${var.app_name}-ecs-task-execution-policy"
  path   = "/"
  policy = data.aws_iam_policy_document.ecs_task_execution_policy_document.json

  tags = merge(
    var.tags,
    {
      Name = "${var.app_name}-ecs-task-policy"
    }
  )
}

module "ecs_task_execution_role" {
  source     = "../iam_role"
  name       = "${var.app_name}-ecs-task-execution-role"
  identifier = "ecs-tasks.amazonaws.com"

  policy_arns_map = {
    "policy_1" = aws_iam_policy.ecs_task_execution_policy.arn
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.app_name}-ecs-task-execution-role"
    }
  )
}

resource "aws_iam_policy" "ecs_task_policy" {
  name   = "${var.app_name}-ecs-task-policy"
  path   = "/"
  policy = data.aws_iam_policy_document.ecs_task.json

  tags = merge(
    var.tags,
    {
      Name = "${var.app_name}-ecs-task-policy"
    }
  )
}

module "ecs_task_role" {
  source     = "../iam_role"
  name       = "${var.app_name}-ecs-task-role"
  identifier = "ecs-tasks.amazonaws.com"
  policy_arns_map = {
    "policy_1" = aws_iam_policy.ecs_task_policy.arn
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.app_name}-ecs-task-role"
    }
  )
}

# =============================================================================
# SECRETS — optional single container (no value managed by Terraform)
# =============================================================================
# When create_app_secret = true, Terraform creates ONLY the empty secret
# container "<app_name>-secrets". The JSON value is uploaded out-of-band (console
# or a gitignored secrets/<app>.json). Terraform never generates or reads a secret
# value, so NOTHING sensitive is stored in Terraform state.
#
# One container holds ALL app secret keys. Reference each key from the task
# definition's `secrets` entries as valueFrom = "<app_secrets_arn>:<key>::"
# (typically wired in CI/CD's taskdef.json). The execution role is granted read
# access automatically (see local.execution_secret_arns in data.tf/locals.tf).
#
# Populate the container BEFORE the first deploy — a missing key makes the ECS
# task fail at start. Rotate by editing the value in the console, then redeploy.
resource "aws_secretsmanager_secret" "app_secrets" {
  count = var.create_app_secret ? 1 : 0
  name  = "${var.app_name}-secrets"

  tags = merge(var.tags, {
    Name = "${var.app_name}-secrets"
  })
}

resource "aws_ecs_task_definition" "task_definition" {
  family = "${var.app_name}-server"

  cpu                      = var.task_cpu_size
  memory                   = var.task_memory_size
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = templatefile("${path.module}/container_definitions/server-task-def.json.tpl", {
    container_name      = var.container_names[0]
    container_port      = var.container_port
    repository_url      = var.repository_url
    bootstrap_image_tag = var.bootstrap_image_tag
    memory_size         = var.task_memory_size
    app_name            = var.app_name
    aws_region          = var.region
    health_check_path   = var.app_health_check_path

    # Environment variables
    }
  )
  execution_role_arn = module.ecs_task_execution_role.iam_role_arn
  task_role_arn      = module.ecs_task_role.iam_role_arn

  # Writable scratch space for a read-only root filesystem (the container mounts it at /tmp).
  # Fargate backs a volume with no host path by task ephemeral storage.
  volume {
    name = "tmp"
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.app_name}-server-task-definition"
    }
  )
}

resource "aws_cloudwatch_log_group" "log" {
  count             = length(var.container_names)
  name              = "/ecs_server/${var.app_name}/${var.container_names[count.index]}"
  retention_in_days = var.cloudwatch_log_retention_in_days
  tags = merge(
    var.tags,
    {
      Name = "/ecs_server/${var.app_name}/${var.container_names[count.index]}"
    }
  )
}

resource "random_uuid" "target_group_uuid" {}

resource "aws_lb_target_group" "target_group_blue" {
  name   = "${substr(var.app_name, 0, 18)}-server-blue-${substr(random_uuid.target_group_uuid.result, 0, 2)}"
  vpc_id = data.aws_vpc.selected.id

  port        = var.container_port
  protocol    = var.load_balancer_type == "nlb" ? "TCP" : "HTTP"
  target_type = "ip"

  deregistration_delay = var.deregistration_delay

  health_check {
    port                = var.container_port
    timeout             = var.load_balancer_type == "nlb" ? 6 : 10
    protocol            = "HTTP"
    path                = var.app_health_check_path
    matcher             = "200-299"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }

  lifecycle {
    create_before_destroy = true
  }
  tags = merge(
    var.tags,
    {
      Name = "${substr(var.app_name, 0, 18)}-server-blue-${substr(random_uuid.target_group_uuid.result, 0, 2)}"
    }
  )
}

resource "aws_lb_target_group" "target_group_green" {
  name   = "${substr(var.app_name, 0, 18)}-server-green-${substr(random_uuid.target_group_uuid.result, 0, 2)}"
  vpc_id = data.aws_vpc.selected.id

  port        = var.container_port
  protocol    = var.load_balancer_type == "nlb" ? "TCP" : "HTTP"
  target_type = "ip"

  deregistration_delay = var.deregistration_delay

  health_check {
    port                = var.container_port
    timeout             = var.load_balancer_type == "nlb" ? 6 : 10
    protocol            = "HTTP"
    path                = var.app_health_check_path
    matcher             = "200-299"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(
    var.tags,
    {
      Name = "${substr(var.app_name, 0, 18)}-server-green-${substr(random_uuid.target_group_uuid.result, 0, 2)}"
    }
  )
}

# ALB listener rules (path-based routing)
resource "aws_lb_listener_rule" "http_rule" {
  count        = var.load_balancer_type == "alb" ? 1 : 0
  listener_arn = var.http_prod_listener_arn

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.target_group_blue.id
  }
  condition {
    path_pattern {
      values = ["*"]
    }
  }
  lifecycle {
    ignore_changes = [
      action,
    ]
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.app_name}-server-http-rule"
    }
  )
}

resource "aws_lb_listener_rule" "http_test_rule" {
  count        = var.load_balancer_type == "alb" ? 1 : 0
  listener_arn = var.http_test_listener_arn

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.target_group_green.id
  }
  condition {
    path_pattern {
      values = ["*"]
    }
  }
  lifecycle {
    ignore_changes = [
      action,
    ]
  }
  tags = merge(
    var.tags,
    {
      Name = "${var.app_name}-server-http-test-rule"
    }
  )
}

# For NLB, we create the listeners directly since NLB module doesn't create them
# TCP listener for HTTP (port 80)
resource "aws_lb_listener" "nlb_http" {
  count             = var.load_balancer_type == "nlb" ? 1 : 0
  port              = "80"
  protocol          = "TCP"
  load_balancer_arn = var.nlb_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.target_group_blue.arn
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.app_name}-nlb-tcp-http"
    }
  )

  lifecycle {
    ignore_changes = [
      default_action,
    ]
  }
}

resource "aws_lb_listener" "nlb_prod" {
  count             = var.load_balancer_type == "nlb" ? 1 : 0
  port              = "443" # Standard HTTPS port
  protocol          = "TLS"
  load_balancer_arn = var.nlb_arn
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.target_group_blue.arn
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.app_name}-nlb-tls-prod"
    }
  )

  lifecycle {
    ignore_changes = [
      default_action,
    ]
  }
}

# NLB test listener on different port
resource "aws_lb_listener" "nlb_test" {
  count             = var.load_balancer_type == "nlb" ? 1 : 0
  port              = "10443" # Standard test port
  protocol          = "TLS"
  load_balancer_arn = var.nlb_arn
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.target_group_green.arn
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.app_name}-nlb-tcp-test"
    }
  )

  lifecycle {
    ignore_changes = [
      default_action,
    ]
  }
}

# ECS Security Group is created externally to avoid cycle dependencies with RDS/ElastiCache
# Pass the security group ID via var.ecs_security_group_id

# Add security group rule to allow ALB to access ECS
resource "aws_security_group_rule" "ecs_allow_alb" {
  type                     = "ingress"
  from_port                = var.container_port
  to_port                  = var.container_port
  protocol                 = "tcp"
  security_group_id        = var.ecs_security_group_id
  source_security_group_id = var.alb_security_group_id
  description              = "Allow inbound traffic from ALB to ECS tasks"
}

resource "aws_ecs_service" "ecs_service" {
  name                   = "${var.app_name}-server-service"
  launch_type            = "FARGATE"
  desired_count          = var.desired_task_count
  cluster                = var.cluster_name
  task_definition        = aws_ecs_task_definition.task_definition.arn
  enable_execute_command = var.enable_execute_command

  network_configuration {
    security_groups  = [var.ecs_security_group_id]
    subnets          = var.subnet_ids
    assign_public_ip = var.assign_public_ip
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.target_group_blue.arn
    container_name   = var.container_names[0]
    container_port   = var.container_port
  }

  deployment_controller {
    type = "CODE_DEPLOY"
  }

  # For NLB, ensure listeners are created before the service
  depends_on = [
    aws_lb_listener.nlb_prod,
    aws_lb_listener.nlb_test
  ]

  lifecycle {
    ignore_changes = [
      load_balancer,
      task_definition,
      # Application Auto Scaling owns desired_count once an appautoscaling_target is registered
      # against this service (cloudwatch_alarm_ecs does exactly that). Without this, every apply
      # resets the service to var.desired_task_count — including mid scale-out, removing capacity
      # during the load event that caused it — and `plan is clean` stops being a truthful
      # convergence signal. Added 2026-09-18 (G4).
      desired_count
    ]
  }
  tags = merge(
    var.tags,
    {
      Name = "${var.app_name}-server-service"
    }
  )
}
