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
# One scratch directory avoids copying the same dependency checkouts into all
# three examples; build-manifest caching stays disabled for source correctness.
(cd "$repo/Examples/Conformance" && swift run --jobs 2 --scratch-path "$repo/.build" --disable-build-manifest-caching --force-resolved-versions TeaQLConsole)
(cd "$repo/Examples/SchoolManagement" && swift run --jobs 2 --scratch-path "$repo/.build" --disable-build-manifest-caching --force-resolved-versions SchoolBootstrapVerification)
(cd "$repo/Examples/OrderManagement" && swift run --jobs 2 --scratch-path "$repo/.build" --disable-build-manifest-caching --force-resolved-versions teaql-order-management)
echo "PASS: all Swift examples"
