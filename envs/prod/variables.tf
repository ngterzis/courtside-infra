variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "domain_name" {
  type        = string
  description = "Root domain for the app, e.g. courtside.app"
}

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
  description = "org/repo for GitHub Actions OIDC, e.g. ngterzis/courtside-backend"
  default     = "ngterzis/courtside-backend"
}
