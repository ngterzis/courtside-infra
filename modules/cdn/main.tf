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

# S3 bucket for CloudFront standard access logs. The c-ip field captures the real
# viewer IP for every request across all paths (frontend, /api/*, chat).
resource "aws_s3_bucket" "cf_logs" {
  bucket        = "${var.name}-cloudfront-logs"
  force_destroy = true
}

# CloudFront standard log delivery writes via the awslogsdelivery account using a
# bucket ACL, so ACLs must be enabled (BucketOwnerPreferred). CloudFront adds the
# required grant automatically when logging_config is set.
resource "aws_s3_bucket_ownership_controls" "cf_logs" {
  bucket = aws_s3_bucket.cf_logs.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_public_access_block" "cf_logs" {
  bucket                  = aws_s3_bucket.cf_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Expire logs after the retention window — IP addresses are personal data (GDPR).
resource "aws_s3_bucket_lifecycle_configuration" "cf_logs" {
  bucket = aws_s3_bucket.cf_logs.id
  rule {
    id     = "expire-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = var.log_retention_days
    }
  }
}

# SPA routing: rewrite client-side routes (/login, /games/123) to /index.html at the
# edge. S3 returns 403 (not 404) for missing keys since CloudFront lacks ListBucket,
# and distribution-wide custom_error_responses would also rewrite API errors.
resource "aws_cloudfront_function" "spa_rewrite" {
  name    = "${var.name}-spa-rewrite"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = <<-EOF
    function handler(event) {
      var request = event.request;
      var uri = request.uri;
      // Paths whose last segment has an extension are real objects (assets, favicon)
      var last = uri.substring(uri.lastIndexOf('/') + 1);
      if (last.indexOf('.') === -1) {
        request.uri = '/index.html';
      }
      return request;
    }
  EOF
}

resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  aliases             = [var.domain_name]

  logging_config {
    bucket          = aws_s3_bucket.cf_logs.bucket_domain_name
    prefix          = "cloudfront/"
    include_cookies = false
  }

  # Ensure ACLs are enabled before CloudFront tries to grant itself log-write access
  depends_on = [aws_s3_bucket_ownership_controls.cf_logs]

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
    custom_header {
      name  = "X-Origin-Verify"
      value = var.origin_secret
    }
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
    custom_header {
      name  = "X-Origin-Verify"
      value = var.origin_secret
    }
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

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.spa_rewrite.arn
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
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
