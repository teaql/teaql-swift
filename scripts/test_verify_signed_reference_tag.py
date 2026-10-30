#!/usr/bin/env python3
"""Local API fixtures for the SwiftPM signed-tag CI gate."""

import importlib.util
from pathlib import Path
import unittest


SOURCE = Path(__file__).with_name("verify-signed-reference-tag.py")
SPEC = importlib.util.spec_from_file_location("swift_signed_reference_tag", SOURCE)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
COMMIT = "a" * 40
TAG_SHA = "b" * 40
BASE = "https://api.github.com/repos/teaql/teaql-swift"


def fixtures(tag="0.3.2"):
    return {
        BASE + "/git/ref/tags/" + tag: {
            "ref": "refs/tags/" + tag, "object": {"type": "tag", "sha": TAG_SHA}},
        BASE + "/git/tags/" + TAG_SHA: {
            "sha": TAG_SHA, "tag": tag,
            "object": {"type": "commit", "sha": COMMIT},
            "verification": {"verified": True, "signature": "signed"}},
    }


class SignedTagTests(unittest.TestCase):
    def check(self, values, tag="0.3.2"):
        return MODULE.verify("teaql/teaql-swift", tag, COMMIT,
                             lambda url: values[url])

    def test_signed_annotated_exact_commit(self):
        self.assertEqual(self.check(fixtures()), TAG_SHA)

    def test_signed_prerelease(self):
        self.assertEqual(self.check(fixtures("0.3.2-rc.1"), "0.3.2-rc.1"), TAG_SHA)

    def test_lightweight_tag_rejected(self):
        data = fixtures()
        data[BASE + "/git/ref/tags/0.3.2"]["object"] = {
            "type": "commit", "sha": COMMIT}
        with self.assertRaisesRegex(ValueError, "annotated"):
            self.check(data)

    def test_wrong_commit_rejected(self):
        data = fixtures()
        data[BASE + "/git/tags/" + TAG_SHA]["object"]["sha"] = "c" * 40
        with self.assertRaisesRegex(ValueError, "release commit"):
            self.check(data)

    def test_unverified_signature_rejected(self):
        data = fixtures()
        data[BASE + "/git/tags/" + TAG_SHA]["verification"]["verified"] = False
        with self.assertRaisesRegex(ValueError, "verified"):
            self.check(data)

    def test_different_tag_ref_rejected(self):
        data = fixtures()
        data[BASE + "/git/ref/tags/0.3.2"]["ref"] = "refs/tags/0.3.1"
        with self.assertRaisesRegex(ValueError, "different tag reference"):
            self.check(data)

    def test_invalid_tag_rejected_before_fetch(self):
        with self.assertRaisesRegex(ValueError, "invalid SwiftPM"):
            MODULE.verify("teaql/teaql-swift", "v0.3.2", COMMIT,
                          lambda _: self.fail("must not fetch"))

    def test_wrong_repository_rejected_before_fetch(self):
        with self.assertRaisesRegex(ValueError, "unexpected GitHub repository"):
            MODULE.verify("other/teaql-swift", "0.3.2", COMMIT,
                          lambda _: self.fail("must not fetch"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
