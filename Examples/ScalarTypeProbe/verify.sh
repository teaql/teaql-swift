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
for round in 1 2; do
  TEAQL_EMPTY_DB="$evidence/empty-aggregates.sqlite" TEAQL_EMPTY_ROUND="$round" \
    TEAQL_EMPTY_VECTORS="$example/empty-aggregates.json" \
    swift run --scratch-path "$scratch" --skip-build EmptyAggregateVerification \
    | tee "$evidence/empty-aggregates-round-$round.log"
  node -e 'const fs=require("node:fs"),assert=require("node:assert/strict");const rows=fs.readFileSync(process.argv[1],"utf8").split(/\r?\n/).filter(v=>v.startsWith("SWIFT_EMPTY_AGGREGATES=")).map(v=>JSON.parse(v.slice("SWIFT_EMPTY_AGGREGATES=".length)));assert.equal(rows.length,1);const r=rows[0];assert.equal(r.passed,true);assert.equal(r.round,+process.argv[2]);assert.equal(r.scalars.length,4);assert.equal(r.buckets.length,2);assert.equal(r.requests.length,13);assert.equal(r.groupedRows,0);assert.equal(r.fallbackRaw,null);assert.equal(r.exactSum,"123456789012.345679");assert.equal(r.failureSQL.length,2);assert.equal(r.failureSQL[1].outcome,"failure");' \
    "$evidence/empty-aggregates-round-$round.log" "$round"
  sha256sum -c generated.sha256
done
for round in 1 2; do
  TEAQL_INTEGER32_DB="$evidence/integer32.sqlite" TEAQL_INTEGER32_ROUND="$round" \
    swift run --scratch-path "$scratch" --skip-build Integer32Verification \
    | tee "$evidence/integer32-round-$round.log"
  node -e 'const fs=require("node:fs"),assert=require("node:assert/strict");const rows=fs.readFileSync(process.argv[1],"utf8").split(/\r?\n/).filter(v=>v.startsWith("SWIFT_INTEGER32=")).map(v=>JSON.parse(v.slice("SWIFT_INTEGER32=".length)));assert.equal(rows.length,1);const r=rows[0];assert.equal(r.passed,true);assert.equal(r.round,+process.argv[2]);assert.equal(r.metadataCorrect,true);assert.deepEqual(r.markerNames,["optional_integer","required_integer"]);assert.equal(r.cases.length,83);assert(r.cases.every(c=>c.passed));assert.equal(r.controls.length,2);assert.equal(r.legacy.length,8);' \
    "$evidence/integer32-round-$round.log" "$round"
  sha256sum -c generated.sha256
done
for round in 1 2; do
  TEAQL_SWIFT_TOMBSTONE_DB="$evidence/tombstone.sqlite" TEAQL_SWIFT_TOMBSTONE_ROUND="$round" \
    swift run --scratch-path "$scratch" --skip-build TombstoneVerification | tee "$evidence/tombstone-round-$round.log"
  node -e 'const fs=require("node:fs"),assert=require("node:assert/strict");const rows=fs.readFileSync(process.argv[1],"utf8").split(/\r?\n/).filter(v=>v.startsWith("SWIFT_TOMBSTONE=")).map(v=>JSON.parse(v.slice("SWIFT_TOMBSTONE=".length)));assert.equal(rows.length,6);assert(rows.every(v=>v.passed&&v.round===+process.argv[2]&&v.nativeGeneratedVersionConsistent));' "$evidence/tombstone-round-$round.log" "$round"
  sha256sum -c generated.sha256
done
for round in 1 2; do
  TEAQL_SWIFT_ROUNDTRIP_DB="$evidence/roundtrip.sqlite" TEAQL_SWIFT_ROUNDTRIP_ROUND="$round" \
    swift run --scratch-path "$scratch" --skip-build ScalarRoundtripVerification | tee "$evidence/roundtrip-round-$round.log"
  node -e 'const fs=require("node:fs"),assert=require("node:assert/strict");const rows=fs.readFileSync(process.argv[1],"utf8").split(/\r?\n/).filter(v=>v.startsWith("SWIFT_SCALAR_ROUNDTRIP=")).map(v=>JSON.parse(v.slice("SWIFT_SCALAR_ROUNDTRIP=".length)));assert.equal(rows.length,1);const r=rows[0];assert(r.passed&&r.round===+process.argv[2]);assert.equal(r.finalVersion,4);assert.equal(r.rejections.length,24);assert(r.rejections.every(v=>v.rejected&&v.counts.query===0&&v.counts.mutate===0&&v.counts.begin===0));assert(Object.values(r.checks).every(Boolean));assert.equal(r.nativeScalarFields,21);assert.equal(Object.keys(r.checks).length,522);' "$evidence/roundtrip-round-$round.log" "$round"
  sha256sum -c generated.sha256
done
for round in 1 2; do
  TEAQL_DYNAMIC_DECIMAL_DB="$evidence/dynamic-decimal.sqlite" TEAQL_DYNAMIC_DECIMAL_ROUND="$round" \
    swift run --scratch-path "$scratch" --skip-build DynamicDecimalVerification \
    | tee "$evidence/dynamic-decimal-round-$round.log"
  node -e 'const fs=require("node:fs"),assert=require("node:assert/strict");const rows=fs.readFileSync(process.argv[1],"utf8").split(/\r?\n/).filter(v=>v.startsWith("SWIFT_DYNAMIC_DECIMAL=")).map(v=>JSON.parse(v.slice("SWIFT_DYNAMIC_DECIMAL=".length)));assert.equal(rows.length,1);const r=rows[0];assert(r.passed&&r.round===+process.argv[2]);assert.equal(r.rejections,96);assert.equal(Object.keys(r.checks).length,116);assert(Object.values(r.checks).every(Boolean));assert.equal(Object.keys(r.rows).length,4);' \
    "$evidence/dynamic-decimal-round-$round.log" "$round"
  sha256sum -c generated.sha256
done
echo "PASS Swift scalar example twice without cleanup; evidence: $evidence"
