#!/usr/bin/env python3
"""Run every standalone S3 package test against disposable same-host RustFS."""

import argparse
import json
import os
from pathlib import Path
import re
import secrets
import socket
import subprocess
import tempfile
import time

import boto3
from botocore.config import Config


PACKAGE = Path(__file__).resolve().parents[1]
IMAGE = "rustfs/rustfs@sha256:41fe89380f4120a337790c02af192c3fe7bb55c3edc2e6e9357b487b47c6ab21"
ROOT_URL = "https://github.com/teaql/teaql-swift.git"
FORMATS = ("pdf", "production-pdf", "jpg", "jpeg", "png", "mp3", "mp4",
           "docx", "xlsx", "doc", "xls")
RECEIPTS = (
    "S3StorageTests.testMinioRealSignedRangeAndExpiry",
    "S3StorageTests.testRealS3ConditionalDelete",
    "BlobMaintenanceS3Tests.testRealS3CompletedBlobRetention",
    "BlobMaintenanceS3Tests.testRealS3ExpiredUploadDeleteRecoveryAndStaleVersion",
    "BlobUploadS3Tests.testRealSQLiteSharedBlobS3FinalUnbindRetainsUntilDeadline",
)


def command(args, *, cwd=None, **kwargs):
    return subprocess.run(args, cwd=cwd, check=True, **kwargs)


def git(path, *args):
    return command(["git", *args], cwd=path, capture_output=True, text=True).stdout.strip()


def check_output(raw, access, secret):
    output = raw.replace(access, "[redacted]").replace(secret, "[redacted]")
    if re.search(r"X-Amz-|https?://[^\s]+[?&]|AKIA[0-9A-Z]{16}|"
                 r"Authorization\s*:|f4/(?:typescript|go|python|dotnet|swift)/",
                 output, re.I):
        raise RuntimeError("sensitive native output detected; log discarded")
    return output


def verify_tests(output):
    if ("Test Suite 'All tests' passed" not in output or
            "Executed 17 tests, with 0 failures" not in output or
            "Test skipped" in output):
        raise RuntimeError("standalone S3 package must pass all 17 tests without skips")
    for receipt in RECEIPTS:
        if f"Test Case '{receipt}' passed" not in output:
            raise RuntimeError("missing native S3 receipt: " + receipt)
    for item in FORMATS:
        for receipt in (f"PASS Swift {item} native module outer owner rollback",
                        f"PASS Swift {item} S3 upload/confirm/graph bind/authorized view/unbind/retention GC"):
            if receipt not in output:
                raise RuntimeError("missing native S3 receipt: " + receipt)


