#!/usr/bin/env bash
set -euo pipefail
example="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$example/../.." && pwd)"
evidence="$(mktemp -d -t teaql-swift-scalar.XXXXXXXX)"
scratch="${TEAQL_SWIFT_SCRATCH_PATH:-$repo/.build}"
cd "$example"
sha256sum -c generated.sha256
swift build --jobs 2 --scratch-path "$scratch" --disable-build-manifest-caching \
  --force-resolved-versions > "$evidence/build.log" 2>&1 || {
    tail -n 35 "$evidence/build.log"; exit 1;
  }
for round in 1 2; do
  TEAQL_SCALAR_DB="$evidence/scalar.sqlite" swift run --scratch-path "$scratch" \
    --skip-build ScalarDecimalVerification | tee "$evidence/round-$round.log"
  fresh=true; version=2
  if [[ "$round" == 2 ]]; then fresh=false; version=3; fi
  rg -Fq "PASS Swift generated scalar Decimal fresh=$fresh rows=3 version=$version" "$evidence/round-$round.log"
  sha256sum -c generated.sha256
done
echo "PASS Swift scalar example twice without cleanup; evidence: $evidence"
