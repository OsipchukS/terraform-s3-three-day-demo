"""Offline tests: no boto3 installation, credentials, network or AWS calls."""
import importlib.util
import os
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import MagicMock, patch


class ClientError(Exception):
    def __init__(self, code):
        self.response = {"Error": {"Code": code}}


fake_boto = types.ModuleType("boto3")
fake_boto.client = MagicMock()
fake_errors = types.ModuleType("botocore.exceptions")
fake_errors.ClientError = ClientError
with patch.dict(sys.modules, {"boto3": fake_boto, "botocore": types.ModuleType("botocore"), "botocore.exceptions": fake_errors}):
    spec = importlib.util.spec_from_file_location("cleanup", Path(__file__).resolve().parents[1] / "lambda" / "cleanup.py")
    cleanup = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cleanup)


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, {
            "BUCKET_NAME": "only-demo", "EXPECTED_OWNER": "123456789012",
            "DELETE_AT": "2020-01-01T00:00:00Z",
        })
        self.env.start()
        self.addCleanup(self.env.stop)
        self.s3 = MagicMock()
        fake_boto.client.reset_mock()
        fake_boto.client.return_value = self.s3
        self.s3.list_multipart_uploads.return_value = {}
        self.s3.list_object_versions.return_value = {}
        self.s3.list_objects_v2.return_value = {}
        self.s3.delete_objects.return_value = {}

    def test_empty_and_event_cannot_select_another_bucket(self):
        self.assertEqual(cleanup.handler({"bucket": "production"}, None), {"status": "deleted"})
        self.s3.delete_bucket.assert_called_once_with(Bucket="only-demo", ExpectedBucketOwner="123456789012")

    def test_multiple_pages_versions_markers_and_uploads(self):
        self.s3.list_multipart_uploads.side_effect = [{"Uploads": [{"Key": "partial", "UploadId": "u1"}]}, {}]
        self.s3.list_object_versions.side_effect = [
            {"Versions": [{"Key": f"k{i}", "VersionId": "v1"} for i in range(999)], "DeleteMarkers": [{"Key": "old", "VersionId": "d1"}]},
            {"Versions": [{"Key": "last", "VersionId": "v2"}]}, {},
        ]
        self.s3.list_objects_v2.side_effect = [{"Contents": [{"Key": "unversioned"}]}, {}]
        cleanup.handler({}, None)
        batches = self.s3.delete_objects.call_args_list
        self.assertEqual([len(call.kwargs["Delete"]["Objects"]) for call in batches], [1000, 1, 1])
        self.s3.abort_multipart_upload.assert_called_once()
        for call in batches:
            self.assertEqual(call.kwargs["ExpectedBucketOwner"], "123456789012")
        self.s3.delete_bucket.assert_called_once()

    def test_missing_bucket_is_success(self):
        self.s3.list_multipart_uploads.side_effect = ClientError("NoSuchBucket")
        self.assertEqual(cleanup.handler({}, None), {"status": "already_deleted"})

    def test_partial_delete_error_fails_for_retry(self):
        self.s3.list_objects_v2.return_value = {"Contents": [{"Key": "locked"}]}
        self.s3.delete_objects.return_value = {"Errors": [{"Code": "AccessDenied"}]}
        with self.assertRaises(RuntimeError):
            cleanup.handler({}, None)
        self.s3.delete_bucket.assert_not_called()

    def test_access_denied_is_not_suppressed(self):
        self.s3.list_object_versions.side_effect = ClientError("AccessDenied")
        with self.assertRaises(ClientError):
            cleanup.handler({}, None)

    def test_bucket_not_empty_is_retryable(self):
        self.s3.delete_bucket.side_effect = ClientError("BucketNotEmpty")
        with self.assertRaises(ClientError):
            cleanup.handler({}, None)

    def test_early_invocation_is_rejected(self):
        os.environ["DELETE_AT"] = "2099-01-01T00:00:00Z"
        with self.assertRaises(RuntimeError):
            cleanup.handler({}, None)
        fake_boto.client.assert_not_called()


if __name__ == "__main__":
    unittest.main()
