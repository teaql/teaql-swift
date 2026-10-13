#!/usr/bin/env bash
set -euo pipefail
example="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$example/../.." && pwd)"
scratch="${TEAQL_SWIFT_SCRATCH_PATH:-$repo/.build}"
evidence="$(mktemp -d /tmp/teaql-swift-standard-graph-XXXXXX)"
cd "$example"
fingerprint() { (cd Generated && rg --files -g '*.swift' | LC_ALL=C sort | xargs sha256sum); }
fingerprint > "$evidence/before.sha256"
swift build --jobs 2 --scratch-path "$scratch" --disable-build-manifest-caching \
  --force-resolved-versions --product StandardGraphVerification
for round in 1 2; do
  timeout --kill-after=10s 30s env -u TEAQL_TELEMETRY_ENABLED \
    -u TEAQL_TELEMETRY_SERVICE_NAME -u TEAQL_TELEMETRY_OTLP_ENDPOINT \
    "$scratch/debug/StandardGraphVerification" "$evidence/graph.sqlite" > "$evidence/run-$round.log" 2>&1
  for variable in TEAQL_TELEMETRY_ENABLED TEAQL_TELEMETRY_SERVICE_NAME TEAQL_TELEMETRY_OTLP_ENDPOINT; do
    rg -Fq "$variable" "$evidence/run-$round.log"
  done
  rg -Fq 'SWIFT_STANDARD_GRAPH PASSED create=6 rollback=0 retry=6 deleted=1' "$evidence/run-$round.log"
  expected=0; if [[ "$round" == 1 ]]; then expected=1; fi
  rg -Fq "first_seed_audits=$expected repeat_seed_audits=0 ordinary_sql_logs=0" "$evidence/run-$round.log"
  rg '^SWIFT_STANDARD_GRAPH PASSED' "$evidence/run-$round.log"
done
fingerprint > "$evidence/after.sha256"
cmp "$evidence/before.sha256" "$evidence/after.sha256"
echo "PASS: Swift standard graph twice without cleanup; library unchanged; evidence $evidence"
