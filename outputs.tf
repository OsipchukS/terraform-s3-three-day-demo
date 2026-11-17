output "bucket_name" { value = aws_s3_bucket.demo.id }
output "uploaded_files" { value = sort(tolist(local.files)) }
output "cleanup_at_utc" { value = local.delete_at }
output "cleanup_function_name" { value = aws_lambda_function.cleanup.function_name }
output "failure_queue_url" { value = aws_sqs_queue.failures.url }
