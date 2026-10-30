# Optional Blob image verifier

`TeaQLBlobReference` provides `StbImageBlobContentVerifier` for explicit host
installation in `SQLiteBlobUploadService`. It accepts `jpg`, `jpeg` and `png`
only; the host must separately permit the same extensions in `BlobFieldSpec`.
It reads all original bytes, checks complete JPEG/PNG containers and PNG CRCs,
preflights dimensions, decodes every pixel, then returns original-byte SHA-256
and actual MIME. Constructor limits bound input, decoded RGBA pixels and
concurrent admission. A failed verification cannot promote the catalog row.

The C decoder is confined to the optional `CStbImage` target. It vendors
`stb_image.h` v2.30 from official commit
`003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5` (SHA-256
`594c2fe35d49488b4382dbfaec8f98366defca819d916ac95becf3e75f4200b3`),
with its MIT/Public Domain dual-license text retained in the source. Only
JPEG and PNG decoders are compiled. The verifier is an in-process parser with
resource bounds, not a separate CPU-isolated worker. Other Blob formats still
need independent trusted production parsers; the PDF verifier in existing
SQLite/S3 tests is fixture-only.
