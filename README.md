# TeaQL Swift

## Sensitive log data

Runtime diagnostic logs show expanded SQL, with masked parameters substituted
in place before delivery to files, console, buffers, or custom logging sinks.
Known ordinary fields remain visible; canonical fields in `EntityDescriptor.auditMaskFields`
use the shared mask algorithm. Credentials and unknown bindings are completely hidden.
Selecting a diagnostic sink alone does not authorize plaintext. For controlled troubleshooting only:

```bash
export TEAQL_ALLOW_SENSITIVE_PLAINTEXT_LOGS=I_UNDERSTAND_SENSITIVE_DATA_MAY_BE_WRITTEN_TO_DISK
```

Only this exact value enables plaintext permission; empty values, `true`, and
whitespace variants do not. Enabling it emits a warning. Credential-classified
fields and unknown bindings remain redacted. Each debug record carries
`DEBUG PLAINTEXT; EXPLICIT OPT-IN`; masked SQL is marked `MASKED; NOT REPLAYABLE`.
The flag does not force every sink to expose values.
SQL without reliable field/literal provenance may be suppressed and marked
`NOT REPLAYABLE`. Execution parameters and persisted business data are unchanged.

Do not put sensitive data in free-text comments or purpose declarations.
TeaQL cannot govern arbitrary application prints or independent driver loggers;
configure those separately. This setting does not erase older plaintext files.
Restrict access and retention when using plaintext diagnostics, then unset the
variable and restart processes when troubleshooting is complete.

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
try await context.ensureSchema(RuntimeModule(
  name: "OrderManagement", entities: [CustomerOrder.descriptor]))

let context = UserContext(
    actor: "current-user",
    queryExecutor: database,
    mutationExecutor: database,
    requestPolicy: RequestPolicy { query in
        // Inject trusted tenant and authorization policy here.
        query
    },
    mutationPolicyRegistry: mutationPolicyRegistry,
    mutationPolicyApprovalProvider: approvalProvider
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

`executeForList` accepts only `UserContext`. Runtime services, tenant/permission
policy, actor, application audit sink, and Mutation Policy are installed when
that trusted context is created. Dynamic or federated payloads cannot override
them. A non-empty comment and purpose are required for queries; every save
requires an audit reason.

Generated graph saves run Checker/Fix for every reachable mutation, freeze one
complete `MutationPlan`, and review it before the first provider mutation. An
explicit denial reaches neither SQLite nor a `FederalDataService`. A missing
customer policy or exact policy approval emits the stable
`MUTATION-POLICY-001` / `MUTATION-POLICY-002` warning and remains fail-open;
explicit denial and incomplete reviewed graphs fail closed. The same governance
snapshot is attached to every application audit event in the graph.

List queries have a default hard limit of 10,000 rows. Local application code may lower or override it through a query, but requests above the hard limit fail instead of loading an unsafe amount. The hard limit is never transported through federation. Most applications should keep the default unless a carefully reviewed local workload requires otherwise.

## Security Boundary

Swift's federation profile is a client. It sends bounded, governed requests to
a trusted TeaQL backend but cannot supply or override server tenant, role,
field, purpose, or optimistic-lock policy. Local SQLite remains application
storage; it does not make the device a public TFP server.

An opaque entity reference returned by a Java, Rust, Go, or .NET backend is an
indivisible transport value. Swift code must not parse, rewrite, log, or mint
it, and must not replace it with a raw internal ID/version pair. The current
Swift profile intentionally does not keep backend AES keys or expose local
opaque-reference encode/decode APIs. That is a supported client boundary, not a
runtime gap.

Database execution remains parameterized; diagnostic SQL is expanded after
field-aware masking, not a placeholder string plus an array. Plaintext for
masked business fields requires the explicit debug acknowledgement above.
The server-side envelope, shared golden vector, stable errors, and
development-only raw-reference acknowledgement are maintained in the canonical
[opaque entity reference contract](https://github.com/teaql/teaql-conformance/blob/main/design/opaque-entity-references.md).

## Generation and customization

The `swift-lib-core` scope in `teaql-code-gen` generates standard SwiftPM source: models, staged requests, `Q`, and package metadata. Generated files say `Do not edit directly`. Customize behavior by composing `UserContext`, `RequestPolicy`, `AuditSink`, transports, or application services—not by patching generated source.

Human/non-human predicate wording and plural names are produced by the generator's centralized rules, aligned with Java. For example: `people()`, `whoAreActive()`, `whoseEmailIs(...)`; non-human entities use forms such as `whichAreActive()`.

## Verify

### Local dynamic-search schema drift

`DynamicSearch.normalize(_:entity:models:maxClauses:warn:)` accepts a local UI
search envelope such as
`{"filter":{"name":{"$contains":"Campus"}},"orderBy":[{"field":"id","direction":"desc"}]}`.
`SearchModel` metadata must come from trusted application setup. Unknown fields
and relation paths remove the whole clause and return structured
`DYNAMIC_SEARCH_UNKNOWN_FIELD` warnings without submitted values. Warnings go to
stderr by default, or to the supplied logging callback.

`DynamicSearch.merge(_:source:models:filterBinding:orderBinding:warn:)` composes
native `TeaQLExpression` and `OrderBy` values with a copy of an already-scoped
query. It retains existing filters, ordering, limits and intent. Trusted bindings
must also preserve authorization inside related queries. Warnings are emitted
only after all validation and bindings succeed; the original query is unchanged.

Supported metadata types: `string`, `integer`, `number`, `boolean`, `date`
(`yyyy-MM-dd`), `timestamp` (integer epoch milliseconds), and `decimal` (use a
string for exact digits). Operators: `$eq`, `$ne`, `$gt`, `$gte`, `$lt`, `$lte`,
`$in`, `$notIn`, and string `$contains`. Limits default to 100 clauses, 16 path
segments and 1,000 IN-list values. Malformed input, invalid operators/types and
trusted-context injection remain errors. TFP stays strict. Automatic generated
bindings are not provided by this local adapter.

### Runtime and example gates

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
