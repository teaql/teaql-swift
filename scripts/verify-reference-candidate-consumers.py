#!/usr/bin/env python3
"""Compile four disposable SwiftPM consumers of the current Git revision.

The runtime is resolved by a file:// Git URL pinned to HEAD, never by a path
package or the source checkout's build directory. No tag or remote write occurs.
"""

from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SWIFT = os.environ.get("TEAQL_SWIFT_BIN", "swift")


def run(args, *, cwd=ROOT, timeout=1200):
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(" ".join(map(str, args)) + " failed:\n"
                           + (result.stdout + result.stderr)[-5000:])
    return result.stdout + result.stderr


def app(work, name, revision, url, blob, secure):
    directory = work / name
    (directory / "Sources/Probe").mkdir(parents=True)
    products = ['.product(name: "TeaQLCore", package: "teaql-swift")']
    imports = ["import TeaQLCore"]
    symbols = []
    if blob:
        products.append('.product(name: "TeaQLBlobReference", package: "teaql-swift")')
        imports.append("import TeaQLBlobReference")
        symbols.append("let _ = BlobReferenceModule.self")
    if secure:
        products.append('.product(name: "TeaQLSecureDocumentReference", package: "teaql-swift")')
        imports.append("import TeaQLSecureDocumentReference")
        symbols.append("let _ = SecureDocumentReferenceModule.self")
    manifest = ("// swift-tools-version: 6.0\nimport PackageDescription\n"
                "let package = Package(\n  name: \"TeaQLReferenceCandidateProbe\",\n"
                "  dependencies: [.package(url: \"" + url + "\", revision: \""
                + revision + "\")],\n"
                "  targets: [.executableTarget(name: \"Probe\", dependencies: [\n    "
                + ",\n    ".join(products) + "\n  ])],\n"
                "  swiftLanguageModes: [.v6]\n)\n")
    source = "\n".join(imports + symbols + [f'print("PASS Swift candidate {name}")']) + "\n"
    if ("TeaQLBlobReference" in manifest + source) != blob or (
        "TeaQLSecureDocumentReference" in manifest + source
    ) != secure:
        raise RuntimeError(name + ": optional product leaked into absent cell")
    (directory / "Package.swift").write_text(manifest)
    (directory / "Sources/Probe/main.swift").write_text(source)
    return directory


def check_lock(directory, revision, url):
    data = json.loads((directory / "Package.resolved").read_text())
    matches = [pin for pin in data["pins"] if pin.get("identity") == "teaql-swift"]
    if len(matches) != 1:
        raise RuntimeError("candidate Git package identity was not locked exactly")
    pin = matches[0]
    local = pin.get("kind") == "localSourceControl" and pin.get("location") and (
        Path(pin["location"]).resolve() == ROOT
    )
    remote = pin.get("kind") == "remoteSourceControl" and pin.get("location") == url
    if not (local or remote) or pin.get("state", {}).get("revision") != revision:
        raise RuntimeError("candidate Git revision was not locked exactly: "
                           + json.dumps(matches, sort_keys=True))
    return hashlib.sha256((directory / "Package.resolved").read_bytes()).hexdigest()


def main():
    if len(sys.argv) != 1:
        raise SystemExit("Usage: verify-reference-candidate-consumers.py")
    changed = subprocess.run(["git", "status", "--porcelain", "--", "Package.swift", "Sources"],
                             cwd=ROOT, capture_output=True, text=True, check=True)
    if changed.stdout.strip():
        raise RuntimeError("runtime product source differs from pinned HEAD")
    revision = run(["git", "rev-parse", "HEAD"]).strip()
    url = ROOT.as_uri()
    with tempfile.TemporaryDirectory(prefix="teaql-swift-reference-candidate-") as temporary:
        work = Path(temporary)
        scratch = work / "scratch"
        for name, blob, secure in (("base", False, False), ("secure", False, True),
                                   ("blob", True, False), ("combined", True, True)):
            directory = app(work, name, revision, url, blob, secure)
            output = run([SWIFT, "run", "--package-path", str(directory),
                          "--scratch-path", str(scratch), "--jobs", "2", "Probe"],
                         cwd=directory)
            if f"PASS Swift candidate {name}" not in output:
                raise RuntimeError(name + ": executable did not run")
            digest = check_lock(directory, revision, url)
            print(f"PASS Swift revision candidate {name} lock_sha256={digest}", flush=True)
    print("PASS Swift four-cell local Git revision " + revision, flush=True)


if __name__ == "__main__":
    main()
