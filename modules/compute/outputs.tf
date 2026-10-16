output "ecr_repository_url" { value = aws_ecr_repository.main.repository_url }
output "api_lambda_name" { value = aws_lambda_function.api.function_name }
output "chat_lambda_name" { value = aws_lambda_function.chat.function_name }
output "api_gateway_invoke_url" { value = "${aws_api_gateway_stage.main.invoke_url}/" }
output "chat_function_url" { value = aws_lambda_function_url.chat.function_url }
output "fargate_security_group_id" { value = aws_security_group.fargate.id }
output "ecs_cluster_name" { value = aws_ecs_cluster.main.name }
output "migrate_task_definition_arn" { value = aws_ecs_task_definition.migrate.arn }
output "github_actions_role_arn" { value = aws_iam_role.github_actions.arn }
output "origin_secret" {
  value     = random_password.origin_secret.result
  sensitive = true
}
