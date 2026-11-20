#!/usr/bin/env bash
set -euo pipefail
example="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${TEAQL_DISPATCH_PROFILE_EVIDENCE_DIR:-}" ]]; then
  evidence="$TEAQL_DISPATCH_PROFILE_EVIDENCE_DIR"
  mkdir "$evidence"
else
  evidence="$(mktemp -d -t teaql-swift-dispatch-profile.XXXXXXXX)"
fi
evidence="$(cd "$evidence" && pwd)"
scratch="$(mktemp -d -t teaql-swift-dispatch-build.XXXXXXXX)"
cleanup() {
  status=$?
  trap - EXIT
  rm -rf -- "$scratch" || { [[ "$status" != 0 ]] || status=1; }
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
target="${TEAQL_SWIFT_SCRATCH_PATH:-$scratch/target}"

for profile in camelCase snake_case PascalCase; do
  source="$example"
  if [[ "$profile" != camelCase ]]; then source="$example/profiles/$profile"; fi
  folder="$evidence/$profile"
  app="$source/swift-app-console"
  mkdir "$folder"
  model_profile="$(python3 -B -c 'import sys,xml.etree.ElementTree as xml; print(xml.parse(sys.argv[1]).getroot().attrib["json_field_naming"])' "$source/model.xml")"
  [[ "$model_profile" == "$profile" ]]
  diff -qr "$source/swift-lib-core/Sources/GeneratedTeaQL" "$app/Sources/GeneratedTeaQL"
  options=(--package-path "$app" --scratch-path "$target" --disable-build-manifest-caching --force-resolved-versions)
  swift package "${options[@]}" show-dependencies --format json > "$folder/dependencies.log" 2>&1
  swift build "${options[@]}" --jobs 2 --product TeaQLConsole > "$folder/build.log" 2>&1 || {
    tail -80 "$folder/build.log"
    exit 1
  }
  binary="$(swift build --package-path "$app" --scratch-path "$target" --show-bin-path)/TeaQLConsole"
  for phase in first restart; do
    "$binary" "$folder/dispatch.sqlite" "$model_profile" "$phase" | tee "$folder/$phase.log"
  done
done
TEAQL_GENERATED_E_PROFILE_EVIDENCE_DIR="${TEAQL_GENERATED_E_PROFILE_EVIDENCE_DIR:-$evidence/calibration}" node "$example/verify-local.cjs" | tee "$evidence/calibration.log"
