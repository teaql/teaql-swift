#!/usr/bin/env bash
set -euo pipefail
example="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$example/../.." && pwd)"
if [[ $# -gt 1 ]]; then echo 'usage: bash verify.sh [retained-sqlite-path]' >&2; exit 2; fi
if [[ $# -eq 1 ]]; then
  trace_database="$1"
else
  trace_directory="$(mktemp -d /tmp/teaql-swift-generated-trace-XXXXXX)"
  trace_database="$trace_directory/trace.sqlite"
fi
trace_evidence="$(mktemp -d /tmp/teaql-swift-generated-trace-evidence-XXXXXX)"
scratch="${TEAQL_SWIFT_SCRATCH_PATH:-$repo/.build}"
cd "$example"
hash_library() {
  find Generated/Sources -type f -name '*.swift' -print0 | sort -z | xargs -0 sha256sum
  sha256sum Generated/Package.swift
}
hash_library > "$trace_evidence/generated-before.sha256"
for round in first second; do
  timeout --kill-after=10s 180s env -u TEAQL_ALLOW_SENSITIVE_PLAINTEXT_LOGS -u TEAQL_SWIFT_TRACE_SCENARIO \
    swift run --jobs 2 --scratch-path "$scratch" --disable-build-manifest-caching \
    --force-resolved-versions TraceChainVerification "$trace_database" \
    2>&1 | tee "$trace_evidence/$round.log"
  rg -Fq 'PASS: Swift generated Checker accepted/rejected overlap 4 cases; callbacks serialized' "$trace_evidence/$round.log"
  rg -Fxq 'PASS Swift generated bootstrap intent: logging off/on, committed audit, repeat no writes' "$trace_evidence/$round.log"
  [[ "$(rg -c '^BOOTSTRAP INTENT ' "$trace_evidence/$round.log")" == 2 ]]
  rg -Fq 'PASS Swift generated ledger override: Payment replaces fallback; independent OrderItem inherits only root at command/SQL/audit' "$trace_evidence/$round.log"
  rg -Fq 'PASS FORWARD_NOTLOADED: generated Q/E keeps identity, hidden detail fails closed' "$trace_evidence/$round.log"
  rg -Fq 'PASS Swift graph identity controls: duplicate, missing and equal-ID type collapse rejected' "$trace_evidence/$round.log"
  [[ "$(rg -c '^GRAPH IDENTITY EVIDENCE ' "$trace_evidence/$round.log")" == 1 ]]
  rg -Fq 'PASS: Swift generated Trace Chain example' "$trace_evidence/$round.log"
done
hash_library > "$trace_evidence/generated-after.sha256"
cmp "$trace_evidence/generated-before.sha256" "$trace_evidence/generated-after.sha256"
echo "PASS: generated library unchanged; both starts use $trace_database"
echo "evidence retained: $trace_evidence"
