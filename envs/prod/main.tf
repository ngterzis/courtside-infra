data "aws_route53_zone" "main" {
  name = var.hosted_zone_name
}

locals {
  # trimsuffix handles the trailing dot that Route 53 zone names sometimes include
  app_domain = "courtside.${trimsuffix(data.aws_route53_zone.main.name, ".")}"
}

module "vpc" {
  source = "../../modules/vpc"

  name                 = "courtside-prod"
  cidr                 = "10.0.0.0/16"
  azs                  = ["eu-central-1a", "eu-central-1b"]
  public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnet_cidrs = ["10.0.11.0/24", "10.0.12.0/24"]
}

module "database" {
  source = "../../modules/database"

  name                = "courtside-prod"
  vpc_id              = module.vpc.vpc_id
  subnet_ids          = module.vpc.private_subnet_ids
  db_name             = "courtside"
  db_username         = "courtside"
  max_capacity        = 4
  skip_final_snapshot = false
}

locals {
  # Names agreed between the ml module (which provisions the feature group, model
  # registry, MLflow) and the pipeline in the backend repo (which ingests, trains,
  # and deploys the endpoint). See ml/config.py defaults in courtside-backend.
  ml_feature_group_name       = "courtside-player-form"
  ml_model_package_group_name = "courtside-next-game-points"
  ml_endpoint_name            = "courtside-next-game-points"

  # MUST match courtside.ml.features.FEATURE_NAMES in the backend repo.
  ml_feature_names = [
    "games_played",
    "pts_avg_3", "reb_avg_3", "ast_avg_3", "tov_avg_3", "fga_avg_3",
    "ts_pct_3", "fg_pct_3", "three_pct_3",
    "pts_avg_5", "reb_avg_5", "ast_avg_5", "ts_pct_5",
    "pts_avg_season", "reb_avg_season", "ast_avg_season", "ts_pct_season",
    "last_game_points", "days_rest", "is_home", "opp_margin_avg",
  ]
}

module "ml" {
  source = "../../modules/ml"

  name                     = "courtside-prod"
  feature_group_name       = local.ml_feature_group_name
  feature_names            = local.ml_feature_names
  model_package_group_name = local.ml_model_package_group_name
  endpoint_name            = local.ml_endpoint_name
}

module "compute" {
  source = "../../modules/compute"

  name               = "courtside-prod"
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  # DB — passed in so compute can add the Fargate→DB security group rule
  db_security_group_id      = module.database.db_security_group_id
  cluster_arn               = module.database.cluster_arn
  db_credentials_secret_arn = module.database.db_credentials_secret_arn
  db_url_secret_arn         = module.database.db_url_secret_arn
  db_name                   = "courtside"

  jwt_secret        = var.jwt_secret
  anthropic_api_key = var.anthropic_api_key
  github_repo       = var.github_repo

  # Model serving. Endpoint name is intentionally left "" until the deploy pipeline
  # has shipped the Serverless endpoint — flip to local.ml_endpoint_name then.
  feature_group_name      = local.ml_feature_group_name
  sagemaker_endpoint_name = ""
}

# ── Cross-module IAM (wired here, like the frontend GitHub role below) ─────────

# The app Lambda invokes the endpoint and reads online features at request time.
resource "aws_iam_role_policy" "lambda_sagemaker" {
  name = "courtside-prod-lambda-sagemaker"
  role = module.compute.lambda_role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sagemaker:InvokeEndpoint"]
        Resource = module.ml.endpoint_arn
      },
      {
        Effect   = "Allow"
        Action   = ["sagemaker:GetRecord"]
        Resource = module.ml.feature_group_arn
      },
    ]
  })
}

# The backend GitHub Actions role runs the training/deploy pipeline (train.yml).
resource "aws_iam_role_policy" "github_actions_ml" {
  name = "courtside-prod-github-actions-ml"
  role = module.compute.github_actions_role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          module.ml.ml_bucket_arn,
          "${module.ml.ml_bucket_arn}/*",
        ]
      },
      {
        # Ingest features into the online + offline store.
        Effect   = "Allow"
        Action   = ["sagemaker:PutRecord", "sagemaker:GetRecord", "sagemaker:BatchGetRecord"]
        Resource = module.ml.feature_group_arn
      },
      {
        # Build the training set from the offline store via Athena + Glue.
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:StopQueryExecution",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:GetPartition",
          "glue:GetPartitions",
        ]
        Resource = "*"
      },
      {
        # Register model packages and create/update the Serverless endpoint.
        Effect = "Allow"
        Action = [
          "sagemaker:CreateModel",
          "sagemaker:CreateEndpointConfig",
          "sagemaker:CreateEndpoint",
          "sagemaker:UpdateEndpoint",
          "sagemaker:DescribeEndpoint",
          "sagemaker:DescribeEndpointConfig",
          "sagemaker:DescribeModel",
          "sagemaker:ListEndpoints",
          "sagemaker:CreateModelPackage",
          "sagemaker:ListModelPackages",
          "sagemaker:DescribeModelPackage",
          "sagemaker:UpdateModelPackage",
        ]
        Resource = "*"
      },
      {
        # Log runs to the managed MLflow tracking server.
        Effect = "Allow"
        Action = [
          "sagemaker-mlflow:*",
          "sagemaker:CreatePresignedMlflowTrackingServerUrl",
        ]
        Resource = module.ml.mlflow_tracking_server_arn
      },
      {
        # Hand the execution role to SageMaker for models/endpoints/ingestion.
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = module.ml.sagemaker_exec_role_arn
        Condition = {
          StringEquals = { "iam:PassedToService" = "sagemaker.amazonaws.com" }
        }
      },
    ]
  })
}

module "frontend" {
  source = "../../modules/frontend"
  name   = "courtside-prod"
}

# GitHub Actions role for the frontend repo to deploy to S3 + invalidate CloudFront
data "aws_iam_openid_connect_provider" "github" {
  arn = "arn:aws:iam::794216920868:oidc-provider/token.actions.githubusercontent.com"
}

resource "aws_iam_role" "github_actions_frontend" {
  name = "courtside-prod-github-actions-frontend"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:ngterzis/courtside:*"
        }
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_frontend" {
  name = "courtside-prod-github-actions-frontend"
  role = aws_iam_role.github_actions_frontend.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:DeleteObject", "s3:GetObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${module.frontend.bucket_id}",
          "arn:aws:s3:::${module.frontend.bucket_id}/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation"]
        Resource = "arn:aws:cloudfront::794216920868:distribution/${module.cdn.cloudfront_distribution_id}"
      },
    ]
  })
}

module "cdn" {
  source = "../../modules/cdn"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name             = "courtside-prod"
  domain_name      = local.app_domain
  route53_zone_id  = data.aws_route53_zone.main.zone_id
  s3_bucket_id     = module.frontend.bucket_id
  s3_bucket_domain = module.frontend.bucket_regional_domain
  s3_oac_id        = module.frontend.oac_id

  api_gateway_invoke_url = module.compute.api_gateway_invoke_url
  chat_function_url      = module.compute.chat_function_url
}
