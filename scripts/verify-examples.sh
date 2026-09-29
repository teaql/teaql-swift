#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
expected=(Conformance OrderManagement SchoolManagement)
mapfile -t actual < <(find "$repo/Examples" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
if [[ "${actual[*]}" != "${expected[*]}" ]]; then
  echo "example inventory changed; update scripts/verify-examples.sh: ${actual[*]}" >&2
  exit 1
fi

# Local runtime dependencies may gain source files without changing Package.swift.
# Refresh the build plan so old manifests cannot omit newly added runtime code.
# Keep compiled artifacts and databases; this is not a clean-build workaround.
(cd "$repo/Examples/Conformance" && swift run --disable-build-manifest-caching TeaQLConsole)
(cd "$repo/Examples/SchoolManagement" && swift run --disable-build-manifest-caching SchoolBootstrapVerification)
(cd "$repo/Examples/OrderManagement" && swift run --disable-build-manifest-caching teaql-order-management)
echo "PASS: all Swift examples"
