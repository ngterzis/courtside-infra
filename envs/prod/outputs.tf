output "cloudfront_domain" { value = module.cdn.cloudfront_domain }
output "cloudfront_distribution_id" { value = module.cdn.cloudfront_distribution_id }
output "frontend_s3_bucket" { value = module.frontend.bucket_id }
output "github_actions_frontend_role_arn" { value = aws_iam_role.github_actions_frontend.arn }
output "ecr_repository_url" { value = module.compute.ecr_repository_url }
output "api_lambda_name" { value = module.compute.api_lambda_name }
output "chat_lambda_name" { value = module.compute.chat_lambda_name }
output "ecs_cluster_name" { value = module.compute.ecs_cluster_name }
output "migrate_task_definition_arn" { value = module.compute.migrate_task_definition_arn }
# Migrate task runs in a public subnet (with assignPublicIp=ENABLED in the run-task
# call) so it has internet egress without a NAT gateway.
output "fargate_subnet_id" { value = module.vpc.public_subnet_ids[0] }
output "fargate_security_group_id" { value = module.compute.fargate_security_group_id }
output "github_actions_role_arn" { value = module.compute.github_actions_role_arn }

# ── ML pipeline (set these as env in the backend repo's train.yml) ────────────
output "ml_bucket" { value = module.ml.ml_bucket }
output "ml_feature_group_name" { value = module.ml.feature_group_name }
output "ml_offline_store_s3" { value = module.ml.offline_store_s3 }
output "ml_athena_output_s3" { value = module.ml.athena_output_s3 }
output "ml_sagemaker_role_arn" { value = module.ml.sagemaker_exec_role_arn }
output "ml_model_package_group" { value = module.ml.model_package_group_name }
output "ml_endpoint_name" { value = module.ml.endpoint_name }
output "mlflow_tracking_server_arn" { value = module.ml.mlflow_tracking_server_arn }
output "ml_pipeline_name" { value = module.ml.pipeline_name }
output "ml_pipeline_repository_url" { value = module.ml.pipeline_repository_url }
output "db_cluster_arn" { value = module.database.cluster_arn }
output "db_credentials_secret_arn" { value = module.database.db_credentials_secret_arn }
