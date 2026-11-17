mock_provider "aws" {
  override_during = plan
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_partition" { defaults = { partition = "aws" } }
  mock_resource "aws_s3_bucket" {
    defaults = { id = "hmp-three-day-test", arn = "arn:aws:s3:::hmp-three-day-test" }
  }
}

run "private_bucket_and_scoped_cleanup" {
  command = plan
  override_resource {
    target          = aws_cloudwatch_log_group.cleanup
    values          = { arn = "arn:aws:logs:eu-north-1:123456789012:log-group:/aws/lambda/demo" }
    override_during = plan
  }
  override_resource {
    target          = aws_sqs_queue.failures
    values          = { arn = "arn:aws:sqs:eu-north-1:123456789012:failures" }
    override_during = plan
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.demo.block_public_acls && aws_s3_bucket_public_access_block.demo.block_public_policy && aws_s3_bucket_public_access_block.demo.ignore_public_acls && aws_s3_bucket_public_access_block.demo.restrict_public_buckets
    error_message = "All four public-access protections must be enabled."
  }
  assert {
    condition     = length(aws_s3_object.sample) == 3 && aws_s3_bucket_ownership_controls.demo.rule[0].object_ownership == "BucketOwnerEnforced"
    error_message = "Expected three files and ACLs disabled."
  }
  assert {
    condition     = aws_scheduler_schedule.cleanup.action_after_completion == "DELETE" && aws_scheduler_schedule.cleanup.flexible_time_window[0].mode == "OFF" && aws_scheduler_schedule.cleanup.schedule_expression_timezone == "UTC"
    error_message = "Expected one-time UTC scheduling without a flexible window."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.cleanup.policy).Statement[0].Resource == "arn:aws:s3:::hmp-three-day-test" && jsondecode(aws_iam_role_policy.cleanup.policy).Statement[1].Resource == "arn:aws:s3:::hmp-three-day-test/*"
    error_message = "Cleanup permissions must be restricted to the demo bucket."
  }
  assert {
    condition     = aws_lambda_function_event_invoke_config.cleanup.maximum_retry_attempts == 2 && aws_lambda_function.cleanup.timeout == 900
    error_message = "Lambda must retry execution failures and have time to empty the bucket."
  }
}

run "stable_72_hour_deadline" {
  command = plan
  override_resource {
    target          = terraform_data.upload_completed
    values          = { output = "2026-11-17T12:00:00Z" }
    override_during = plan
  }
  assert {
    condition     = output.cleanup_at_utc == "2026-11-20T12:00:00Z" && aws_scheduler_schedule.cleanup.schedule_expression == "at(2026-11-20T12:00:00)"
    error_message = "Deletion must be scheduled exactly 72 hours after the recorded upload completion."
  }
  assert {
    condition     = jsondecode(aws_s3_bucket_policy.demo.policy).Statement[1].Condition.DateGreaterThanEquals["aws:CurrentTime"] == "2026-11-20T12:00:00Z"
    error_message = "New uploads must stop at the cleanup deadline."
  }
}
