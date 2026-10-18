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

  jwt_secret          = var.jwt_secret
  anthropic_api_key   = var.anthropic_api_key
  langfuse_public_key = var.langfuse_public_key
  langfuse_secret_key = var.langfuse_secret_key
  langfuse_host       = var.langfuse_host
  github_repo         = var.github_repo
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
  origin_secret          = module.compute.origin_secret
}
