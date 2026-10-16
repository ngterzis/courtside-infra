variable "name" { type = string }
variable "domain_name" {
  type        = string
  description = "Full subdomain to serve, e.g. courtside.mysite.com"
}
variable "route53_zone_id" { type = string }
variable "s3_bucket_id" { type = string }
variable "s3_bucket_domain" { type = string }
variable "s3_oac_id" { type = string }
variable "api_gateway_invoke_url" { type = string }
variable "chat_function_url" { type = string }

variable "log_retention_days" {
  type        = number
  default     = 90
  description = "Days to retain CloudFront access logs before S3 expires them. IP addresses are personal data — keep this short."
}

variable "origin_secret" {
  type        = string
  sensitive   = true
  description = "Sent to the API and chat origins as X-Origin-Verify; the app rejects requests without it."
}
