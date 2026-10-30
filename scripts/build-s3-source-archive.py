#!/usr/bin/env python3
"""Export a standalone SwiftPM S3 source archive from one committed runtime revision.

The development package keeps its local path dependency. This export replaces
only that manifest edge with the exact root Git revision; it never tags, pushes,
uploads, or chooses a release version.
"""

import argparse
from io import BytesIO
import hashlib
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SWIFT = os.environ.get("TEAQL_SWIFT_BIN", "swift")
RUNTIME_URL = "https://github.com/teaql/teaql-swift.git"
OLD_EDGE = '.package(name: "TeaQLRuntime", path: "..")'


def run(args, *, cwd=ROOT, timeout=120):
    result = subprocess.run(args, cwd=cwd, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(" ".join(map(str, args)) + " failed: "
                           + result.stderr.decode(errors="replace")[-3000:])
    return result.stdout


def exact_revision():
    revision = run(["git", "rev-parse", "HEAD"]).decode().strip()
    if len(revision) != 40 or any(c not in "0123456789abcdef" for c in revision):
        raise RuntimeError("source must have one exact Git commit")
    return revision


def export_committed_s3(destination, revision):
    raw = run(["git", "archive", "--format=tar", revision + ":ObjectStorageS3"])
    copied = {}
    with tarfile.open(fileobj=BytesIO(raw), mode="r:") as archive:
        for member in archive:
            name = Path(member.name)
            if name.is_absolute() or ".." in name.parts or member.issym() or member.islnk():
                raise RuntimeError("unsafe S3 Git archive entry: " + member.name)
            if member.isdir():
                continue
            if not member.isfile():
                raise RuntimeError("unsupported S3 Git archive entry: " + member.name)
            if name == Path("Package.resolved"):
                continue
            content = archive.extractfile(member).read()
            target = destination / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
            copied[name.as_posix()] = hashlib.sha256(content).hexdigest()
    if "Package.swift" not in copied or "Sources/TeaQLObjectStorageS3/S3ObjectStorage.swift" not in copied:
        raise RuntimeError("S3 package manifest or provider source missing")
    return copied


def add_root_license(destination, revision, copied):
    """Keep an independent S3 archive licensed from the same Git revision."""
    if "LICENSE" in copied:
        return
    content = run(["git", "show", revision + ":LICENSE"])
    if not content:
        raise RuntimeError("committed root LICENSE is empty")
    (destination / "LICENSE").write_bytes(content)
    copied["LICENSE"] = hashlib.sha256(content).hexdigest()


def rewrite_manifest(destination, revision):
    manifest = destination / "Package.swift"
    source = manifest.read_text()
    if source.count(OLD_EDGE) != 1:
        raise RuntimeError("expected exactly one local runtime dependency")
    new_edge = ('.package(name: "TeaQLRuntime", url: "' + RUNTIME_URL
                + '", revision: "' + revision + '")')
    content = source.replace(OLD_EDGE, new_edge)
    manifest.write_text(content)
    return hashlib.sha256(content.encode()).hexdigest()


def verify_zip(archive, expected, manifest_sha, root_name):
    with zipfile.ZipFile(archive) as reader:
        names = reader.namelist()
        if len(names) != len(set(names)):
            raise RuntimeError("duplicate Swift source archive entry")
        prefix = root_name + "/"
        if any(not name.startswith(prefix) for name in names):
            raise RuntimeError("Swift source archive escaped its package root")
        actual = {name[len(prefix):]: hashlib.sha256(reader.read(name)).hexdigest()
                  for name in names if not name.endswith("/")}
    expected = dict(expected, **{"Package.swift": manifest_sha})
    if actual != expected:
        raise RuntimeError("Swift source archive differs from committed S3 source: "
                           + "missing=" + repr(sorted(expected.keys() - actual.keys()))
                           + " extra=" + repr(sorted(actual.keys() - expected.keys()))
                           + " changed=" + repr(sorted(name for name in actual.keys() & expected.keys()
                                                      if actual[name] != expected[name])))
    return hashlib.sha256(archive.read_bytes()).hexdigest(), len(actual)


def normalize_zip(archive, temporary):
    normalized = Path(temporary) / "normalized.zip"
    with zipfile.ZipFile(archive) as source, zipfile.ZipFile(normalized, "w") as target:
        for old in sorted(source.infolist(), key=lambda item: item.filename):
            info = zipfile.ZipInfo(old.filename, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = old.create_system
            info.external_attr = old.external_attr
            info.compress_type = old.compress_type
            target.writestr(info, source.read(old), compresslevel=9)
    normalized.replace(archive)


def build(output):
    output = Path(output).resolve()
    if output.exists() or output.is_symlink():
        raise RuntimeError("refusing to overwrite existing archive: " + str(output))
    if not output.parent.is_dir():
        raise RuntimeError("archive output directory does not exist")
    revision = exact_revision()
    with tempfile.TemporaryDirectory(prefix="teaql-swift-s3-source-") as temporary:
        package = Path(temporary) / "teaql-objectstorage-s3"
        package.mkdir()
        copied = export_committed_s3(package, revision)
        add_root_license(package, revision, copied)
        manifest_sha = rewrite_manifest(package, revision)
        try:
            run([SWIFT, "package", "--package-path", str(package), "archive-source",
                 "--output", str(output)], timeout=300)
            normalize_zip(output, temporary)
            digest, count = verify_zip(output, copied, manifest_sha, package.name)
        except BaseException:
            output.unlink(missing_ok=True)
            raise
    return revision, digest, count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, help="new source ZIP path")
    args = parser.parse_args()
    revision, digest, count = build(args.output)
    print("PASS standalone Swift S3 source archive root_revision=" + revision
          + " sha256=" + digest + " files=" + str(count), flush=True)


if __name__ == "__main__":
    main()
