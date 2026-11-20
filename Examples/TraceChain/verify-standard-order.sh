#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
example="$repo/Examples/TraceChain"
scratch="${TEAQL_SWIFT_SCRATCH_PATH:-$repo/.build}"
source "$example/standard-verification-environment.sh"
standard_verification_environment order "$@"
cd "$example/standard-order/swift-app-console"
echo "Swift standard Order evidence: $evidence"
fingerprint > "$evidence/library-before.sha256"
swift build --jobs 2 --scratch-path "$scratch" --disable-build-manifest-caching \
  --force-resolved-versions --product StandardOrderVerification > "$evidence/build.log" 2>&1
for round in 1 2; do
  timeout --kill-after=10s 30s "${launch[@]}" \
    "$scratch/debug/StandardOrderVerification" "$evidence/orders.sqlite" > "$evidence/run-$round.log" 2>&1
  rg -q 'SWIFT_STANDARD_ORDER PASSED queries=4 counted=2 uncounted=2 total=3 preview=3 itemCount=5 facets=3' "$evidence/run-$round.log"
  if [[ "$round" == 1 ]]; then expected=4; else expected=0; fi
  rg -q "first_seed_audits=$expected repeat_seed_audits=0" "$evidence/run-$round.log"
  check_standard_startup "$evidence/run-$round.log"
  cat "$evidence/run-$round.log"
done
fingerprint > "$evidence/library-after.sha256"
cmp "$evidence/library-before.sha256" "$evidence/library-after.sha256"
echo 'PASS: Swift standard complete Order twice without database cleanup; library unchanged'
