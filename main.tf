data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  files      = fileset("${path.module}/samples", "**")
  delete_at  = timeadd(terraform_data.upload_completed.output, "72h")
}

resource "aws_s3_bucket" "demo" {
  bucket_prefix = "hmp-three-day-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "demo" {
  bucket                  = aws_s3_bucket.demo.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "demo" {
  bucket = aws_s3_bucket.demo.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "demo" {
  bucket = aws_s3_bucket.demo.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_object" "sample" {
  for_each               = local.files
  bucket                 = aws_s3_bucket.demo.id
  key                    = each.value
  source                 = "${path.module}/samples/${each.value}"
  etag                   = filemd5("${path.module}/samples/${each.value}")
  server_side_encryption = "AES256"
  depends_on = [aws_s3_bucket_public_access_block.demo,
    aws_s3_bucket_ownership_controls.demo,
  aws_s3_bucket_server_side_encryption_configuration.demo]
}

# Captured during the first apply AFTER uploads. Ordinary plans/applies never reset it.
resource "terraform_data" "upload_completed" {
  input            = timestamp()
  triggers_replace = [aws_s3_bucket.demo.id]
  depends_on       = [aws_s3_object.sample]
  lifecycle { ignore_changes = [input] }
}

resource "aws_s3_bucket_policy" "demo" {
  bucket = aws_s3_bucket.demo.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport", Effect = "Deny", Principal = "*"
        Action    = "s3:*", Resource = [aws_s3_bucket.demo.arn, "${aws_s3_bucket.demo.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "StopNewObjectsAtDeadline", Effect = "Deny", Principal = "*"
        Action    = ["s3:PutObject", "s3:ReplicateObject"], Resource = "${aws_s3_bucket.demo.arn}/*"
        Condition = { DateGreaterThanEquals = { "aws:CurrentTime" = local.delete_at } }
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "cleanup" {
  name              = "/aws/lambda/${aws_s3_bucket.demo.id}-cleanup"
  retention_in_days = 7
}

resource "aws_sqs_queue" "failures" {
  name_prefix               = "hmp-cleanup-failures-"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_iam_role" "cleanup" {
  name_prefix = "hmp-s3-cleanup-"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "cleanup" {
  role = aws_iam_role.cleanup.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:ListBucket", "s3:ListBucketVersions", "s3:ListBucketMultipartUploads", "s3:DeleteBucket"], Resource = aws_s3_bucket.demo.arn },
      { Effect = "Allow", Action = ["s3:DeleteObject", "s3:DeleteObjectVersion", "s3:AbortMultipartUpload"], Resource = "${aws_s3_bucket.demo.arn}/*" },
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.cleanup.arn}:*" },
      { Effect = "Allow", Action = ["sqs:SendMessage"], Resource = aws_sqs_queue.failures.arn }
    ]
  })
}

resource "aws_lambda_function" "cleanup" {
  function_name    = "${aws_s3_bucket.demo.id}-cleanup"
  role             = aws_iam_role.cleanup.arn
  runtime          = "python3.13"
  handler          = "cleanup.handler"
  filename         = "${path.module}/lambda/cleanup.zip"
  source_code_hash = filebase64sha256("${path.module}/lambda/cleanup.zip")
  timeout          = 900
  memory_size      = 128
  environment {
    variables = {
      BUCKET_NAME    = aws_s3_bucket.demo.id
      EXPECTED_OWNER = local.account_id
      DELETE_AT      = local.delete_at
    }
  }
  dead_letter_config { target_arn = aws_sqs_queue.failures.arn }
  depends_on = [aws_iam_role_policy.cleanup, aws_cloudwatch_log_group.cleanup]
}

resource "aws_lambda_function_event_invoke_config" "cleanup" {
  function_name                = aws_lambda_function.cleanup.function_name
  maximum_retry_attempts       = 2
  maximum_event_age_in_seconds = 21600
}

resource "aws_scheduler_schedule_group" "demo" {
  name_prefix = "hmp-three-day-"
}

resource "aws_iam_role" "scheduler" {
  name_prefix = "hmp-s3-scheduler-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Principal = { Service = "scheduler.amazonaws.com" }, Action = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnEquals    = { "aws:SourceArn" = aws_scheduler_schedule_group.demo.arn }
      }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "lambda:InvokeFunction", Resource = aws_lambda_function.cleanup.arn },
      { Effect = "Allow", Action = "sqs:SendMessage", Resource = aws_sqs_queue.failures.arn }
    ]
  })
}

resource "aws_scheduler_schedule" "cleanup" {
  name                         = "delete-demo-bucket"
  group_name                   = aws_scheduler_schedule_group.demo.name
  schedule_expression          = "at(${trimsuffix(local.delete_at, "Z")})"
  schedule_expression_timezone = "UTC"
  action_after_completion      = "DELETE"
  flexible_time_window { mode = "OFF" }
  target {
    arn      = aws_lambda_function.cleanup.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ reason = "three-day-demo-expired" })
    retry_policy {
      maximum_event_age_in_seconds = 86400
      maximum_retry_attempts       = 185
    }
    dead_letter_config { arn = aws_sqs_queue.failures.arn }
  }
  depends_on = [aws_iam_role_policy.scheduler, aws_lambda_function_event_invoke_config.cleanup, aws_s3_bucket_policy.demo]
}
