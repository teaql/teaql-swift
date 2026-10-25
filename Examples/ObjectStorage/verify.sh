#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${TEAQL_S3_ENDPOINT:?dedicated local test endpoint required}"
: "${TEAQL_S3_BUCKET:?dedicated test bucket required}"
: "${TEAQL_S3_ACCESS_KEY:?test access key required}"
: "${TEAQL_S3_SECRET_KEY:?test secret key required}"
cd "$repo"
scratch="${TEAQL_SWIFT_SCRATCH_PATH:-$repo/ObjectStorageS3/.build}"
swift test --jobs 2 --scratch-path "$scratch" --filter ObjectStorageTests --disable-build-manifest-caching
# Sequential compatible builds reuse the caller's owned scratch without
# deleting any shared cache or retaining an extra SDK build per example.
(cd ObjectStorageS3 && swift test --jobs 2 --scratch-path "$scratch" --disable-build-manifest-caching)
(cd Examples/ObjectStorage && swift run --jobs 2 --scratch-path "$scratch" --disable-build-manifest-caching ObjectStorageExample)
