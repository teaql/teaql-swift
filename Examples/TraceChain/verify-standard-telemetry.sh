#!/usr/bin/env bash
set -euo pipefail
example="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$example/../.." && pwd)"
scratch="${TEAQL_SWIFT_SCRATCH_PATH:-$repo/.build}"
source "$example/standard-verification-environment.sh"
standard_verification_environment telemetry "$@"
cd "$example/swift-app-console"
fingerprint > "$evidence/generated-before.sha256"
swift build --jobs 2 --scratch-path "$scratch" --disable-build-manifest-caching \
  --force-resolved-versions --product StandardTelemetryVerification
for round in first second; do
  timeout --kill-after=10s 30s "${launch[@]}" \
    "$scratch/debug/StandardTelemetryVerification" "$evidence/$round.sqlite" \
    2>&1 | tee "$evidence/$round.log"
  check_standard_startup "$evidence/$round.log"
  rg -Fxq 'PASS Swift standard telemetry: seeded root=1 repeated seed writes=0 Q/E=2 SQL=6 committed audit=1' "$evidence/$round.log"
done
fingerprint > "$evidence/generated-after.sha256"
cmp "$evidence/generated-before.sha256" "$evidence/generated-after.sha256"
echo "PASS Swift standard telemetry example; evidence retained: $evidence"
