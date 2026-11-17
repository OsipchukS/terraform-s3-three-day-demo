# Three-day private S3 demo

An independent Terraform project that uploads three sample files to a private S3 bucket in **Europe (Stockholm), eu-north-1**, then schedules deletion of the files and the bucket after 72 hours.

## Requirements

- Terraform >= 1.16.5 and < 2.0.
- AWS provider 6.68.0 (pinned in the dependency lock file).
- Python 3.13 or compatible Python 3 for local packaging and tests.
- AWS credentials supplied externally through a standard AWS profile, SSO session, or environment variables.
- Deployment permissions for the demo's S3, Lambda, IAM roles and inline policies, IAM PassRole, Scheduler, CloudWatch Logs, and SQS resources.

Never place credentials in Terraform source, sample files, or committed variable files. This repository includes no credentials, Terraform state, saved plans, or provider binaries.

## How cleanup works

1. Terraform creates an S3 bucket with all four public-access blocks enabled, BucketOwnerEnforced ownership, and AES256 server-side encryption.
2. It uploads the three files in samples/.
3. After the initial uploads finish, terraform_data records an apply-time UTC timestamp. The deletion deadline is that timestamp plus 72 hours.
4. EventBridge Scheduler invokes a Python Lambda once at the deadline. The schedule uses UTC and has no flexible time window.
5. Lambda aborts unfinished multipart uploads, deletes object versions, delete markers and remaining objects, then deletes the bucket. It uses only the bucket name and expected owner configured in its environment; an event cannot select another bucket.
6. The one-time schedule deletes itself after invocation.

This project uses **Scheduler and Lambda, not S3 Lifecycle**. S3 Lifecycle handles objects and does not delete the bucket.

Normal subsequent plans and applies do not move the recorded deadline. Replacing the bucket starts a new countdown. The bucket policy denies new object writes at the deadline to reduce races during cleanup.

Scheduler has minute-level precision, and asynchronous invocation and retries can delay completion. This is scheduled cleanup rather than a guarantee of deletion at an exact second.

## Local checks without AWS resources

Run from the project directory:

~~~powershell
python build.py
terraform init -backend=false
terraform fmt -check -recursive
terraform validate
terraform test
python -m unittest discover -s tests -p 'test_*.py' -v
~~~

Both Terraform test runs use plan with a mocked AWS provider. The seven Python tests replace the AWS SDK and do not need boto3, credentials, or network access. The Lambda runtime supplies boto3.

The included lambda/cleanup.zip is built reproducibly from lambda/cleanup.py. Rebuild it with python build.py after editing the handler.

## Deployment

Configure AWS authentication outside this repository, then review and apply a fresh plan:

~~~powershell
terraform init
terraform plan -out='demo.tfplan'
terraform apply 'demo.tfplan'
terraform output
~~~

Creating these resources may incur AWS charges. The local backend stores state in terraform.tfstate in this directory. Keep that file and its backups private and secure. Do not reuse another project's state.

The outputs identify the bucket, uploaded files, cleanup function, failure queue, and deletion time in UTC.

## Failures and operational limits

Scheduler retries delivery failures for up to 24 hours. Lambda separately retries execution errors twice, with a maximum event age of six hours. Both paths use an encrypted SQS dead-letter queue with 14-day message retention. Automatic alerts are not configured.

The cleanup log group is /aws/lambda/<bucket-name>-cleanup, with seven-day retention. Monitor it and the failure queue if cleanup fails.

This is a small demo. Lambda has a 15-minute timeout; do not use the bucket for large datasets. Do not enable Object Lock or MFA Delete or change the bucket's permissions externally, since these can prevent cleanup.

If initial deployment fails before Scheduler is created, automatic deletion is not configured yet. Finish the deployment or clean up the partial resources.

## Final cleanup

After automatic deletion of the bucket, Lambda, its retry configuration, IAM roles and policies, the log group, SQS queue, and Scheduler group remain for diagnostics.

Review their deletion from this project's directory:

~~~powershell
terraform plan -destroy -out='cleanup.tfplan'
terraform apply 'cleanup.tfplan'
~~~

After the bucket and one-time schedule disappear, Terraform state can temporarily refer to missing resources. A normal apply can recreate them. Use the reviewed destroy plan to finish the demo instead.

The bucket has force_destroy enabled, so Terraform destroy can also remove it while it still contains files.

## Validation

Validated with Terraform 1.16.5, AWS provider 6.68.0 and Windows amd64:

- terraform fmt -check -recursive: passed.
- terraform validate: passed.
- terraform test: 2 passed.
- Python unittest: 7 passed.
- Lambda ZIP contents match the source file.

Successful deployment and a subsequent read-only AWS refresh confirmed the uploaded objects and schedule. Actual execution of the scheduled deletion has not yet been verified.

## AWS references

- [Scheduler schedule types and precision](https://docs.aws.amazon.com/scheduler/latest/UserGuide/schedule-types.html)
- [Asynchronous Lambda invocation through Scheduler](https://docs.aws.amazon.com/lambda/latest/dg/with-eventbridge-scheduler.html)
- [Scheduler CreateSchedule API](https://docs.aws.amazon.com/scheduler/latest/APIReference/API_CreateSchedule.html)
