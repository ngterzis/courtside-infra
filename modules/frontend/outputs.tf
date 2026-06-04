output "bucket_id" { value = aws_s3_bucket.main.id }
output "bucket_regional_domain" { value = aws_s3_bucket.main.bucket_regional_domain_name }
output "oac_id" { value = aws_cloudfront_origin_access_control.s3.id }
