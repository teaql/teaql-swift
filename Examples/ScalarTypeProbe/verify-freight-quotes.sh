#!/usr/bin/env bash
set -euo pipefail
example="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app="$example/swift-app-console"
if [[ -n "${TEAQL_FREIGHT_QUOTE_EVIDENCE_DIR:-}" ]]; then
  evidence="$TEAQL_FREIGHT_QUOTE_EVIDENCE_DIR"
  mkdir "$evidence"
else
  evidence="$(mktemp -d -t teaql-swift-freight-evidence.XXXXXXXX)"
fi
evidence="$(cd "$evidence" && pwd)"
owned_scratch=""
scratch="${TEAQL_SWIFT_SCRATCH_PATH:-}"
cleanup() {
  status=$?
  trap - EXIT
  if [[ -n "$owned_scratch" ]]; then
    rm -rf -- "$owned_scratch" || { [[ "$status" != 0 ]] || status=1; }
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ -z "$scratch" ]]; then
  owned_scratch="$(mktemp -d -t teaql-swift-freight-build.XXXXXXXX)"
  scratch="$owned_scratch"
fi
check_domain_library() {
  diff -qr "$example/swift-lib-core/Sources/GeneratedTeaQL" "$app/Sources/GeneratedTeaQL"
}
check_domain_library
options=(--package-path "$app" --scratch-path "$scratch" --disable-build-manifest-caching --force-resolved-versions)
swift package "${options[@]}" show-dependencies --format json > "$evidence/dependencies.log" 2>&1
swift build "${options[@]}" --jobs 2 --product TeaQLConsole > "$evidence/build.log" 2>&1 || {
  tail -80 "$evidence/build.log"
  exit 1
}
binary_dir="$(swift build --package-path "$app" --scratch-path "$scratch" --show-bin-path)"
for phase in first restart; do
  "$binary_dir/TeaQLConsole" "$evidence/freight.sqlite" "$phase" | tee "$evidence/$phase.log"
done
check_domain_library
mkdir "$evidence/calibration"
TEAQL_SWIFT_SCALAR_EVIDENCE_DIR="${TEAQL_SWIFT_SCALAR_EVIDENCE_DIR:-$evidence/calibration/scalar}" TEAQL_SWIFT_SCRATCH_PATH="$scratch" bash "$example/verify.sh" | tee "$evidence/calibration/scalar.log"
echo "PASS Freight quotes and scalar calibrations. Evidence at $evidence"
