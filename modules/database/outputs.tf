output "cluster_arn" { value = aws_rds_cluster.main.arn }
output "db_credentials_secret_arn" { value = aws_secretsmanager_secret.db_credentials.arn }
output "db_url_secret_arn" { value = aws_secretsmanager_secret.db_url.arn }
output "db_security_group_id" { value = aws_security_group.db.id }
