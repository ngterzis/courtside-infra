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
variable "chat_lambda_name" { type = string }
