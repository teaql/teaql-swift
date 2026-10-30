#!/usr/bin/env python3
"""Local guards for consuming only exact standalone S3 archive bytes."""

import importlib.util
from pathlib import Path
import tempfile
import unittest
import warnings
import zipfile


SCRIPT = Path(__file__).with_name("verify-s3-candidate-consumer.py")
SPEC = importlib.util.spec_from_file_location("s3_archive_consumer", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
REVISION = "a" * 40
PREFIX = "teaql-objectstorage-s3/"
PROVIDER = "Sources/TeaQLObjectStorageS3/S3ObjectStorage.swift"


def manifest(revision=REVISION):
    return ('.package(name: "TeaQLRuntime", url: "'
            + MODULE.RUNTIME_URL + '", revision: "' + revision + '")')


class ExactArchiveConsumerTests(unittest.TestCase):
    def archive(self, work, entries):
        path = work / "candidate.zip"
        with zipfile.ZipFile(path, "w") as writer:
            for name, content in entries:
                writer.writestr(PREFIX + name, content)
        return path

    def test_extracts_exact_manifest_and_provider(self):
        with tempfile.TemporaryDirectory(prefix="teaql-s3-consumer-test-") as temporary:
            work = Path(temporary)
            archive = self.archive(work, [("Package.swift", manifest()),
                                          (PROVIDER, "public struct S3ObjectStorage {}")])
            target = work / "extracted"
            target.mkdir()
            files = MODULE.extract_exact_archive(archive, target, REVISION)
            self.assertEqual(files, {"Package.swift", PROVIDER})
            self.assertEqual((target / "Package.swift").read_text(), manifest())

    def test_rejects_parent_escape(self):
        with tempfile.TemporaryDirectory(prefix="teaql-s3-consumer-test-") as temporary:
            work = Path(temporary)
            archive = self.archive(work, [("../outside", "bad")])
            target = work / "extracted"
            target.mkdir()
            with self.assertRaisesRegex(RuntimeError, "unsafe S3 archive entry"):
                MODULE.extract_exact_archive(archive, target, REVISION)
            self.assertFalse((work / "outside").exists())

    def test_rejects_different_root_revision(self):
        with tempfile.TemporaryDirectory(prefix="teaql-s3-consumer-test-") as temporary:
            work = Path(temporary)
            archive = self.archive(work, [("Package.swift", manifest("b" * 40)),
                                          (PROVIDER, "source")])
            target = work / "extracted"
            target.mkdir()
            with self.assertRaisesRegex(RuntimeError, "exact remote runtime revision"):
                MODULE.extract_exact_archive(archive, target, REVISION)

    def test_rejects_duplicate_entry(self):
        with tempfile.TemporaryDirectory(prefix="teaql-s3-consumer-test-") as temporary:
            work = Path(temporary)
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                archive = self.archive(work, [("Package.swift", manifest()),
                                              ("Package.swift", manifest()),
                                              (PROVIDER, "source")])
            target = work / "extracted"
            target.mkdir()
            with self.assertRaisesRegex(RuntimeError, "duplicate S3 source archive entry"):
                MODULE.extract_exact_archive(archive, target, REVISION)


if __name__ == "__main__":
    unittest.main(verbosity=2)
