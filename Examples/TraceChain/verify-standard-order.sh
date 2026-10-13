#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
example="$repo/Examples/TraceChain/standard-order"
scratch="${TEAQL_SWIFT_SCRATCH_PATH:-$repo/.build}"
evidence="$(mktemp -d -t teaql-swift-standard-order.XXXXXXXX)"
echo "Swift standard Order evidence: $evidence"
fingerprint() { (cd "$example/lib/Sources/GeneratedTeaQL" && rg --files -g '*.swift' | LC_ALL=C sort | xargs -d '\n' sha256sum); }
fingerprint > "$evidence/library-before.sha256"
(cd "$example" && swift build --jobs 2 --scratch-path "$scratch" --disable-build-manifest-caching --product StandardOrderVerification > "$evidence/build.log" 2>&1)
for round in 1 2; do
  "$scratch/debug/StandardOrderVerification" "$evidence/orders.sqlite" > "$evidence/run-$round.log" 2>&1
  rg -q 'SWIFT_STANDARD_ORDER PASSED queries=4 counted=2 uncounted=2 total=3 preview=3 itemCount=5 facets=3' "$evidence/run-$round.log"
  if [[ "$round" == 1 ]]; then expected=4; else expected=0; fi
  rg -q "first_seed_audits=$expected repeat_seed_audits=0" "$evidence/run-$round.log"
  for name in TEAQL_TELEMETRY_ENABLED TEAQL_TELEMETRY_SERVICE_NAME TEAQL_TELEMETRY_OTLP_ENDPOINT; do rg -q "$name" "$evidence/run-$round.log"; done
  cat "$evidence/run-$round.log"
done
fingerprint > "$evidence/library-after.sha256"
cmp "$evidence/library-before.sha256" "$evidence/library-after.sha256"
echo 'PASS: Swift standard complete Order twice without database cleanup; library unchanged'
