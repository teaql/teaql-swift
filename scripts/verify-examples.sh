#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
expected=(Conformance OrderManagement SchoolManagement)
mapfile -t actual < <(find "$repo/Examples" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
if [[ "${actual[*]}" != "${expected[*]}" ]]; then
  echo "example inventory changed; update scripts/verify-examples.sh: ${actual[*]}" >&2
  exit 1
fi

(cd "$repo/Examples/Conformance" && swift run TeaQLConsole)
(cd "$repo/Examples/SchoolManagement" && swift run SchoolBootstrapVerification)
(cd "$repo/Examples/OrderManagement" && swift run teaql-order-management)
echo "PASS: all Swift examples"
