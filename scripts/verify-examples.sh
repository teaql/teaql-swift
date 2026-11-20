#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
if [[ "$#" -gt 1 || ( "$mode" != "" && "$mode" != "--after-freight-quotes" ) ]]; then
  echo "Usage: bash scripts/verify-examples.sh [--after-freight-quotes]" >&2
  exit 2
fi

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
expected=(Conformance ContextDerived ExpressionProfiles FacetTrace FixEAlignment NaturalMessages ObjectStorage OrderManagement QueryGrouping ScalarTypeProbe SchoolManagement TraceChain)
mapfile -t actual < <(find "$repo/Examples" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
if [[ "${actual[*]}" != "${expected[*]}" ]]; then
  echo "example inventory changed; update scripts/verify-examples.sh: ${actual[*]}" >&2
  exit 1
fi
if [[ -z "$mode" ]]; then
node "$repo/scripts/verify-generated-fixtures.cjs"
node "$repo/Examples/FixEAlignment/verify-local.cjs"
fi
inventory_evidence="${TEAQL_EXAMPLES_EVIDENCE_DIR:-$(mktemp -d -t teaql-swift-examples-evidence.XXXXXXXX)}"
mkdir -p "$inventory_evidence"
if [[ -z "$mode" ]]; then
TEAQL_CONTEXT_FIX_EVIDENCE_DIR="$inventory_evidence/context-derived" node "$repo/Examples/ContextDerived/verify-local.cjs"
node --test "$repo/scripts/verify-natural-messages.test.cjs"
node "$repo/scripts/verify-natural-messages.cjs" --example-only --output "$inventory_evidence/natural-messages"
export TEAQL_SWIFT_SCALAR_EVIDENCE_DIR="$inventory_evidence/scalar"
export TEAQL_SWIFT_EXAMPLE_SOURCE_ROOT="${TEAQL_SWIFT_EXAMPLE_SOURCE_ROOT:-${TEAQL_FIX_E_SOURCE_ROOT:+$TEAQL_FIX_E_SOURCE_ROOT/swift}}"
if [[ -z "$TEAQL_SWIFT_EXAMPLE_SOURCE_ROOT" ]]; then export TEAQL_SWIFT_EXAMPLE_SOURCE_ROOT="$repo"; fi
TEAQL_DISPATCH_PROFILE_EVIDENCE_DIR="$inventory_evidence/expression-profiles" bash "$repo/Examples/ExpressionProfiles/verify-dispatch.sh"
fi

# Local runtime dependencies may gain source files without changing Package.swift.
# Refresh the build plan so old manifests cannot omit newly added runtime code.
# Keep compiled artifacts and databases; this is not a clean-build workaround.
# One scratch directory avoids copying the same dependency checkouts into all
# examples; build-manifest caching stays disabled for source correctness.
# An explicit scratch path also allows isolated ABI/layout verification without
# deleting the normal build cache or any retained example database.
scratch="${TEAQL_SWIFT_SCRATCH_PATH:-$repo/.build}"
if [[ -z "$mode" ]]; then
TEAQL_FREIGHT_QUOTE_EVIDENCE_DIR="$inventory_evidence/freight-quotes" TEAQL_SWIFT_SCRATCH_PATH="$scratch" bash "$repo/Examples/ScalarTypeProbe/verify-freight-quotes.sh"
TEAQL_CONFORMANCE_EVIDENCE_DIR="$inventory_evidence/conformance" TEAQL_SWIFT_SCRATCH_PATH="$scratch" \
  bash "$repo/Examples/Conformance/verify.sh"
fi
TEAQL_SCHOOL_EVIDENCE_DIR="$inventory_evidence/school-management" TEAQL_SWIFT_SCRATCH_PATH="$scratch" \
  bash "$repo/Examples/SchoolManagement/verify.sh"
TEAQL_ORDER_EVIDENCE_DIR="$inventory_evidence/order-management" TEAQL_SWIFT_SCRATCH_PATH="$scratch" \
  bash "$repo/Examples/OrderManagement/verify.sh"
TEAQL_SWIFT_GROUPING_EVIDENCE_DIR="$inventory_evidence/query-grouping" \
  TEAQL_SWIFT_SCRATCH_PATH="$scratch" bash "$repo/Examples/QueryGrouping/verify.sh"
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
if [[ -z "$mode" ]]; then
  echo "PASS: all Swift examples"
else
  echo "PASS: Swift examples after freight quotes and conformance"
fi
