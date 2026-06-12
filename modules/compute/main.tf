data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ── ECR ──────────────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "main" {
  name                 = var.name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration { scan_on_push = true }
}

# Seed a placeholder image on first creation so Lambda can be created before CI pushes a real image.
resource "terraform_data" "ecr_seed" {
  triggers_replace = aws_ecr_repository.main.repository_url

  provisioner "local-exec" {
    command = <<-EOT
      aws ecr get-login-password --region ${data.aws_region.current.name} | \
        docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com && \
      docker pull public.ecr.aws/lambda/python:3.12 && \
      docker tag public.ecr.aws/lambda/python:3.12 ${aws_ecr_repository.main.repository_url}:latest && \
      docker push ${aws_ecr_repository.main.repository_url}:latest
    EOT
  }
}

resource "aws_ecr_lifecycle_policy" "main" {
  repository = aws_ecr_repository.main.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# ── IAM: Lambda ──────────────────────────────────────────────────────────────

resource "aws_iam_role" "lambda" {
  name = "${var.name}-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_data_api" {
  name = "${var.name}-lambda-data-api"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "rds-data:ExecuteStatement",
          "rds-data:BatchExecuteStatement",
          "rds-data:BeginTransaction",
          "rds-data:CommitTransaction",
          "rds-data:RollbackTransaction",
        ]
        Resource = var.cluster_arn
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = var.db_credentials_secret_arn
      },
    ]
  })
}

locals {
  lambda_env = {
    ENV               = "prod"
    USE_DATA_API      = "true"
    DB_CLUSTER_ARN    = var.cluster_arn
    DB_SECRET_ARN     = var.db_credentials_secret_arn
    DB_NAME           = var.db_name
    JWT_SECRET        = var.jwt_secret
    ANTHROPIC_API_KEY = var.anthropic_api_key
    # LWA: uvicorn listens on this port inside the container
    PORT                    = "8000"
    AWS_LAMBDA_EXEC_WRAPPER = "/opt/extensions/lambda-adapter"
  }
}

# ── Lambda A: API (standard invoke, behind API Gateway) ──────────────────────

resource "aws_lambda_function" "api" {
  function_name = "${var.name}-api"
  role          = aws_iam_role.lambda.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.main.repository_url}:latest"
  timeout       = 29
  memory_size   = 512

  environment { variables = local.lambda_env }

  lifecycle {
    # CI/CD updates function code directly via aws lambda update-function-code
    ignore_changes = [image_uri]
  }

  depends_on = [terraform_data.ecr_seed]
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/lambda/${aws_lambda_function.api.function_name}"
  retention_in_days = 14
}

# ── Lambda B: Chat (response-stream invoke, behind Function URL) ──────────────

resource "aws_lambda_function" "chat" {
  function_name = "${var.name}-chat"
  role          = aws_iam_role.lambda.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.main.repository_url}:latest"
  timeout       = 900
  memory_size   = 512

  # response_stream lets LWA stream the SSE chat response through the Function URL.
  environment { variables = merge(local.lambda_env, { AWS_LWA_INVOKE_MODE = "response_stream" }) }

  lifecycle {
    ignore_changes = [image_uri]
  }

  depends_on = [terraform_data.ecr_seed]
}

resource "aws_cloudwatch_log_group" "chat" {
  name              = "/aws/lambda/${aws_lambda_function.chat.function_name}"
  retention_in_days = 14
}

resource "aws_lambda_function_url" "chat" {
  function_name = aws_lambda_function.chat.function_name
  # OAC+IAM can't sign POST bodies to a Function URL, so we use a public URL and
  # let the app's JWT (get_current_player) be the gatekeeper. See chat behavior
  # in the cdn module for the CloudFront wiring.
  authorization_type = "NONE"
  invoke_mode        = "RESPONSE_STREAM"
}

