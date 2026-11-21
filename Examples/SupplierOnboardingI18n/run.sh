#!/usr/bin/env bash
set -euo pipefail

example="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$example/../.." && pwd)"
export TEAQL_SWIFT_EXAMPLE_SOURCE_ROOT="${TEAQL_SWIFT_EXAMPLE_SOURCE_ROOT:-$repo}"
scratch="$(mktemp -d -t teaql-supplier-swift.XXXXXXXX)"
cleanup() {
  local status=$?
  trap - EXIT
  if ! rmdir -- "$scratch" 2>/dev/null; then
    python3 -c 'import shutil, sys; shutil.rmtree(sys.argv[1])' "$scratch"
  fi
  exit "$status"
}
trap cleanup EXIT
cp -R -- "$example/Package.swift" "$example/Sources" "$example/swift-lib-core" "$scratch/"
cp -- "$TEAQL_SWIFT_EXAMPLE_SOURCE_ROOT/Package.resolved" "$scratch/"
swift_flags=(--package-path "$scratch" --scratch-path "$scratch/build" --cache-path "$scratch/cache"
             --config-path "$scratch/config" --security-path "$scratch/security"
             --manifest-cache local --force-resolved-versions)
swift build "${swift_flags[@]}" --jobs "${TEAQL_SWIFT_JOBS:-2}" --product TeaQLConsole >&2
binary="$(swift build "${swift_flags[@]}" --show-bin-path)/TeaQLConsole"
driver=(python3 "$example/run-example.py" --catalog "$example/swift-lib-core/teaql-i18n.json")
cd -- "$scratch"
if [[ "${1:-}" == --verify ]]; then
  "${driver[@]}" --all --repeat 2 -- "$binary"
  "${driver[@]}" --edge-cases -- "$binary"
else
  "${driver[@]}" "$@" -- "$binary"
fi
