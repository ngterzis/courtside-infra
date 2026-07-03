variable "name" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "db_security_group_id" { type = string }
variable "cluster_arn" { type = string }
variable "db_credentials_secret_arn" { type = string }
variable "db_url_secret_arn" { type = string }
variable "db_name" { type = string }
variable "jwt_secret" {
  type      = string
  sensitive = true
}
variable "anthropic_api_key" {
  type      = string
  sensitive = true
}
variable "github_repo" {
  type        = string
  description = "org/repo for GitHub Actions OIDC trust, e.g. ngterzis/courtside-backend"
}

# Next-game points model. Both default to "" so the API falls back to the
# trailing-average baseline until an endpoint exists — set sagemaker_endpoint_name
# once the deploy pipeline has shipped the Serverless endpoint.
variable "sagemaker_endpoint_name" {
  type    = string
  default = ""
}

variable "feature_group_name" {
  type    = string
  default = ""
}
