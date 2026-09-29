# runtime-example-conformance-service Swift Core

The runtime-owned `MaskingVerification.swift` fixture also executes SQLite CRUD
and checks expanded SQL, canonical-to-column field masking, visible ordinary
fields, protected credentials, original persisted values, and the query log switch.
It also injects a SQLite trigger to reject a post-write snapshot and verifies
separate write/readback diagnostics, inherited audit-intent masking, partial
graph rollback, and connection reuse. SQL success is not transaction acceptance.
It is separate from the generated domain library; generator metadata propagation
needs its own verification. Run `bash scripts/verify-examples.sh` from the runtime
repository with the plaintext-debug environment variable unset.

This package is generated from the TeaQL model. Do not edit files under
`Sources/GeneratedTeaQL`; update the model, generator, or `teaql-swift` runtime
and regenerate.

Queries accept exactly one context argument, `UserContext`, and become
executable only after both `comment` and `purpose` are supplied. Mutations use
`entity.auditAs("reason").save(context)`.

List queries are protected by a 10,000-row hard limit. Application code may
lower it with `hardLimit(...)`; the value is local runtime policy and is never
sent through federation. Most applications should keep the default unless a
special workload has been reviewed carefully.
