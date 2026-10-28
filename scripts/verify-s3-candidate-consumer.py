#!/usr/bin/env python3
"""Build a disposable, separate Git candidate for the optional S3 provider.

The root runtime and S3 source are taken from one clean HEAD. The candidate
manifest replaces the source-checkout-only path dependency with an exact Git
revision dependency on that runtime. Nothing is tagged, pushed, or published.
"""

from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
S3 = ROOT / "ObjectStorageS3"
SWIFT = os.environ.get("TEAQL_SWIFT_BIN", "swift")


def run(args, *, cwd=ROOT, timeout=1200, env=None):
    result = subprocess.run(
        args, cwd=cwd, text=True, capture_output=True, timeout=timeout, env=env
    )
    if result.returncode:
        raise RuntimeError(
            " ".join(map(str, args)) + " failed:\n" + (result.stdout + result.stderr)[-6000:]
        )
    return result.stdout + result.stderr


def check_clean():
    changed = run(
        ["git", "status", "--porcelain", "--", "Package.swift", "Sources",
         "ObjectStorageS3/Package.swift", "ObjectStorageS3/Sources"]
    )
    if changed.strip():
        raise RuntimeError("root or S3 package source differs from pinned HEAD")


def make_candidate(work, root_revision):
    candidate = work / "teaql-objectstorage-s3"
    candidate.mkdir()
    manifest = (S3 / "Package.swift").read_text()
    old = '.package(name: "TeaQLRuntime", path: "..")'
    new = ('.package(name: "TeaQLRuntime", url: "' + ROOT.as_uri()
           + '", revision: "' + root_revision + '")')
    if manifest.count(old) != 1:
        raise RuntimeError("unexpected S3 runtime dependency declaration")
    (candidate / "Package.swift").write_text(manifest.replace(old, new))
    shutil.copytree(S3 / "Sources", candidate / "Sources")
    run(["git", "init", "-q", "-b", "main"], cwd=candidate)
    run(["git", "add", "Package.swift", "Sources"], cwd=candidate)
    fixed = dict(os.environ, GIT_AUTHOR_DATE="2026-01-01T00:00:00Z",
                 GIT_COMMITTER_DATE="2026-01-01T00:00:00Z")
    run(["git", "-c", "user.name=TeaQL Candidate",
         "-c", "user.email=candidate@teaql.invalid",
         "commit", "-q", "-m", "Snapshot optional S3 provider"], cwd=candidate, env=fixed)
    revision = run(["git", "rev-parse", "HEAD"], cwd=candidate).strip()
    return candidate, revision


def make_app(work, candidate, revision, root_revision):
    app = work / "consumer"
    (app / "Sources" / "Probe").mkdir(parents=True)
    (app / "Package.swift").write_text(
        "// swift-tools-version: 6.0\nimport PackageDescription\n"
        "let package = Package(\n  name: \"TeaQLS3CandidateProbe\",\n"
        "  dependencies: [\n    .package(url: \"" + candidate.as_uri()
        + "\", revision: \"" + revision + "\"),\n"
        "    .package(url: \"" + ROOT.as_uri()
        + "\", revision: \"" + root_revision + "\")\n  ],\n"
        "  targets: [.executableTarget(name: \"Probe\", dependencies: [\n"
        "    .product(name: \"TeaQLObjectStorageS3\", package: \"teaql-objectstorage-s3\"),\n"
        "    .product(name: \"TeaQLCore\", package: \"teaql-swift\")\n"
        "  ])],\n  swiftLanguageModes: [.v6]\n)\n"
    )
    (app / "Sources" / "Probe" / "main.swift").write_text(
        "import TeaQLCore\nimport TeaQLObjectStorageS3\n"
        "let _ = S3ObjectStorage.self\n"
        'print("PASS Swift S3 candidate consumer")\n'
    )
    return app


def check_lock(app, candidate, s3_revision, root_revision):
    lock = app / "Package.resolved"
    pins = json.loads(lock.read_text())["pins"]
    expected = {
        "teaql-objectstorage-s3": (candidate, s3_revision),
        "teaql-swift": (ROOT, root_revision),
    }
    for identity, (path, revision) in expected.items():
        matches = [pin for pin in pins if pin.get("identity") == identity]
        if len(matches) != 1:
            raise RuntimeError(identity + " not locked exactly once")
        pin = matches[0]
        if (pin.get("kind") != "localSourceControl"
            or Path(pin.get("location", "")).resolve() != path.resolve()
            or pin.get("state", {}).get("revision") != revision):
            raise RuntimeError(identity + " not locked to candidate Git revision: "
                               + json.dumps(matches, sort_keys=True))
    return hashlib.sha256(lock.read_bytes()).hexdigest()


def main():
    check_clean()
    root_revision = run(["git", "rev-parse", "HEAD"]).strip()
    with tempfile.TemporaryDirectory(prefix="teaql-swift-s3-candidate-") as temporary:
        work = Path(temporary)
        candidate, s3_revision = make_candidate(work, root_revision)
        app = make_app(work, candidate, s3_revision, root_revision)
        output = run(
            [SWIFT, "run", "--package-path", str(app),
             "--scratch-path", str(work / "scratch"), "--jobs", "2", "Probe"],
            cwd=app,
        )
        if "PASS Swift S3 candidate consumer" not in output:
            raise RuntimeError("S3 candidate executable did not run")
        digest = check_lock(app, candidate, s3_revision, root_revision)
        print("PASS Swift separate S3 Git candidate root_revision="
              + root_revision + " s3_revision=" + s3_revision
              + " lock_sha256=" + digest, flush=True)


if __name__ == "__main__":
    main()
