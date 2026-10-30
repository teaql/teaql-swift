#!/usr/bin/env python3
"""Require a pushed SwiftPM version tag to be signed and verified by GitHub."""

import json
import os
import re
import sys
from urllib.parse import quote
from urllib.request import Request, urlopen


def sha(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}", value) is not None


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


def verify(repository, tag, commit, get_json):
    if repository != "teaql/teaql-swift":
        raise ValueError("unexpected GitHub repository")
    if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?", tag or "") is None:
        raise ValueError("invalid SwiftPM release version tag")
    if not sha(commit):
        raise ValueError("invalid release commit SHA")
    base = "https://api.github.com/repos/" + repository
    reference = get_json(base + "/git/ref/tags/" + quote(tag, safe=""))
    if reference.get("ref") != "refs/tags/" + tag:
        raise ValueError("GitHub returned a different tag reference")
    target = reference.get("object") or {}
    if target.get("type") != "tag" or not sha(target.get("sha")):
        raise ValueError("release tag is not an annotated tag object")
    tag_object = get_json(base + "/git/tags/" + target["sha"])
    if tag_object.get("sha") != target["sha"] or tag_object.get("tag") != tag:
        raise ValueError("annotated tag object does not match its reference")
    tagged_commit = tag_object.get("object") or {}
    if tagged_commit.get("type") != "commit" or tagged_commit.get("sha") != commit:
        raise ValueError("signed tag does not point to the release commit")
    verification = tag_object.get("verification") or {}
    if verification.get("verified") is not True or not verification.get("signature"):
        raise ValueError("GitHub has not verified a signature on the release tag")
    return target["sha"]


def main():
    try:
        repository = os.environ["GITHUB_REPOSITORY"]
        tag = os.environ["GITHUB_REF_NAME"]
        commit = os.environ["GITHUB_SHA"]
        token = os.environ["GITHUB_TOKEN"]
        if not token:
            raise ValueError("missing GitHub token")
        tag_sha = verify(repository, tag, commit, lambda url: fetch_json(url, token))
    except (KeyError, ValueError, OSError) as error:
        print("Swift release tag verification failed: " + str(error), file=sys.stderr)
        return 1
    print("PASS verified signed Swift release tag " + tag + " at " + commit
          + " (" + tag_sha + ")")
    return 0


if __name__ == "__main__":
    sys.exit(main())
