"""Delete only the environment-bound demo bucket. No event-supplied targets."""
import os
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError


def _delete_batch(s3, bucket, owner, objects):
    if not objects:
        return
    result = s3.delete_objects(
        Bucket=bucket, ExpectedBucketOwner=owner,
        Delete={"Objects": objects, "Quiet": True},
    )
    if result.get("Errors"):
        raise RuntimeError("S3 batch deletion failed; inspect bucket permissions/locks")


def handler(event, context):
    bucket = os.environ["BUCKET_NAME"]
    owner = os.environ["EXPECTED_OWNER"]
    deadline = datetime.fromisoformat(os.environ["DELETE_AT"].replace("Z", "+00:00"))
    if datetime.now(timezone.utc) < deadline:
        raise RuntimeError("Cleanup deadline has not been reached")
    s3 = boto3.client("s3", region_name="eu-north-1")
    args = {"Bucket": bucket, "ExpectedBucketOwner": owner}
    try:
        # Re-read the first page after each mutation: pagination markers may be deleted.
        while True:
            page = s3.list_multipart_uploads(**args, MaxUploads=1000)
            uploads = page.get("Uploads", [])
            if not uploads:
                break
            for upload in uploads:
                s3.abort_multipart_upload(**args, Key=upload["Key"], UploadId=upload["UploadId"])
        while True:
            page = s3.list_object_versions(**args, MaxKeys=1000)
            versions = page.get("Versions", []) + page.get("DeleteMarkers", [])
            if not versions:
                break
            _delete_batch(s3, bucket, owner, [
                {"Key": item["Key"], "VersionId": item["VersionId"]}
                for item in versions
            ])
        while True:
            page = s3.list_objects_v2(**args, MaxKeys=1000)
            objects = page.get("Contents", [])
            if not objects:
                break
            _delete_batch(s3, bucket, owner, [{"Key": item["Key"]} for item in objects])
        s3.delete_bucket(**args)
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "NoSuchBucket":
            return {"status": "already_deleted"}
        raise
    print("Demo bucket cleanup completed")
    return {"status": "deleted"}
