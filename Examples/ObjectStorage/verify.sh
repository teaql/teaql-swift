#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${TEAQL_S3_ENDPOINT:?dedicated local test endpoint required}"
: "${TEAQL_S3_BUCKET:?dedicated test bucket required}"
: "${TEAQL_S3_ACCESS_KEY:?test access key required}"
: "${TEAQL_S3_SECRET_KEY:?test secret key required}"
cd "$repo"
swift test --jobs 2 --filter ObjectStorageTests --disable-build-manifest-caching --force-resolved-versions
# The SDK and the live consumer share their own scratch directory.
scratch="$repo/ObjectStorageS3/.build"
(cd ObjectStorageS3 && swift test --jobs 2 --scratch-path "$scratch" --disable-build-manifest-caching --force-resolved-versions)
(cd Examples/ObjectStorage && swift run --jobs 2 --scratch-path "$scratch" --disable-build-manifest-caching --force-resolved-versions ObjectStorageExample)
