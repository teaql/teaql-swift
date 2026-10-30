#!/usr/bin/env python3
"""Compare a committed independent S3 package with one exact root Git revision.

This is a read-only source handoff check. It does not create a repository, tag,
remote, release, or registry package, and it does not replace SwiftPM's native
build and consumer checks.
"""

import argparse
from io import BytesIO
import hashlib
import importlib.util
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[1]
BUILDER_PATH = ROOT / "scripts/build-s3-source-archive.py"
SPEC = importlib.util.spec_from_file_location("teaql_s3_source_archive", BUILDER_PATH)
BUILDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)


def git(args, cwd):
    result = subprocess.run(["git", *args], cwd=cwd, capture_output=True, timeout=120)
    if result.returncode:
        raise RuntimeError("git " + " ".join(args) + " failed: "
                           + result.stderr.decode(errors="replace")[-1000:])
    return result.stdout


def committed_tree(repo, revision):
    if re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        raise RuntimeError("invalid source commit")
    raw = git(["archive", "--format=tar", revision], repo)
    files = {}
    with tarfile.open(fileobj=BytesIO(raw), mode="r:") as archive:
        for member in archive:
            path = Path(member.name)
            if path.is_absolute() or ".." in path.parts or member.issym() or member.islnk():
                raise RuntimeError("unsafe committed package path: " + member.name)
            if member.isdir():
                continue
            if not member.isfile():
                raise RuntimeError("unsupported committed package path: " + member.name)
            files[path.as_posix()] = archive.extractfile(member).read()
    return files


def expected_s3_files(root_revision):
    if re.fullmatch(r"[0-9a-f]{40}", root_revision) is None:
        raise RuntimeError("invalid root Git revision")
    with tempfile.TemporaryDirectory(prefix="teaql-swift-s3-parity-") as temporary:
        package = Path(temporary)
        copied = BUILDER.export_committed_s3(package, root_revision)
        BUILDER.add_root_license(package, root_revision, copied)
        BUILDER.rewrite_manifest(package, root_revision)
        return {path.relative_to(package).as_posix(): path.read_bytes()
                for path in package.rglob("*") if path.is_file()}


def compare(expected, actual):
    if expected.keys() != actual.keys():
        raise RuntimeError("independent S3 Git file set differs: missing="
                           + repr(sorted(expected.keys() - actual.keys()))
                           + " extra=" + repr(sorted(actual.keys() - expected.keys())))
    for name in sorted(expected):
        if actual[name] != expected[name]:
            raise RuntimeError("independent S3 Git bytes differ: " + name)
    digest = hashlib.sha256()
    for name in sorted(expected):
        content = expected[name]
        digest.update(len(name.encode()).to_bytes(4, "big"))
        digest.update(name.encode())
        digest.update(len(content).to_bytes(8, "big"))
        digest.update(content)
    return digest.hexdigest(), len(expected)


def verify(repo, root_revision):
    repo = Path(repo).resolve()
    if not (repo / ".git").exists():
        raise RuntimeError("independent S3 candidate must be a local Git repository")
    if git(["status", "--porcelain"], repo):
        raise RuntimeError("independent S3 repository has uncommitted changes")
    candidate_revision = git(["rev-parse", "HEAD"], repo).decode().strip()
    return root_revision, candidate_revision, *compare(
        expected_s3_files(root_revision), committed_tree(repo, candidate_revision))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="local independent S3 Git checkout")
    parser.add_argument("--root-revision", required=True,
                        help="exact reviewed root commit pinned by the S3 package")
    args = parser.parse_args(argv)
    try:
        root, s3, digest, count = verify(args.repo, args.root_revision)
    except (OSError, RuntimeError, subprocess.TimeoutExpired, tarfile.TarError) as error:
        print("Swift S3 independent repository check failed: " + str(error), file=sys.stderr)
        return 1
    print("PASS Swift S3 independent repository root_revision=" + root
          + " s3_revision=" + s3 + " files=" + str(count)
          + " source_sha256=" + digest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
