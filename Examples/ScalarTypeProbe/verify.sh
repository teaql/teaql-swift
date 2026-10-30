#!/usr/bin/env bash
set -euo pipefail
example="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$example/../.." && pwd)"
if [[ -n "${TEAQL_SWIFT_SCALAR_EVIDENCE_DIR:-}" ]]; then
  evidence="$TEAQL_SWIFT_SCALAR_EVIDENCE_DIR"
  if [[ -e "$evidence" ]]; then echo "refusing to overwrite scalar evidence: $evidence" >&2; exit 1; fi
  mkdir -p "$evidence"
else
  evidence="$(mktemp -d -t teaql-swift-scalar.XXXXXXXX)"
fi
scratch="${TEAQL_SWIFT_SCRATCH_PATH:-$repo/.build}"
cd "$example"
sha256sum -c generated.sha256
swift build --jobs 2 --scratch-path "$scratch" --disable-build-manifest-caching \
  --force-resolved-versions > "$evidence/build.log" 2>&1 || {
    cat "$evidence/build.log"; exit 1;
  }
for round in 1 2; do
  TEAQL_SCALAR_DB="$evidence/scalar.sqlite" swift run --scratch-path "$scratch" \
    --skip-build ScalarDecimalVerification | tee "$evidence/round-$round.log"
  fresh=true; version=2
  if [[ "$round" == 2 ]]; then fresh=false; version=3; fi
  rg -Fq "PASS Swift generated scalar Decimal fresh=$fresh rows=3 version=$version" "$evidence/round-$round.log"
  sha256sum -c generated.sha256
done
for round in 1 2; do
  TEAQL_QUERY_PROPERTY_DB="$evidence/query-properties.sqlite" swift run --scratch-path "$scratch" \
    --skip-build QueryPropertyVerification | tee "$evidence/query-properties-round-$round.log"
  node -e 'const fs=require("node:fs"),assert=require("node:assert/strict");const rows=fs.readFileSync(process.argv[1],"utf8").split(/\r?\n/).filter(v=>v.startsWith("SWIFT_QUERY_PROPERTY_JSON=")).map(v=>JSON.parse(v.slice("SWIFT_QUERY_PROPERTY_JSON=".length)));assert.equal(rows.length,1);assert.equal(rows[0].passed,true);assert.equal(rows[0].count,0);assert.equal(rows[0].encodedCount,0);' "$evidence/query-properties-round-$round.log"
  sha256sum -c generated.sha256
done
echo "PASS Swift scalar example twice without cleanup; evidence: $evidence"
