#!/usr/bin/env python3
"""Source-parity failures for a separately committed Swift S3 Git package."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).with_name("verify-independent-s3-repository.py")
SPEC = importlib.util.spec_from_file_location("teaql_s3_repository_parity", SOURCE)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class IndependentRepositoryTests(unittest.TestCase):
    def test_exact_files_pass(self):
        digest, count = MODULE.compare({"Package.swift": b"manifest", "LICENSE": b"license"},
                                       {"LICENSE": b"license", "Package.swift": b"manifest"})
        self.assertEqual(len(digest), 64)
        self.assertEqual(count, 2)

    def test_missing_extra_and_mutated_file_fail(self):
        expected = {"Package.swift": b"manifest", "LICENSE": b"license"}
        for actual, message in (({"Package.swift": b"manifest"}, "missing=.*LICENSE"),
                                (dict(expected, **{"unexpected.swift": b"extra"}), "extra=.*unexpected"),
                                ({"Package.swift": b"changed", "LICENSE": b"license"}, "bytes differ: Package.swift")):
            with self.subTest(actual=actual):
                with self.assertRaisesRegex(RuntimeError, message):
                    MODULE.compare(expected, actual)

    def test_export_uses_one_git_revision_for_manifest_and_license(self):
        revision = subprocess.check_output(["git", "rev-parse", "HEAD"],
                                           cwd=MODULE.ROOT, text=True).strip()
        files = MODULE.expected_s3_files(revision)
        self.assertEqual(files["LICENSE"], subprocess.check_output(
            ["git", "show", revision + ":LICENSE"], cwd=MODULE.ROOT))
        self.assertIn(revision.encode(), files["Package.swift"])
        self.assertNotIn(b'path: ".."', files["Package.swift"])
        self.assertNotIn("Package.resolved", files)

    def test_invalid_revision_and_non_repository_fail(self):
        with self.assertRaisesRegex(RuntimeError, "invalid root"):
            MODULE.expected_s3_files("not-a-revision")
        with tempfile.TemporaryDirectory(prefix="teaql-s3-parity-test-") as directory:
            with self.assertRaisesRegex(RuntimeError, "local Git repository"):
                MODULE.verify(directory, "a" * 40)

    def test_uncommitted_package_is_rejected_before_source_comparison(self):
        with tempfile.TemporaryDirectory(prefix="teaql-s3-parity-test-") as directory:
            subprocess.run(["git", "init", "-q", directory], check=True)
            (Path(directory) / "untracked.txt").write_text("not in release commit")
            with self.assertRaisesRegex(RuntimeError, "uncommitted changes"):
                MODULE.verify(directory, "a" * 40)


if __name__ == "__main__":
    unittest.main(verbosity=2)
