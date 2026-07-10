output "ml_bucket" { value = aws_s3_bucket.ml.bucket }
output "ml_bucket_arn" { value = aws_s3_bucket.ml.arn }

output "offline_store_s3" { value = local.offline_store_uri }
output "athena_output_s3" { value = local.athena_output_uri }
output "athena_workgroup" { value = aws_athena_workgroup.ml.name }

output "sagemaker_exec_role_arn" { value = aws_iam_role.sagemaker_exec.arn }
output "sagemaker_exec_role_name" { value = aws_iam_role.sagemaker_exec.name }

output "feature_group_name" { value = aws_sagemaker_feature_group.player_form.feature_group_name }
output "feature_group_arn" { value = aws_sagemaker_feature_group.player_form.arn }

output "model_package_group_name" { value = aws_sagemaker_model_package_group.next_game_points.model_package_group_name }
output "model_package_group_arn" { value = aws_sagemaker_model_package_group.next_game_points.arn }

output "mlflow_tracking_server_arn" { value = aws_sagemaker_mlflow_tracking_server.main.arn }

output "endpoint_name" { value = var.endpoint_name }
output "endpoint_arn" { value = local.endpoint_arn }

output "pipeline_name" { value = var.pipeline_name }
output "pipeline_arn" { value = local.pipeline_arn }
output "pipeline_repository_url" { value = aws_ecr_repository.pipeline.repository_url }
