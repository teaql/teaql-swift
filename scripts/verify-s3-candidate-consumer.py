#!/usr/bin/env python3
"""Compile a clean SwiftPM consumer of the exact standalone S3 source archive.

The released S3 manifest names the remote root Git revision. A local SwiftPM
mirror resolves that still-unpushed revision for this disposable qualification;
the archive and application manifests are never rewritten for the consumer.
"""

from pathlib import Path, PurePosixPath
import hashlib
import json
import os
import signal
import stat
import subprocess
import sys
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SWIFT = os.environ.get("TEAQL_SWIFT_BIN", "swift")
RUNTIME_URL = "https://github.com/teaql/teaql-swift.git"
S3_IDENTITY = "teaql-objectstorage-s3"


def run(args, *, cwd=ROOT, timeout=1200, env=None):
    process = subprocess.Popen(args, cwd=cwd, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, env=env,
                               start_new_session=True)
    try:
        output, _ = process.communicate(timeout=timeout)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
        raise
    if process.returncode:
        raise RuntimeError(" ".join(map(str, args)) + " failed:\n"
                           + output[-6000:])
    return output


def check_clean():
    if run(["git", "status", "--porcelain"]).strip():
        raise RuntimeError("S3 archive consumer requires a clean source commit")


def extract_exact_archive(archive, candidate, root_revision):
    prefix = S3_IDENTITY + "/"
    names = set()
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        if len(entries) != len({item.filename for item in entries}):
            raise RuntimeError("duplicate S3 source archive entry")
        for item in entries:
            name = item.filename
            relative = PurePosixPath(name[len(prefix):])
            if (not name.startswith(prefix) or relative.is_absolute()
                or ".." in relative.parts or stat.S_ISLNK(item.external_attr >> 16)):
                raise RuntimeError("unsafe S3 archive entry: " + name)
            if item.is_dir():
                continue
            if not relative.parts or relative.as_posix() in names:
                raise RuntimeError("duplicate S3 source path: " + name)
            target = candidate.joinpath(*relative.parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.read(item))
            names.add(relative.as_posix())
    manifest = (candidate / "Package.swift").read_text()
    expected = ('.package(name: "TeaQLRuntime", url: "' + RUNTIME_URL
                + '", revision: "' + root_revision + '")')
    if manifest.count(expected) != 1 or 'path: ".."' in manifest:
        raise RuntimeError("S3 archive does not pin the exact remote runtime revision")
    if "Sources/TeaQLObjectStorageS3/S3ObjectStorage.swift" not in names:
        raise RuntimeError("S3 provider source missing from archive")
    return names


def make_candidate(work, root_revision):
    archive = work / "s3-source.zip"
    output = run([sys.executable, str(ROOT / "scripts/build-s3-source-archive.py"),
                  "--output", str(archive)])
    if "root_revision=" + root_revision not in output:
        raise RuntimeError("S3 archive builder used a different root commit")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    candidate = work / S3_IDENTITY
    candidate.mkdir()
    files = extract_exact_archive(archive, candidate, root_revision)
    run(["git", "init", "-q", "-b", "main"], cwd=candidate)
    run(["git", "add", "-A"], cwd=candidate)
    fixed = dict(os.environ, GIT_AUTHOR_DATE="2026-01-01T00:00:00Z",
                 GIT_COMMITTER_DATE="2026-01-01T00:00:00Z")
    run(["git", "-c", "user.name=TeaQL Candidate",
         "-c", "user.email=candidate@teaql.invalid", "commit", "-q", "-m",
         "Exact S3 source archive candidate"], cwd=candidate, env=fixed)
    revision = run(["git", "rev-parse", "HEAD"], cwd=candidate).strip()
    tracked = set(run(["git", "ls-files"], cwd=candidate).splitlines())
    if tracked != files:
        raise RuntimeError("S3 Git candidate differs from source archive files")
    return candidate, revision, digest, files


def make_app(work, candidate, revision):
    app = work / "consumer"
    (app / "Sources" / "Probe").mkdir(parents=True)
    (app / "Package.swift").write_text(
        "// swift-tools-version: 6.0\nimport PackageDescription\n"
        "let package = Package(\n  name: \"TeaQLS3ArchiveProbe\",\n"
        "  dependencies: [.package(url: \"" + candidate.as_uri()
        + "\", revision: \"" + revision + "\")],\n"
        "  targets: [.executableTarget(name: \"Probe\", dependencies: [\n"
        "    .product(name: \"TeaQLObjectStorageS3\", package: \""
        + S3_IDENTITY + "\")\n  ])],\n  swiftLanguageModes: [.v6]\n)\n")
    (app / "Sources" / "Probe" / "main.swift").write_text(
        "import TeaQLObjectStorageS3\nlet _ = S3ObjectStorage.self\n"
        'print("PASS Swift exact archive S3 consumer")\n')
    return app


def check_origin(work, candidate, s3_revision, root_revision, files):
    app = work / "consumer"
    lock = app / "Package.resolved"
    pins = json.loads(lock.read_text())["pins"]
    for identity, revision in ((S3_IDENTITY, s3_revision),
                               ("teaql-swift", root_revision)):
        matches = [pin for pin in pins if pin.get("identity") == identity]
        if len(matches) != 1 or matches[0].get("state", {}).get("revision") != revision:
            raise RuntimeError(identity + " not locked to the exact candidate revision")
        checkout = work / "scratch" / "checkouts" / identity
        if not checkout.is_dir():
            raise RuntimeError(identity + " checkout missing from private Swift scratch")
        if run(["git", "rev-parse", "HEAD"], cwd=checkout).strip() != revision:
            raise RuntimeError(identity + " compiled checkout revision differs")
        if identity == S3_IDENTITY:
            for name in files:
                if (checkout / name).read_bytes() != (candidate / name).read_bytes():
                    raise RuntimeError("compiled S3 source differs from archive: " + name)
    return hashlib.sha256(lock.read_bytes()).hexdigest()


def main():
    check_clean()
    root_revision = run(["git", "rev-parse", "HEAD"]).strip()
    with tempfile.TemporaryDirectory(prefix="teaql-swift-s3-archive-consumer-") as temporary:
        work = Path(temporary)
        candidate, s3_revision, digest, files = make_candidate(work, root_revision)
        app = make_app(work, candidate, s3_revision)
        run([SWIFT, "package", "--package-path", str(app), "config", "set-mirror",
             "--original", RUNTIME_URL, "--mirror", ROOT.as_uri()], cwd=app)
        output = run([SWIFT, "run", "--package-path", str(app),
                      "--scratch-path", str(work / "scratch"), "--jobs", "2", "Probe"],
                     cwd=app)
        if "PASS Swift exact archive S3 consumer" not in output:
            raise RuntimeError("exact S3 source archive consumer did not run")
        lock_sha = check_origin(work, candidate, s3_revision, root_revision, files)
        print("PASS Swift exact archive S3 consumer root_revision=" + root_revision
              + " s3_revision=" + s3_revision + " archive_sha256=" + digest
              + " files=" + str(len(files)) + " lock_sha256=" + lock_sha,
              flush=True)


if __name__ == "__main__":
    main()
