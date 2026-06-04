resource "random_password" "db" {
  length  = 32
  special = false
}

# Secret for RDS Data API (username + password only)
resource "aws_secretsmanager_secret" "db_credentials" {
  name = "${var.name}/db-credentials"
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
  })
}

# Full connection URL for Fargate migration task (psycopg direct connection)
resource "aws_secretsmanager_secret" "db_url" {
  name = "${var.name}/db-url"
}

resource "aws_secretsmanager_secret_version" "db_url" {
  secret_id     = aws_secretsmanager_secret.db_url.id
  secret_string = "postgresql+psycopg://${var.db_username}:${random_password.db.result}@${aws_rds_cluster.main.endpoint}:5432/${var.db_name}"

  # Endpoint isn't known until cluster is created
  depends_on = [aws_rds_cluster_instance.main]
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.name}-db-subnet-group"
  subnet_ids = var.subnet_ids
}

# No ingress rules here — the compute module adds them via aws_security_group_rule
# to avoid a circular module dependency.
resource "aws_security_group" "db" {
  name   = "${var.name}-db-sg"
  vpc_id = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_rds_cluster" "main" {
  cluster_identifier     = "${var.name}-cluster"
  engine                 = "aurora-postgresql"
  engine_mode            = "provisioned"
  engine_version         = "16.6"
  database_name          = var.db_name
  master_username        = var.db_username
  master_password        = random_password.db.result
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  enable_http_endpoint   = true # required for RDS Data API
  skip_final_snapshot    = var.skip_final_snapshot

  serverlessv2_scaling_configuration {
    min_capacity = 0 # scale-to-zero
    max_capacity = var.max_capacity
  }
}

resource "aws_rds_cluster_instance" "main" {
  cluster_identifier = aws_rds_cluster.main.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.main.engine
  engine_version     = aws_rds_cluster.main.engine_version
}
