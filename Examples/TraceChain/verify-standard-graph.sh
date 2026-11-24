#!/usr/bin/env bash
set -euo pipefail
example="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$example/../.." && pwd)"
scratch="${TEAQL_SWIFT_SCRATCH_PATH:-$repo/.build}"
source "$example/standard-verification-environment.sh"
standard_verification_environment graph "$@"
cd "$example/swift-app-console"
fingerprint > "$evidence/before.sha256"
swift build --jobs 2 --scratch-path "$scratch" --disable-build-manifest-caching \
  --force-resolved-versions --product StandardGraphVerification
for round in 1 2; do
  timeout --kill-after=10s 30s "${launch[@]}" \
    "$scratch/debug/StandardGraphVerification" "$evidence/graph.sqlite" > "$evidence/run-$round.log" 2>&1
  check_standard_startup "$evidence/run-$round.log"
  rg -Fq 'SWIFT_STANDARD_GRAPH PASSED create=6 rollback=0 retry=6 deleted=1' "$evidence/run-$round.log"
  expected=0; if [[ "$round" == 1 ]]; then expected=1; fi
  rg -Fq "first_seed_audits=$expected repeat_seed_audits=0 ordinary_sql_logs=0" "$evidence/run-$round.log"
  rg '^SWIFT_STANDARD_GRAPH PASSED' "$evidence/run-$round.log"
done
fingerprint > "$evidence/after.sha256"
cmp "$evidence/before.sha256" "$evidence/after.sha256"
echo "PASS: Swift standard graph twice without cleanup; library unchanged; evidence $evidence"
