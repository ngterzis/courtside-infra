variable "aws_region" {
  type    = string
  default = "eu-central-1"
}

variable "hosted_zone_name" {
  type        = string
  description = "Root domain registered in Route 53, e.g. mysite.com — the courtside subdomain is derived from this"
}

variable "jwt_secret" {
  type      = string
  sensitive = true
}

variable "anthropic_api_key" {
  type      = string
  sensitive = true
}

# LLM tracing for the chat agent. Empty keys leave tracing off in the backend.
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
  type        = string
  description = "Langfuse region endpoint, e.g. https://cloud.langfuse.com (EU) or https://us.cloud.langfuse.com"
  default     = "https://cloud.langfuse.com"
}

variable "github_repo" {
  type        = string
  description = "org/repo for GitHub Actions OIDC, e.g. ngterzis/courtside-backend"
  default     = "ngterzis/courtside-backend"
}
