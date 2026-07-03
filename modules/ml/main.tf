data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  offline_store_uri = "s3://${aws_s3_bucket.ml.bucket}/feature-store"
  athena_output_uri = "s3://${aws_s3_bucket.ml.bucket}/athena"
  mlflow_artifacts  = "s3://${aws_s3_bucket.ml.bucket}/mlflow"

  # The endpoint is created at deploy time (not by Terraform), but IAM needs its ARN.
  endpoint_arn = "arn:aws:sagemaker:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:endpoint/${var.endpoint_name}"
}

# ── S3: offline feature store + Athena results + MLflow artifacts ──────────────

resource "aws_s3_bucket" "ml" {
  bucket = "${var.name}-ml-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "ml" {
  bucket                  = aws_s3_bucket.ml.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ml" {
  bucket = aws_s3_bucket.ml.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# ── IAM: SageMaker execution role ─────────────────────────────────────────────
# Assumed by SageMaker services: Feature Store (offline writes + Glue table),
# the managed MLflow server (artifact writes), and Model/Endpoint (pull model
# artifact from S3 + the built-in XGBoost image from ECR).

resource "aws_iam_role" "sagemaker_exec" {
  name = "${var.name}-sagemaker-exec"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sagemaker.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Broad SageMaker access is the standard guidance for an execution role and keeps a
# learning setup working first-try (Glue/Athena/ECR for the built-in containers).
# S3 is granted separately below because the managed policy only covers buckets
# whose name contains "sagemaker".
resource "aws_iam_role_policy_attachment" "sagemaker_full" {
  role       = aws_iam_role.sagemaker_exec.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSageMakerFullAccess"
}

resource "aws_iam_role_policy" "sagemaker_exec_s3" {
  name = "${var.name}-sagemaker-exec-s3"
  role = aws_iam_role.sagemaker_exec.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
      Resource = [
        aws_s3_bucket.ml.arn,
        "${aws_s3_bucket.ml.arn}/*",
      ]
    }]
  })
}

# ── Feature Store: player-form feature group ──────────────────────────────────

resource "aws_sagemaker_feature_group" "player_form" {
  feature_group_name             = var.feature_group_name
  record_identifier_feature_name = "record_id"
  event_time_feature_name        = "event_time"
  role_arn                       = aws_iam_role.sagemaker_exec.arn

  feature_definition {
    feature_name = "record_id"
    feature_type = "String"
  }
  feature_definition {
    feature_name = "player_id"
    feature_type = "String"
  }
  feature_definition {
    feature_name = "event_time"
    feature_type = "String"
  }
  feature_definition {
    feature_name = "label"
    feature_type = "Fractional"
  }

  dynamic "feature_definition" {
    for_each = var.feature_names
    content {
      feature_name = feature_definition.value
      feature_type = "Fractional"
    }
  }

  online_store_config {
    enable_online_store = true
  }

  offline_store_config {
    s3_storage_config {
      s3_uri = local.offline_store_uri
    }
  }

  depends_on = [aws_iam_role_policy.sagemaker_exec_s3]
}

# ── Model Registry: package group (packages/versions created by the pipeline) ──

resource "aws_sagemaker_model_package_group" "next_game_points" {
  model_package_group_name = var.model_package_group_name
}

# ── Managed MLflow tracking server ────────────────────────────────────────────
# Its ARN is the tracking URI clients pass to MLFLOW_TRACKING_URI (with the
# sagemaker-mlflow plugin). AWS hosts it — no server to run ourselves.

resource "aws_sagemaker_mlflow_tracking_server" "main" {
  tracking_server_name = "${var.name}-mlflow"
  artifact_store_uri   = local.mlflow_artifacts
  role_arn             = aws_iam_role.sagemaker_exec.arn
  tracking_server_size = var.mlflow_server_size
}
