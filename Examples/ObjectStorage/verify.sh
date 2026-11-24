#!/usr/bin/env bash
set -euo pipefail
example="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$example/../.." && pwd)"
: "${TEAQL_S3_ENDPOINT:?dedicated local test endpoint required}"
: "${TEAQL_S3_BUCKET:?dedicated test bucket required}"
: "${TEAQL_S3_ACCESS_KEY:?test access key required}"
: "${TEAQL_S3_SECRET_KEY:?test secret key required}"
scratch="${TEAQL_SWIFT_SCRATCH_PATH:-$repo/ObjectStorageS3/.build}"
if [[ -n "${TEAQL_ORDER_ATTACHMENT_EVIDENCE_DIR:-}" ]]; then
  evidence="$TEAQL_ORDER_ATTACHMENT_EVIDENCE_DIR"
  mkdir -p "$(dirname "$evidence")"
  mkdir "$evidence"
else
  evidence="$(mktemp -d -t teaql-swift-order-attachment.XXXXXXXX)"
fi
evidence="$(cd "$evidence" && pwd)"
# Keep the runtime log out of the source tree covered by fingerprint().
export TEAQL_LOG_ENDPOINT="$evidence/runtime.log"
fingerprint() {
  (cd "$example" && find swift-lib-core swift-app-console -type f -not -path '*/.build/*' -print0 | sort -z | xargs -0 sha256sum)
}
fingerprint > "$evidence/source-before.sha256"
cd "$repo"
flags=(--jobs 2 --scratch-path "$scratch" --disable-build-manifest-caching --force-resolved-versions)
swift test "${flags[@]}" --filter ObjectStorageTests 2>&1 | tee "$evidence/runtime-tests.log"
(cd ObjectStorageS3 && swift test "${flags[@]}") 2>&1 | tee "$evidence/provider-tests.log"
cd "$example/swift-app-console"
swift build "${flags[@]}" > "$evidence/workspace-build.log" 2>&1
swift package --scratch-path "$scratch" --force-resolved-versions show-dependencies --format json > "$evidence/origins.log" 2>&1
"$scratch/debug/S3LifecycleCalibration" | tee "$evidence/s3-calibration.log"
for round in 1 2; do
  "$scratch/debug/TeaQLConsole" "$evidence/orders.sqlite" "$evidence/receipt-$round.txt" "$round" |
    tee "$evidence/run-$round.log"
done
fingerprint > "$evidence/source-after.sha256"
cmp "$evidence/source-before.sha256" "$evidence/source-after.sha256"
printf 'Order attachment evidence retained at %s\n' "$evidence"
