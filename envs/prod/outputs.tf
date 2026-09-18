output "cloudfront_domain" { value = module.cdn.cloudfront_domain }
output "cloudfront_distribution_id" { value = module.cdn.cloudfront_distribution_id }
output "frontend_s3_bucket" { value = module.frontend.bucket_id }
output "github_actions_frontend_role_arn" { value = aws_iam_role.github_actions_frontend.arn }
output "ecr_repository_url" { value = module.compute.ecr_repository_url }
output "api_lambda_name" { value = module.compute.api_lambda_name }
output "chat_lambda_name" { value = module.compute.chat_lambda_name }
# Set as API_BASE_URL and CHAT_FUNCTION_URL in courtside-backend, where the
# deploy workflow health-checks both origins before keeping a release.
output "api_gateway_invoke_url" { value = module.compute.api_gateway_invoke_url }
output "chat_function_url" { value = module.compute.chat_function_url }
output "ecs_cluster_name" { value = module.compute.ecs_cluster_name }
output "migrate_task_definition_arn" { value = module.compute.migrate_task_definition_arn }
# Migrate task runs in a public subnet (with assignPublicIp=ENABLED in the run-task
# call) so it has internet egress without a NAT gateway.
output "fargate_subnet_id" { value = module.vpc.public_subnet_ids[0] }
output "fargate_security_group_id" { value = module.compute.fargate_security_group_id }
output "github_actions_role_arn" { value = module.compute.github_actions_role_arn }
