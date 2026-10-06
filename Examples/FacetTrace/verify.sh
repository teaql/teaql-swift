#!/usr/bin/env bash
set -euo pipefail
example="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$example/../.." && pwd)"
evidence="$(mktemp -d /tmp/teaql-swift-facet-example-XXXXXX)"
database="$evidence/school.db"
scratch="${TEAQL_SWIFT_SCRATCH_PATH:-$repo/.build}"
hash_library() {
  (cd "$example/Generated/Sources" && find . -type f -name '*.swift' -print0 | sort -z | xargs -0 sha256sum)
}
hash_library > "$evidence/generated-before.sha256"
cd "$example"
for round in 1 2; do
  if ! timeout --kill-after=10s 180s env -u TEAQL_ALLOW_SENSITIVE_PLAINTEXT_LOGS \
      swift run --jobs 2 --scratch-path "$scratch" --disable-build-manifest-caching \
      --force-resolved-versions FacetAcceptance "$database" > "$evidence/round-$round.log" 2>&1; then
    tail -100 "$evidence/round-$round.log" >&2
    echo "FAIL: retained Swift Facet evidence $evidence" >&2
    exit 1
  fi
  rg -Fq 'Swift generated Facet acceptance passed: 26 scenarios;' "$evidence/round-$round.log"
  echo "PASS: Swift generated Facet round $round, same database, no cleanup"
done
hash_library > "$evidence/generated-after.sha256"
cmp "$evidence/generated-before.sha256" "$evidence/generated-after.sha256"
echo "PASS: unchanged generated library; database $database; evidence $evidence"
