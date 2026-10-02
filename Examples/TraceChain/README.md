# Generated SQLite Trace Chain verification

This example starts at an evaluated six-entity KSML model and the generated
Mutation, Q and E APIs. It observes real mutation requests, physical SQLite
metadata and committed application audit events. The generated library is not
read for API discovery, hand-edited, or supplied with fabricated graph scopes.

## Run against this checkout

```bash
bash Examples/TraceChain/verify.sh
```

The script runs the executable twice on **one retained SQLite file**, compares
all sixteen generated Swift source files and the local dependency manifest,
and leaves the database and evidence directory in place. To reuse a file:

```bash
bash Examples/TraceChain/verify.sh /absolute/path/trace.sqlite
```

Set `TEAQL_SWIFT_SCRATCH_PATH` to select an isolated build directory. Both
manifests depend on the runtime source in this repository, not a public release.
The model's version override does not turn this source test into package proof.
No public package is claimed to contain these changes.

## Verified behavior

| Check | Observed boundary |
| --- | --- |
| Required intent | Blank graph comment and missing Query comment cause no transaction start, mutation, SQL log or committed audit |
| Normative six mutations | Root, unannotated child, locally annotated Payment and Shipment, inherited PaymentAttempt and locally annotated deletion retain separate typed lineage at command, SQL and audit boundaries |
| Three-level generated Q/E | PaymentAttempt → Payment → CustomerOrder → Platform; all four statements retain root intent and logical relation names, independent of hydration aliases |
| Late allocation | Newly allocated root/Payment IDs replace temporary scope identities in physical SQL metadata and committed audits; grandchild inherits the assigned ancestors |
| Ledger replacement | A typed per-Payment complete chain replaces graph fallback, rather than concatenating the two |
| Same numeric ID | CustomerOrder and Payment keep distinct versions 2/1, update successfully, and retain their own typed lineages |
| Concurrent graphs | Overlapping Tasks reuse one Context while its provider serializes transactions; graph reasons do not cross branches |
| Actual child SQL failure | Duplicate Payment ID raises SQLite UNIQUE; preceding parent statement remains successful, failed child retains lineage, graph rolls back and emits no committed audit |
| Rejected write readback | A test-only SQLite trigger removes the inserted Payment; two writes succeed but a zero-row SELECT fails persisted-snapshot acceptance; both write paths and a separate SELECT survive, while the graph rolls back |

The first clean-database graph uses Order#100, OrderItem#201/#202,
Payment#301, PaymentAttempt#401 and Shipment#501. The actual model names
the root `CustomerOrder`. Later starts select a new ID range using bounded
generated Q; they repeat the same topology without deleting previous rows,
soft-deleted children, row audits or fault triggers. The seeded Platform#1 is
reused, and ensureSchema is explicitly called twice.

The Rust-canonical rebuilt SQL route intentionally has no Entity ID. The
example associates each successful physical statement with its real emitted
command by execution index and entity type, then checks its own typed lineage
and the independently captured audit. It does not insert an ID into the route.

The command observer delegates unchanged to SQLite. Fault probes use a separate
Context with the native SQLite provider, preserving its package-only failure
diagnostic handoff. The only handwritten SQL creates a narrowly scoped fault
trigger; no business query, seed or mutation is expressed in application SQL.

## Producer and API discovery

The original model, generated application `AGENTS.md`, evaluation and only the
needed entity/action/field Assist are retained alongside this example.
`SwiftTraceChainExampleGenerationTest` in Model-Aware Services regenerates the
entire library and current Assist and repoints only its dependency manifest to
local source. Never patch `Generated/Sources` to repair a test.

## Remaining scope

This is local generated acceptance, not immutable Registry consumer replay.
Prepared batches, all low-level/request-decoding entry points, complete privacy
coverage, persisted audit-row privacy/lineage, successful-readback diagnostic
events, cancellation and independent-Context/shared-provider coordination still
need their own gates. A zero-row SELECT here is successful SQL with rejected
snapshot validation, not a simulated SQL driver error or a COMMIT failure.
