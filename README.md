# TeaQL Swift

TeaQL's Swift 6 runtime brings generated, governed data access to macOS, iOS, and Linux. This first version supports local SQLite applications and the TeaQL Federal Protocol client, allowing a Swift client and a server in another TeaQL language to share the same domain model.

## Recommended Agent Harness

When building SQLite-backed or federated applications with the TeaQL Swift
runtime, we recommend using it together with the [TeaQL Agent Kit](https://github.com/teaql/teaql-agent-kit).
The Agent Kit is TeaQL's continuously evolving **Harness Engineering** method.
It gives coding agents a model-mediated, executable workflow for domain
modeling, deterministic evaluation and repair, code generation, implementation,
and evidence-based verification as the generator and runtimes evolve.

## Quick start

Requirements: Swift 6 and SQLite development headers (`libsqlite3-dev` on Ubuntu or `sqlite3` with Homebrew).

```swift
let database = try SQLiteDataService(path: "app.sqlite")
try await database.ensureSchema([CustomerOrder.descriptor])

let context = UserContext(
    actor: "current-user",
    queryExecutor: database,
    mutationExecutor: database,
    requestPolicy: RequestPolicy { query in
        // Inject trusted tenant and authorization policy here.
        query
    }
)

let orders = try await Q.customerOrders()
    .withOrderNumberContaining("SWIFT")
    .comment("Order browser search")
    .purpose("Show matching orders")
    .executeForList(context)
```

Run the complete [Order Management example](Examples/OrderManagement/README.md):

```bash
swift run teaql-order-management
```

It creates its SQLite file and schema automatically, seeds one audited order, runs a generated request, and shows the immutable row-audit count. No model tool or database server is needed for this first run.

## Packages

- `TeaQLCore`: values, metadata, typed query state, `UserContext`, governance, and audit contracts.
- `TeaQLSQL`: parameterized SQL compilation and the 10,000-row hard limit.
- `TeaQLSQLite`: schema ensure, query, transaction, save, optimistic locking, and immutable row audit.
- `TeaQLFederal`: real TFP query and audited mutation client over an injectable HTTP transport.
- `TeaQLTestSupport`: isolated SQLite and recording audit helpers.

## Governance

`executeForList` accepts only `UserContext`. Runtime services, tenant/permission policy, actor, and application audit sink are installed when that trusted context is created. Dynamic or federated payloads cannot override them. A non-empty comment and purpose are required for queries; every save requires an audit reason.

List queries have a default hard limit of 10,000 rows. Local application code may lower or override it through a query, but requests above the hard limit fail instead of loading an unsafe amount. The hard limit is never transported through federation. Most applications should keep the default unless a carefully reviewed local workload requires otherwise.

## Generation and customization

The `swift-lib-core` scope in `teaql-code-gen` generates standard SwiftPM source: models, staged requests, `Q`, and package metadata. Generated files say `Do not edit directly`. Customize behavior by composing `UserContext`, `RequestPolicy`, `AuditSink`, transports, or application services—not by patching generated source.

Human/non-human predicate wording and plural names are produced by the generator's centralized rules, aligned with Java. For example: `people()`, `whoAreActive()`, `whoseEmailIs(...)`; non-human entities use forms such as `whichAreActive()`.

## Verify

```bash
swift test
```

The live Swift-to-Rust federation test is enabled when `TEAQL_TFP_BASE_URL` points to the deterministic test endpoint:

```bash
TEAQL_TFP_BASE_URL=http://127.0.0.1:18787 swift test \
  --filter liveSwiftToRustTFPQueryAndAuditedMutation
```

## Status

Swift 6.3 is tested on Linux. GitHub Actions also compiles and tests on macOS. SQLite and the TeaQL Federal Protocol client are the supported first-version providers; additional server databases remain available through federation.
