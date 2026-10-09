[
  {
    "name": "${container_name}",
    "image": "${repository_url}:${bootstrap_image_tag}",
    "essential": true,
    "memory": ${memory_size},
    "user": "1000:1000",
    "readonlyRootFilesystem": true,
    "stopTimeout": 30,
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-region": "${aws_region}",
        "awslogs-stream-prefix": "${container_name}",
        "awslogs-group": "/ecs_server/${app_name}/${container_name}"
      }
    },
    "environment": [],
    "secrets": [],
    "mountPoints": [
      {
        "sourceVolume": "tmp",
        "containerPath": "/tmp",
        "readOnly": false
      }
    ],
    "portMappings": [
      {
        "containerPort": ${container_port},
        "hostPort": ${container_port}
      }
    ],
    "healthCheck": {
      "command": [
        "CMD-SHELL",
        "wget -q -T 4 -O /dev/null http://127.0.0.1:${container_port}${health_check_path} || exit 1"
      ],
      "interval": 10,
      "retries": 10,
      "startPeriod": 10,
      "timeout": 5
    }
  }
]
