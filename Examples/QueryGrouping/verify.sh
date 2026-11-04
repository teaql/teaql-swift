#!/usr/bin/env bash
set -euo pipefail
example="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$example/../.." && pwd)"
evidence="${TEAQL_SWIFT_GROUPING_EVIDENCE_DIR:-}"
if [[ -z "$evidence" ]]; then evidence="$(mktemp -d -t teaql-swift-query-grouping.XXXXXXXX)"; fi
if [[ -e "$evidence/grouping.sqlite" || -e "$evidence/round-1.log" ]]; then
  echo "refusing to overwrite grouping evidence: $evidence" >&2; exit 1
fi
mkdir -p "$evidence"
owned_scratch=""
cleanup() {
  result=$?
  trap - EXIT INT TERM
  if [[ -n "$owned_scratch" ]]; then
    if ! node -e 'const fs=require("node:fs"),path=require("node:path"),assert=require("node:assert/strict");const p=process.argv[1];assert(path.basename(p).startsWith("teaql-swift-query-grouping-build."));assert.equal(fs.realpathSync(p),p);fs.rmSync(p,{recursive:true});' "$owned_scratch"; then
      if [[ "$result" -eq 0 ]]; then result=1; fi
    fi
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
scratch="${TEAQL_SWIFT_SCRATCH_PATH:-}"
if [[ -z "$scratch" ]]; then
  owned_scratch="$(mktemp -d -t teaql-swift-query-grouping-build.XXXXXXXX)"
  scratch="$owned_scratch"
fi
node "$repo/scripts/verify-generated-fixtures.cjs"
node --test "$example/verify-results.test.cjs"
cd "$example"
swift build --jobs 2 --scratch-path "$scratch" --disable-build-manifest-caching \
  --force-resolved-versions --product GroupingAliasProbe > "$evidence/build.log" 2>&1 || {
    cat "$evidence/build.log"; exit 1;
  }
binary_path="$(swift build --scratch-path "$scratch" --show-bin-path)"
for round in 1 2; do
  "$binary_path/GroupingAliasProbe" "$evidence/grouping.sqlite" nonhuman "$round" \
    | tee "$evidence/round-$round.log"
done
node "$example/verify-results.cjs" "$evidence"
node "$repo/scripts/verify-generated-fixtures.cjs"
echo "PASS Swift generated grouping aliases twice without cleanup; evidence: $evidence"
