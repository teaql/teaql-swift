#!/usr/bin/env bash
set -euo pipefail
example="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$example/../.." && pwd)"
if [[ $# -gt 1 ]]; then echo 'usage: bash verify-checker-overlap.sh [retained-sqlite-path]' >&2; exit 2; fi
evidence="${TEAQL_SWIFT_CHECKER_EVIDENCE:-$(mktemp -d /tmp/teaql-swift-checker-overlap.XXXXXX)}"
mkdir -p "$evidence"
evidence="$(cd "$evidence" && pwd)"
database="${1:-$evidence/checker.sqlite}"
scratch="${TEAQL_SWIFT_SCRATCH_PATH:-$repo/.build}"
cd "$example"
hash_library() {
  find Generated/Sources -type f -name '*.swift' -print0 | sort -z | xargs -0 sha256sum
  sha256sum Generated/Package.swift
}
hash_library > "$evidence/verified-before.sha256"
for round in first second; do
  timeout --kill-after=10s 180s env -u TEAQL_ALLOW_SENSITIVE_PLAINTEXT_LOGS TEAQL_SWIFT_TRACE_SCENARIO=checker-overlap \
    swift run --jobs 2 --scratch-path "$scratch" --disable-build-manifest-caching \
    --force-resolved-versions TraceChainVerification "$database" > "$evidence/$round.log" 2>&1
  rg -F 'PASS: Swift generated Checker accepted/rejected overlap 4 cases; callbacks serialized' "$evidence/$round.log"
done
hash_library > "$evidence/verified-after.sha256"
cmp "$evidence/verified-before.sha256" "$evidence/verified-after.sha256"
printf 'PASS: Checker overlap twice on %s; generated library unchanged; evidence %s\n' "$database" "$evidence"
