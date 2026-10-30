#!/usr/bin/env python3
"""API fixtures for the independent Swift S3 release identity gate."""

import importlib.util
from pathlib import Path
import unittest


SOURCE = Path(__file__).with_name("verify-signed-release.py")
SPEC = importlib.util.spec_from_file_location("swift_s3_signed_release", SOURCE)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
S3_COMMIT = "a" * 40
ROOT_COMMIT = "b" * 40
S3_TAG = "c" * 40
ROOT_TAG = "d" * 40
VERSION = "0.3.2"
MANIFEST = ('.package(name: "TeaQLRuntime", url: '
            '"https://github.com/teaql/teaql-swift.git", revision: "'
            + ROOT_COMMIT + '")')


def fixtures():
    result = {}
    for repository, tag_sha, commit in (
        (MODULE.S3_REPOSITORY, S3_TAG, S3_COMMIT),
        (MODULE.RUNTIME_REPOSITORY, ROOT_TAG, ROOT_COMMIT),
    ):
        base = "https://api.github.com/repos/" + repository
        result[base + "/git/ref/tags/" + VERSION] = {
            "ref": "refs/tags/" + VERSION,
            "object": {"type": "tag", "sha": tag_sha}}
        result[base + "/git/tags/" + tag_sha] = {
            "sha": tag_sha, "tag": VERSION,
            "object": {"type": "commit", "sha": commit},
            "verification": {"verified": True, "signature": "signed"}}
    return result


class SignedReleaseTests(unittest.TestCase):
    def check(self, data=None, **kwargs):
        values = dict(repository=MODULE.S3_REPOSITORY, version=VERSION,
                      s3_commit=S3_COMMIT, manifest=MANIFEST)
        values.update(kwargs)
        data = fixtures() if data is None else data
        return MODULE.verify(**values, get_json=lambda url: data[url])

    def test_matching_signed_tags_and_manifest(self):
        self.assertEqual(self.check(), ROOT_COMMIT)

    def test_s3_lightweight_tag_rejected(self):
        data = fixtures()
        data["https://api.github.com/repos/" + MODULE.S3_REPOSITORY
             + "/git/ref/tags/" + VERSION]["object"]["type"] = "commit"
        with self.assertRaisesRegex(ValueError, "annotated"):
            self.check(data)

    def test_runtime_unverified_signature_rejected(self):
        data = fixtures()
        data["https://api.github.com/repos/" + MODULE.RUNTIME_REPOSITORY
             + "/git/tags/" + ROOT_TAG]["verification"]["verified"] = False
        with self.assertRaisesRegex(ValueError, "signature"):
            self.check(data)

    def test_runtime_version_points_to_other_commit(self):
        data = fixtures()
        data["https://api.github.com/repos/" + MODULE.RUNTIME_REPOSITORY
             + "/git/tags/" + ROOT_TAG]["object"]["sha"] = "e" * 40
        with self.assertRaisesRegex(ValueError, "pinned revision"):
            self.check(data)

    def test_s3_version_points_to_other_commit(self):
        data = fixtures()
        data["https://api.github.com/repos/" + MODULE.S3_REPOSITORY
             + "/git/tags/" + S3_TAG]["object"]["sha"] = "e" * 40
        with self.assertRaisesRegex(ValueError, "this release commit"):
            self.check(data)

    def test_local_path_or_wrong_repository_rejected_before_fetch(self):
        with self.assertRaisesRegex(ValueError, "pin one exact"):
            self.check(manifest=MANIFEST + '\n.package(name: "TeaQLRuntime", path: "..")')
        with self.assertRaisesRegex(ValueError, "unexpected S3"):
            self.check(repository="other/teaql-objectstorage-s3")

    def test_missing_or_mismatched_tag_rejected(self):
        data = fixtures()
        data["https://api.github.com/repos/" + MODULE.RUNTIME_REPOSITORY
             + "/git/ref/tags/" + VERSION]["ref"] = "refs/tags/0.3.1"
        with self.assertRaisesRegex(ValueError, "different tag"):
            self.check(data)
        with self.assertRaisesRegex(ValueError, "invalid SwiftPM"):
            self.check(version="v0.3.2")


if __name__ == "__main__":
    unittest.main(verbosity=2)
