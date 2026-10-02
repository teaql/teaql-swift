#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="${TEAQL_SWIFT_SCRATCH_PATH:-$repo/.build}"
evidence="$(mktemp -d /tmp/teaql-swift-batch-api-XXXXXX)"
cd "$repo"
bin="$(swift build --scratch-path "$scratch" --show-bin-path)"
flags=(-typecheck -I "$bin/Modules" -I "$repo/Sources/CSQLite")
swiftc "${flags[@]}" Tests/Fixtures/ValidatedMutationBatch.swift
if swiftc "${flags[@]}" Tests/Fixtures/BareMutationArray.swift >"$evidence/rejected.log" 2>&1; then
  echo 'FAIL: bare provider transaction array still compiles' >&2
  exit 1
fi
if ! rg -q "has no member 'transaction'" "$evidence/rejected.log"; then
  echo 'FAIL: negative compile failed for a different reason' >&2
  sed -n '1,80p' "$evidence/rejected.log" >&2
  exit 1
fi
echo "PASS: validated Context batch compiles; bare provider array rejected; evidence retained: $evidence"
