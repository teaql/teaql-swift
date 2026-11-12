#!/usr/bin/env bash
set -euo pipefail
example="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$example/../.." && pwd)"
if [[ $# -gt 1 ]]; then echo 'usage: bash verify.sh [retained-sqlite-path]' >&2; exit 2; fi
evidence_parent="${TEAQL_EXAMPLES_EVIDENCE_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$evidence_parent"
trace_evidence="$(mktemp -d "$evidence_parent/teaql-swift-generated-trace-evidence-XXXXXX")"
echo "Swift TraceChain compact evidence: $trace_evidence"
if [[ $# -eq 1 ]]; then
  trace_database="$1"
else
  trace_database="$trace_evidence/trace.sqlite"
fi
scratch="${TEAQL_SWIFT_SCRATCH_PATH:-$repo/.build}"
cd "$example"
hash_library() {
  find Generated/Sources -type f -name '*.swift' -print0 | sort -z | xargs -0 sha256sum
  sha256sum Generated/Package.swift
}
finish() {
  result=$?
  trap - EXIT
  # Databases, generated hashes and logs are compact retained evidence, not
  # disposable builds. Caller-owned build scratch is cleaned by its owner;
  # never remove a shared .build directory from this script.
  if hash_library > "$trace_evidence/generated-after.sha256"; then
    if ! cmp "$trace_evidence/generated-before.sha256" "$trace_evidence/generated-after.sha256"; then
      if [[ "$result" -eq 0 ]]; then result=1; fi
    fi
  elif [[ "$result" -eq 0 ]]; then result=1
  fi
  printf 'exit=%s\n' "$result" > "$trace_evidence/result.txt"
  echo "Compact TraceChain evidence retained: $trace_evidence (exit=$result)"
  exit "$result"
}
trap finish EXIT
hash_library > "$trace_evidence/generated-before.sha256"
node --test "$repo/Examples/TraceChain/verify-checker-observation.test.cjs"
for round in first second; do
  timeout --kill-after=10s 180s env -u TEAQL_ALLOW_SENSITIVE_PLAINTEXT_LOGS -u TEAQL_SWIFT_TRACE_SCENARIO \
    swift run --jobs 2 --scratch-path "$scratch" --disable-build-manifest-caching \
    --force-resolved-versions TraceChainVerification "$trace_database" \
    2> "$trace_evidence/$round.stderr.log" | tee "$trace_evidence/$round.log"
  rg -Fq 'PASS: Swift generated Checker isolation v2: accepted-first overlap; rejected-first before BEGIN; 4 cases' "$trace_evidence/$round.log"
  node "$repo/Examples/TraceChain/verify-checker-observation.cjs" "$trace_evidence/$round.log"
  rg -Fxq 'PASS TC-MUT-12 Swift shared readonly: forced public overlap, one BEGIN while paused, command/SQL/audit isolated' "$trace_evidence/$round.log"
  rg -Fxq 'PASS Swift generated bootstrap intent: logging off/on, committed audit, repeat no writes' "$trace_evidence/$round.log"
  [[ "$(rg -c '^BOOTSTRAP INTENT ' "$trace_evidence/$round.log")" == 2 ]]
  rg -Fq 'PASS Swift generated ledger override: Payment replaces fallback; independent OrderItem inherits only root at command/SQL/audit' "$trace_evidence/$round.log"
  [[ "$(rg -c '^ASSIGNED_IDENTITY_OBSERVED ' "$trace_evidence/$round.log")" == 2 ]]
  for logging in false true; do
    rg -Fxq "PASS assigned identity logging=$logging: actual command/SQL/audit, unannotated sibling and independent Q/E reload" "$trace_evidence/$round.log"
  done
  rg -Fq 'PASS FORWARD_NOTLOADED: generated Q/E keeps identity, hidden detail fails closed' "$trace_evidence/$round.log"
  rg -Fq 'PASS Swift graph identity controls: duplicate, missing and equal-ID type collapse rejected' "$trace_evidence/$round.log"
  [[ "$(rg -c '^GRAPH IDENTITY EVIDENCE ' "$trace_evidence/$round.log")" == 1 ]]
  rg -Fq 'PASS: Swift generated Trace Chain example' "$trace_evidence/$round.log"
  [[ "$(rg -c '^PASS Swift generated aggregate membership:' "$trace_evidence/$round.log")" == 8 ]]
  [[ "$(rg -c '^AGGREGATE_OBSERVED ' "$trace_evidence/$round.log")" == 8 ]]
  [[ "$(rg -c '^PASS Swift complete private lineage:' "$trace_evidence/$round.log")" == 4 ]]
done
hash_library > "$trace_evidence/generated-after.sha256"
cmp "$trace_evidence/generated-before.sha256" "$trace_evidence/generated-after.sha256"
echo "PASS: generated library unchanged; both starts use $trace_database"
echo "evidence retained: $trace_evidence"
