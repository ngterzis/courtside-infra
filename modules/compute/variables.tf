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
variable "langfuse_public_key" {
  type    = string
  default = ""
}
variable "langfuse_secret_key" {
  type      = string
  sensitive = true
  default   = ""
}
variable "langfuse_host" {
  type    = string
  default = "https://cloud.langfuse.com"
}
variable "github_repo" {
  type        = string
  description = "org/repo for GitHub Actions OIDC trust, e.g. ngterzis/courtside-backend"
}
