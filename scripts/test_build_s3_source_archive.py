#!/usr/bin/env python3
"""Reject unsafe S3 release archives and prove timestamp normalization."""

import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile


SCRIPT = Path(__file__).with_name("build-s3-source-archive.py")
SPEC = importlib.util.spec_from_file_location("s3_source_archive", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class S3SourceArchiveTests(unittest.TestCase):
    def test_existing_output_is_never_overwritten(self):
        with tempfile.TemporaryDirectory(prefix="teaql-s3-archive-test-") as temporary:
            output = Path(temporary) / "candidate.zip"
            output.write_bytes(b"existing")
            with patch.object(MODULE, "exact_revision", side_effect=AssertionError("must not run")):
                with self.assertRaisesRegex(RuntimeError, "refusing to overwrite"):
                    MODULE.build(output)
            self.assertEqual(output.read_bytes(), b"existing")

    def test_manifest_requires_the_unique_development_edge(self):
        with tempfile.TemporaryDirectory(prefix="teaql-s3-archive-test-") as temporary:
            package = Path(temporary)
            manifest = package / "Package.swift"
            manifest.write_text("let package = Package()\n")
            with self.assertRaisesRegex(RuntimeError, "exactly one"):
                MODULE.rewrite_manifest(package, "a" * 40)

    def test_zip_rejects_extra_source(self):
        with tempfile.TemporaryDirectory(prefix="teaql-s3-archive-test-") as temporary:
            archive = Path(temporary) / "candidate.zip"
            with zipfile.ZipFile(archive, "w") as writer:
                writer.writestr("teaql-objectstorage-s3/Package.swift", "manifest")
                writer.writestr("teaql-objectstorage-s3/unreviewed.txt", "extra")
            digest = hashlib.sha256(b"manifest").hexdigest()
            with self.assertRaisesRegex(RuntimeError, "extra=.*unreviewed"):
                MODULE.verify_zip(archive, {"Package.swift": digest}, digest,
                                  "teaql-objectstorage-s3")

    def test_two_timestamp_variants_normalize_to_identical_bytes(self):
        with tempfile.TemporaryDirectory(prefix="teaql-s3-archive-test-") as temporary:
            hashes = []
            for name, date in (("first", (2025, 1, 1, 0, 0, 0)),
                               ("second", (2026, 10, 30, 0, 0, 0))):
                archive = Path(temporary) / (name + ".zip")
                with zipfile.ZipFile(archive, "w") as writer:
                    info = zipfile.ZipInfo("teaql-objectstorage-s3/Package.swift", date)
                    info.compress_type = zipfile.ZIP_DEFLATED
                    writer.writestr(info, "manifest")
                MODULE.normalize_zip(archive, temporary)
                hashes.append(hashlib.sha256(archive.read_bytes()).hexdigest())
            self.assertEqual(hashes[0], hashes[1])


if __name__ == "__main__":
    unittest.main(verbosity=2)
