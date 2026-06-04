module "vpc" {
  source = "../../modules/vpc"

  name                 = "courtside-prod"
  cidr                 = "10.0.0.0/16"
  azs                  = ["eu-west-1a", "eu-west-1b"]
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

  jwt_secret        = var.jwt_secret
  anthropic_api_key = var.anthropic_api_key
  github_repo       = var.github_repo
}

module "frontend" {
  source = "../../modules/frontend"
  name   = "courtside-prod"
}

module "cdn" {
  source = "../../modules/cdn"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name             = "courtside-prod"
  domain_name      = var.domain_name
  s3_bucket_id     = module.frontend.bucket_id
  s3_bucket_domain = module.frontend.bucket_regional_domain
  s3_oac_id        = module.frontend.oac_id

  api_gateway_invoke_url = module.compute.api_gateway_invoke_url
  chat_function_url      = module.compute.chat_function_url
}
