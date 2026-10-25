#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
expected=(Conformance FacetTrace FixEAlignment ObjectStorage OrderManagement ScalarTypeProbe SchoolManagement TraceChain)
mapfile -t actual < <(find "$repo/Examples" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
if [[ "${actual[*]}" != "${expected[*]}" ]]; then
  echo "example inventory changed; update scripts/verify-examples.sh: ${actual[*]}" >&2
  exit 1
fi
node "$repo/scripts/verify-generated-fixtures.cjs"
node "$repo/Examples/FixEAlignment/verify-local.cjs"
inventory_evidence="${TEAQL_EXAMPLES_EVIDENCE_DIR:-$(mktemp -d -t teaql-swift-examples-evidence.XXXXXXXX)}"
mkdir -p "$inventory_evidence"
export TEAQL_SWIFT_SCALAR_EVIDENCE_DIR="$inventory_evidence/scalar"

# Local runtime dependencies may gain source files without changing Package.swift.
# Refresh the build plan so old manifests cannot omit newly added runtime code.
# Keep compiled artifacts and databases; this is not a clean-build workaround.
# One scratch directory avoids copying the same dependency checkouts into all
# examples; build-manifest caching stays disabled for source correctness.
# An explicit scratch path also allows isolated ABI/layout verification without
# deleting the normal build cache or any retained example database.
scratch="${TEAQL_SWIFT_SCRATCH_PATH:-$repo/.build}"
TEAQL_SWIFT_SCRATCH_PATH="$scratch" bash "$repo/Examples/ScalarTypeProbe/verify.sh"
(cd "$repo/Examples/Conformance" && swift run --jobs 2 --scratch-path "$scratch" --disable-build-manifest-caching --force-resolved-versions TeaQLConsole)
(cd "$repo/Examples/SchoolManagement" && swift run --jobs 2 --scratch-path "$scratch" --disable-build-manifest-caching --force-resolved-versions SchoolBootstrapVerification)
(cd "$repo/Examples/OrderManagement" && swift run --jobs 2 --scratch-path "$scratch" --disable-build-manifest-caching --force-resolved-versions teaql-order-management)
trace_args=()
if [[ -n "${TEAQL_SWIFT_TRACE_DATABASE:-}" ]]; then trace_args+=("$TEAQL_SWIFT_TRACE_DATABASE"); fi
TEAQL_SWIFT_SCRATCH_PATH="$scratch" bash "$repo/Examples/TraceChain/verify.sh" "${trace_args[@]}"
TEAQL_SWIFT_SCRATCH_PATH="$scratch" bash "$repo/Examples/TraceChain/verify-standard-telemetry.sh"
TEAQL_SWIFT_SCRATCH_PATH="$scratch" bash "$repo/Examples/TraceChain/verify-standard-graph.sh"
TEAQL_SWIFT_SCRATCH_PATH="$scratch" bash "$repo/Examples/FacetTrace/verify.sh"
TEAQL_SWIFT_SCRATCH_PATH="$scratch" bash "$repo/scripts/verify-mutation-batch-api.sh"
TEAQL_SWIFT_SCRATCH_PATH="$scratch" bash "$repo/Examples/TraceChain/verify-standard-order.sh"
TEAQL_SWIFT_SCRATCH_PATH="$scratch" bash "$repo/Examples/ObjectStorage/verify.sh"
node "$repo/scripts/verify-generated-fixtures.cjs"
echo "PASS: all Swift examples"
