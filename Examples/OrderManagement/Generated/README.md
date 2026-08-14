# polyglot-order-search-service Swift Core

This package is generated from the TeaQL model. Do not edit files under
`Sources/GeneratedTeaQL`; update the model, generator, or `teaql-swift` runtime
and regenerate.

Queries accept exactly one runtime argument, `UserContext`, and become
executable only after both `comment` and `purpose` are supplied. Mutations use
`entity.auditAs("reason").save(context)`.

List queries are protected by a 10,000-row hard limit. Application code may
lower it with `hardLimit(...)`; the value is local runtime policy and is never
sent through federation. Most applications should keep the default unless a
special workload has been reviewed carefully.