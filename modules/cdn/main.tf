terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.us_east_1]
    }
  }
}

# ACM cert must be in us-east-1 for CloudFront
resource "aws_acm_certificate" "main" {
  provider          = aws.us_east_1
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle { create_before_destroy = true }
}

# DNS validation records — Route 53 is global, no provider alias needed
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  zone_id         = var.route53_zone_id
  name            = each.value.name
  records         = [each.value.record]
  type            = each.value.type
  ttl             = 60
}

resource "aws_acm_certificate_validation" "main" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

locals {
  s3_origin_id    = "s3-frontend"
  apigw_origin_id = "apigw-api"
  chat_origin_id  = "lambda-chat"

  # Extract hostname and stage path separately from the API Gateway invoke URL
  # e.g. "https://id.execute-api.region.amazonaws.com/prod/" → host="id..." path="/prod"
  _apigw_parts = split("/", replace(var.api_gateway_invoke_url, "https://", ""))
  apigw_domain = local._apigw_parts[0]
  apigw_path   = "/${local._apigw_parts[1]}"

  # Lambda Function URL has no path component, just strip scheme and trailing slash
  chat_domain = trimsuffix(replace(var.chat_function_url, "https://", ""), "/")
}

resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  aliases             = [var.domain_name]

  # Origin 1: S3 (frontend static files)
  origin {
    origin_id                = local.s3_origin_id
    domain_name              = var.s3_bucket_domain
    origin_access_control_id = var.s3_oac_id
  }

  # Origin 2: API Gateway REST (all /api/* except chat)
  origin {
    origin_id   = local.apigw_origin_id
    domain_name = local.apigw_domain
    origin_path = local.apigw_path
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # Origin 3: Lambda Function URL (/api/chat*). AuthType=NONE, so no OAC signing —
  # the app enforces JWT auth.
  origin {
    origin_id   = local.chat_origin_id
    domain_name = local.chat_domain
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # /api/chat* → Lambda Function URL (no caching, stream through)
  ordered_cache_behavior {
    path_pattern           = "/api/chat*"
    target_origin_id       = local.chat_origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    compress               = false

    # Forward Authorization so the app receives the viewer's JWT. With the
    # Function URL on AuthType=NONE there's no OAC signature competing for it.
    forwarded_values {
      query_string = true
      headers      = ["Authorization", "Content-Type"]
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  # /api/* → API Gateway
  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = local.apigw_origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    forwarded_values {
      query_string = true
      headers      = ["Authorization", "Content-Type"]
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  # /* → S3 (SPA fallback)
  default_cache_behavior {
    target_origin_id       = local.s3_origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  # SPA: serve index.html for all 404s so React Router works
  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    # Use the validated ARN so CloudFront waits for DNS propagation
    acm_certificate_arn      = aws_acm_certificate_validation.main.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# A alias record: courtside.<domain> → CloudFront
resource "aws_route53_record" "app" {
  zone_id = var.route53_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}