def clear_bucket(client, bucket):
    versions = client.list_object_versions(Bucket=bucket)
    objects = [{"Key": item["Key"], "VersionId": item["VersionId"]}
               for field in ("Versions", "DeleteMarkers")
               for item in versions.get(field, [])]
    if objects:
        client.delete_objects(Bucket=bucket, Delete={"Objects": objects})
    current = client.list_objects_v2(Bucket=bucket).get("Contents", [])
    if current:
        client.delete_objects(Bucket=bucket, Delete={"Objects":
            [{"Key": item["Key"]} for item in current]})
    client.delete_bucket(Bucket=bucket)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-mirror", type=Path,
                        help="Private exact-commit local mirror for an unpushed runtime")
    parser.add_argument("--log", type=Path,
                        help="Existing empty output path for sanitized native test output")
    args = parser.parse_args()
    if args.log and (args.log.exists() or not args.log.parent.is_dir()):
        raise RuntimeError("native log path must be new under an existing directory")
    source_head = git(PACKAGE, "rev-parse", "HEAD")
    if git(PACKAGE, "status", "--porcelain"):
        raise RuntimeError("standalone S3 package source must be clean")
    manifest = (PACKAGE / "Package.swift").read_text()
    match = re.search(r'url: "https://github.com/teaql/teaql-swift.git", revision: "([0-9a-f]{40})"',
                      manifest)
    if not match:
        raise RuntimeError("standalone S3 manifest must pin an exact root commit")
    root_head = match.group(1)
    if args.runtime_mirror:
        mirror = args.runtime_mirror.resolve()
        if git(mirror, "rev-parse", "HEAD") != root_head or git(mirror, "status", "--porcelain"):
            raise RuntimeError("private root mirror must be clean at the pinned commit")

    name = "teaql-s3-ci-" + secrets.token_hex(5)
    volume, bucket = name + "-data", name + "-bucket"
    access, secret = "AKIA" + secrets.token_hex(8).upper(), secrets.token_urlsafe(40)
    container_started = False
    client = None
    with tempfile.TemporaryDirectory(prefix="teaql-s3-ci-") as private:
        scratch = Path(private)
        candidate = scratch / "package"
        command(["git", "clone", "--no-local", "--quiet", str(PACKAGE), str(candidate)])
        if git(candidate, "rev-parse", "HEAD") != source_head:
            raise RuntimeError("disposable S3 clone changed source commit")
        if args.runtime_mirror:
            command(["swift", "package", "--package-path", str(candidate), "config",
                     "set-mirror", "--original", ROOT_URL, "--mirror", mirror.as_uri()],
                    cwd=candidate, capture_output=True)
        envfile = scratch / "rustfs.env"
        envfile.write_text(f"RUSTFS_ACCESS_KEY={access}\nRUSTFS_SECRET_KEY={secret}\nRUSTFS_VOLUMES=/data\n")
        envfile.chmod(0o600)
        try:
            command(["docker", "volume", "create", volume], stdout=subprocess.DEVNULL)
            command(["docker", "run", "-d", "--name", name,
                     "-p", "127.0.0.1::9000", "-v", volume + ":/data",
                     "--env-file", str(envfile), IMAGE], stdout=subprocess.DEVNULL)
            container_started = True
            mapped = command(["docker", "port", name, "9000/tcp"], capture_output=True,
                             text=True).stdout.strip()
            host, port = mapped.rsplit(":", 1)
            for _ in range(100):
                try:
                    with socket.create_connection((host, int(port)), timeout=0.3):
                        break
                except OSError:
                    time.sleep(0.2)
            else:
                raise RuntimeError("disposable RustFS did not listen")
            endpoint = "http://" + mapped
            client = boto3.client("s3", endpoint_url=endpoint, region_name="us-east-1",
                                  aws_access_key_id=access, aws_secret_access_key=secret,
                                  config=Config(s3={"addressing_style": "path"}))
            client.create_bucket(Bucket=bucket)
            env = os.environ.copy()
            env.update({"TEAQL_S3_TEST_ENDPOINT": endpoint, "TEAQL_S3_TEST_BUCKET": bucket,
                        "TEAQL_S3_TEST_ACCESS_KEY": access,
                        "TEAQL_S3_TEST_SECRET_KEY": secret,
                        "TEAQL_S3_TEST_CREATE_ONLY": "1",
                        "TEAQL_S3_TEST_CONDITIONAL_DELETE": "1",
                        "TEAQL_S3_TEST_BLOB_MAINTENANCE": "1",
                        "TEAQL_S3_TEST_BLOB_UPLOAD": "1",
                        "TEAQL_S3_TEST_END_TO_END_GC": "1",
                        "TEAQL_S3_TEST_SHARED_BLOB": "1",
                        "TEAQL_S3_TEST_REAL_IMAGE": "1",
                        "TEAQL_S3_TEST_REAL_PDF": "1",
                        "TEAQL_S3_TEST_REAL_MEDIA": "1",
                        "TEAQL_S3_TEST_REAL_OFFICE": "1",
                        "TEAQL_S3_TEST_REAL_LEGACY_OFFICE": "1"})
            result = subprocess.run(["swift", "test", "--skip-update", "--jobs", "2",
                                     "--scratch-path", str(scratch / "build")],
                                    cwd=candidate, env=env, capture_output=True, text=True,
                                    timeout=1800)
            output = check_output(result.stdout + result.stderr, access, secret)
            if args.log:
                args.log.write_text(output)
            if result.returncode:
                raise RuntimeError("standalone S3 suite failed; see sanitized native log")
            verify_tests(output)
            resolved = candidate / "Package.resolved"
            pins = json.loads(resolved.read_text())["pins"] if resolved.is_file() else []
            runtime = [pin for pin in pins if pin.get("identity") == "teaql-swift"]
            if len(runtime) != 1 or runtime[0].get("state", {}).get("revision") != root_head:
                raise RuntimeError("standalone S3 resolution did not pin the exact root commit")
            print("PASS independent Swift S3 full same-host real-storage suite: 17/17, zero skips")
        finally:
            try:
                if client is not None:
                    try:
                        clear_bucket(client, bucket)
                    finally:
                        client.close()
            finally:
                if container_started:
                    subprocess.run(["docker", "rm", "-f", name], stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL)
                subprocess.run(["docker", "volume", "rm", volume], stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
