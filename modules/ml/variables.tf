variable "name" {
  type        = string
  description = "Resource name prefix, e.g. courtside-prod"
}

variable "feature_group_name" {
  type        = string
  description = "SageMaker Feature Store feature group name"
}

variable "feature_names" {
  type        = list(string)
  description = <<-EOT
    Fractional model-input feature columns. MUST stay in sync with
    courtside.ml.features.FEATURE_NAMES in the backend repo — a mismatch silently
    breaks online GetRecord / inference. record_id, player_id, event_time and label
    are added automatically and are not part of this list.
  EOT
}

variable "model_package_group_name" {
  type        = string
  description = "SageMaker Model Registry package group for the next-game-points model"
}

variable "endpoint_name" {
  type        = string
  description = "Serverless inference endpoint name (created by the deploy pipeline, not Terraform)"
}

variable "mlflow_server_size" {
  type        = string
  default     = "Small"
  description = "Managed MLflow tracking server size"
}
