#!/usr/bin/env bash
set -euo pipefail
example="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$example/../.." && pwd)"
evidence="$(mktemp -d /tmp/teaql-swift-standard-example-XXXXXX)"
scratch="${TEAQL_SWIFT_SCRATCH_PATH:-$repo/.build}"
cd "$example"
hash_library() {
  find Generated/Sources -type f -name '*.swift' -print0 | sort -z | xargs -0 sha256sum
  sha256sum Generated/Package.swift
}
hash_library > "$evidence/generated-before.sha256"
swift build --jobs 2 --scratch-path "$scratch" --disable-build-manifest-caching \
  --force-resolved-versions --product StandardTelemetryVerification
for round in first second; do
  timeout --kill-after=10s 30s env -u TEAQL_TELEMETRY_ENABLED \
    -u TEAQL_TELEMETRY_SERVICE_NAME -u TEAQL_TELEMETRY_OTLP_ENDPOINT \
    "$scratch/debug/StandardTelemetryVerification" "$evidence/$round.sqlite" \
    2>&1 | tee "$evidence/$round.log"
  rg -Fq 'TeaQL telemetry: supported, disabled.' "$evidence/$round.log"
  for name in TEAQL_TELEMETRY_ENABLED TEAQL_TELEMETRY_SERVICE_NAME TEAQL_TELEMETRY_OTLP_ENDPOINT; do
    rg -Fq "$name" "$evidence/$round.log"
  done
  rg -Fxq 'PASS Swift standard telemetry: seeded root=1 repeated seed writes=0 Q/E=2 SQL=6 committed audit=1' "$evidence/$round.log"
done
hash_library > "$evidence/generated-after.sha256"
cmp "$evidence/generated-before.sha256" "$evidence/generated-after.sha256"
echo "PASS Swift standard telemetry example; evidence retained: $evidence"
