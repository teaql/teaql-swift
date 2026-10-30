#!/usr/bin/env python3
"""Check signed, matching SwiftPM release tags for the independent S3 package."""

import json
import os
from pathlib import Path
import re
import sys
from urllib.parse import quote
from urllib.request import Request, urlopen


RUNTIME_REPOSITORY = "teaql/teaql-swift"
S3_REPOSITORY = "teaql/teaql-objectstorage-s3"
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?")
SHA = re.compile(r"[0-9a-f]{40}")
RUNTIME_EDGE = re.compile(
    r'\.package\(name: "TeaQLRuntime", url: "https://github.com/teaql/teaql-swift\.git", '
    r'revision: "([0-9a-f]{40})"\)')


def pinned_runtime_revision(manifest):
    matches = RUNTIME_EDGE.findall(manifest)
    if len(matches) != 1 or 'path: ".."' in manifest:
        raise ValueError("S3 manifest must pin one exact remote Swift runtime revision")
    return matches[0]


def fetch_json(url, token):
    request = Request(url, headers={
        "Accept": "application/vnd.github+json",
        "Authorization": "Bearer " + token,
        "X-GitHub-Api-Version": "2022-11-28",
    })
    with urlopen(request, timeout=20) as response:
        if response.status != 200:
            raise ValueError("GitHub tag API did not return HTTP 200")
        return json.load(response)


def signed_tag_commit(repository, version, get_json):
    base = "https://api.github.com/repos/" + repository
    reference = get_json(base + "/git/ref/tags/" + quote(version, safe=""))
    if reference.get("ref") != "refs/tags/" + version:
        raise ValueError(repository + " returned a different tag reference")
    target = reference.get("object") or {}
    if target.get("type") != "tag" or not SHA.fullmatch(target.get("sha") or ""):
        raise ValueError(repository + " release tag is not an annotated tag object")
    tag_object = get_json(base + "/git/tags/" + target["sha"])
    if tag_object.get("sha") != target["sha"] or tag_object.get("tag") != version:
        raise ValueError(repository + " annotated tag object differs from its reference")
    commit = tag_object.get("object") or {}
    if commit.get("type") != "commit" or not SHA.fullmatch(commit.get("sha") or ""):
        raise ValueError(repository + " release tag does not point to a commit")
    verification = tag_object.get("verification") or {}
    if verification.get("verified") is not True or not verification.get("signature"):
        raise ValueError(repository + " release tag signature is not verified")
    return commit["sha"]


def verify(repository, version, s3_commit, manifest, get_json):
    if repository != S3_REPOSITORY:
        raise ValueError("unexpected S3 release repository")
    if VERSION.fullmatch(version or "") is None:
        raise ValueError("invalid SwiftPM release version tag")
    if SHA.fullmatch(s3_commit or "") is None:
        raise ValueError("invalid S3 release commit SHA")
    runtime_commit = pinned_runtime_revision(manifest)
    if signed_tag_commit(repository, version, get_json) != s3_commit:
        raise ValueError("signed S3 tag does not point to this release commit")
    if signed_tag_commit(RUNTIME_REPOSITORY, version, get_json) != runtime_commit:
        raise ValueError("signed Swift runtime tag differs from pinned revision")
    return runtime_commit


def main():
    try:
        token = os.environ["GITHUB_TOKEN"]
        if not token:
            raise ValueError("missing GitHub token")
        version = os.environ["GITHUB_REF_NAME"]
        s3_commit = os.environ["GITHUB_SHA"]
        repository = os.environ["GITHUB_REPOSITORY"]
        manifest = Path(__file__).resolve().parents[1].joinpath("Package.swift").read_text()
        runtime_commit = verify(repository, version, s3_commit, manifest,
                                lambda url: fetch_json(url, token))
    except (KeyError, OSError, ValueError) as error:
        print("Swift S3 release verification failed: " + str(error), file=sys.stderr)
        return 1
    print("PASS signed matching Swift S3 and runtime tags " + version
          + " s3=" + s3_commit + " runtime=" + runtime_commit)
    return 0


if __name__ == "__main__":
    sys.exit(main())