# AuthType=NONE still needs a resource policy granting public InvokeFunctionUrl.
# Anyone can reach the URL, but every request must carry a valid JWT or the app
# returns 401.
resource "aws_lambda_permission" "chat_public_url" {
  statement_id           = "FunctionURLAllowPublicAccess"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.chat.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

# ── API Gateway REST ──────────────────────────────────────────────────────────

resource "aws_api_gateway_rest_api" "main" {
  name = "${var.name}-api"
}

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "proxy" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "proxy" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.proxy.id
  http_method             = aws_api_gateway_method.proxy.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.api.invoke_arn
}

resource "aws_api_gateway_method" "root" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_rest_api.main.root_resource_id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "root" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_rest_api.main.root_resource_id
  http_method             = aws_api_gateway_method.root.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.api.invoke_arn
}

resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.proxy,
      aws_api_gateway_method.proxy,
      aws_api_gateway_integration.proxy,
      aws_api_gateway_method.root,
      aws_api_gateway_integration.root,
    ]))
  }

  lifecycle { create_before_destroy = true }

  depends_on = [
    aws_api_gateway_integration.proxy,
    aws_api_gateway_integration.root,
  ]
}

resource "aws_api_gateway_stage" "main" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  deployment_id = aws_api_gateway_deployment.main.id
  stage_name    = "prod"
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.main.execution_arn}/*/*"
}

# ── ECS / Fargate (migration runner) ─────────────────────────────────────────

resource "aws_ecs_cluster" "main" {
  name = "${var.name}-cluster"
}

resource "aws_security_group" "fargate" {
  name   = "${var.name}-fargate-sg"
  vpc_id = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Open port 5432 on the DB security group from the Fargate task.
# Defined here (not in the database module) to avoid a circular module dependency.
resource "aws_security_group_rule" "fargate_to_db" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.fargate.id
  security_group_id        = var.db_security_group_id
}

resource "aws_iam_role" "ecs_execution" {
  name = "${var.name}-ecs-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_basic" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ecs_execution_secrets" {
  name = "${var.name}-ecs-execution-secrets"
  role = aws_iam_role.ecs_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = var.db_url_secret_arn
    }]
  })
}

resource "aws_iam_role" "ecs_task" {
  name = "${var.name}-ecs-task-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_cloudwatch_log_group" "migrate" {
  name              = "/ecs/${var.name}-migrate"
  retention_in_days = 7
}

resource "aws_ecs_task_definition" "migrate" {
  family                   = "${var.name}-migrate"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name    = "migrate"
    image   = "${aws_ecr_repository.main.repository_url}:latest"
    command = ["sh", "-c", "alembic upgrade head"]

    environment = [
      { name = "USE_DATA_API", value = "false" }
    ]

    secrets = [{
      name      = "DATABASE_URL"
      valueFrom = var.db_url_secret_arn
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.migrate.name
        "awslogs-region"        = data.aws_region.current.name
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

# ── GitHub Actions OIDC ───────────────────────────────────────────────────────

data "aws_iam_openid_connect_provider" "github" {
  arn = "arn:aws:iam::794216920868:oidc-provider/token.actions.githubusercontent.com"
}

resource "aws_iam_role" "github_actions" {
  name = "${var.name}-github-actions"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:*"
        }
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions" {
  name = "${var.name}-github-actions"
  role = aws_iam_role.github_actions.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Push images to ECR
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
        ]
        Resource = "*"
      },
      {
        # Update Lambda function code
        Effect   = "Allow"
        Action   = ["lambda:UpdateFunctionCode"]
        Resource = [aws_lambda_function.api.arn, aws_lambda_function.chat.arn]
      },
      {
        # Run the migration Fargate task
        Effect = "Allow"
        Action = ["ecs:RunTask", "iam:PassRole"]
        Resource = [
          aws_ecs_task_definition.migrate.arn,
          aws_iam_role.ecs_execution.arn,
          aws_iam_role.ecs_task.arn,
        ]
      },
      {
        # Wait for the migration task to complete
        Effect   = "Allow"
        Action   = ["ecs:DescribeTasks"]
        Resource = "*"
        Condition = {
          ArnEquals = { "ecs:cluster" = aws_ecs_cluster.main.arn }
        }
      },
    ]
  })
}
