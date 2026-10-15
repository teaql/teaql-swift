# Context owned object storage

Tracking: [Swift #42](https://github.com/teaql/teaql-swift/issues/42),
[shared contract #122](https://github.com/teaql/teaql-conformance/issues/122).

TeaQLCore defines typed storage values, the context facade and provider SPI.
The separate `ObjectStorageS3` package provides `TeaQLObjectStorageS3` using
SotoS3 7.17.0. The application configures and owns a shared AWSClient/S3 service
at trusted startup, including credentials/refresh, endpoint and timeouts, and
shuts that client down at application exit. No SDK dependency enters TeaQLCore.

```swift
import TeaQLCore
import TeaQLObjectStorageS3

let provider = try S3ObjectStorage(service: s3, bucket: "attachments")
let storage = try context.withObjectStorage(provider)
  .objectStorage("store payment receipt attachment")
let key = try ObjectKey("receipts/opaque-reference.pdf")
let options = try ObjectPutOptions(size: contentLength, mode: .createOnly)
let metadata = try await storage.put(key, content: source, options: options)
let link = try await storage.getReadUrl(key)
let response = try await storage.get(key)
let block = try await response.reader.read(upToCount: 65536)
try await response.close()
```

`ObjectByteReader` is a Sendable asynchronous bounded reader; empty Data is EOF.
Consume each reader serially and close it. Upload readers are closed on every
exit. Staging uses private directory/file permissions, bounded chunks, exact
length validation and a 5 GiB single-PUT limit. The SDK file sequence can reopen
the body for replay. Downloads use a bounded reader over the SDK's body sequence,
including cancellation/release on close. `getBytes(maximumBytes:)` imposes an
explicit memory ceiling. Create-only is atomic; replacement is explicit.

Denied/unavailable/timeout responses never become false absence. Keys remain
durable while default five-minute read URLs are reusable bearer links, subject
to earlier credential/policy expiry. URLs do not prove existence or grant domain
permission. SDK SigV4 signs the configured endpoint and encoded object path;
URLs are not rewritten afterward. Metadata/key/URL descriptions are masked and
operation events carry only comment, outcome, duration and opaque Context identity.
Native telemetry records opening/reading phases, while the lifecycle event
records completion at EOF or early close. Storage effects do not join SQL saves.

Set `TEAQL_S3_ENDPOINT`, `TEAQL_S3_BUCKET`, `TEAQL_S3_ACCESS_KEY`,
`TEAQL_S3_SECRET_KEY` for a dedicated fixture, then run
`bash Examples/ObjectStorage/verify.sh` twice. The native SDK error test uses a
small loopback Python 3 HTTP fixture. The live example depends on local packages,
provisions its test bucket if absent, uses unique keys and deletes only those
keys; the production provider never creates buckets. The optional SDK and its
example share build cache to avoid redundant dependency compilation. AWS,
Apple platforms and other compatible servers need separate qualification.
Multipart/list/copy/range and signed upload are future extensions.
