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
| Successful write readbacks | Each persisted mutation produces ordered write/SELECT facts; six graph changes mean twelve physical SQL entries but only six committed audits. SELECT keeps the originating root and per-item lineage, with a query/request path and derived purpose |
| Three-level generated Q/E | PaymentAttempt → Payment → CustomerOrder → Platform; all four statements retain root intent and logical relation names, independent of hydration aliases |
| Late allocation | Newly allocated root/Payment IDs replace temporary scope identities in physical SQL metadata and committed audits; grandchild inherits the assigned ancestors |
| Ledger replacement | A typed per-Payment complete chain replaces graph fallback, rather than concatenating the two |
| Same numeric ID | CustomerOrder and Payment keep distinct versions 2/1, update successfully, and retain their own typed lineages |
| Concurrent graphs | Overlapping Tasks reuse one Context while its provider serializes transactions; graph reasons do not cross branches |
| Accepted/rejected Checker overlap | Real generated Required rejects an unnamed child while the other graph alone updates its root/child; both logging modes and invocation orders preserve independent ledgers, a shared readonly snapshot, and following-save isolation |
| Shared read-only references | One bounded two-root Q query shares an actual immutable Platform snapshot reference while root and forward-reference wrappers retain independent mutation ledgers; two overlapping saves issue only two root UPDATEs using versions 2/1 |
| Scoped child adoption | Only the reached changed child is imported and written; foreign-root and sibling pending values remain in their original ledger, and Q/E verifies the changed FK |
| Clean ancestors | Saving a clean parent writes only its changed descendant; its root reason is retained in the child lineage, while the parent version remains unchanged |
| Mixed loaded versions | Two independently loaded versions of one child reject before business SQL, committed audit or policy review; both pending values survive |
| Generated paginated graphs | Offset 1 / limit 2 returns two independent roots with versions 2/1 from a three-root filtered set; saving one leaves the other's changes pending and unpersisted |
| Pagination and descendant lineage | Row, forward/reverse relation and exact-count SQL inherit one page comment/purpose; a clean paginated parent saves only its changed child with root/local responsibility |
| Actual child SQL failure | Duplicate Payment ID raises SQLite UNIQUE; preceding parent statement remains successful, failed child retains lineage, graph rolls back and emits no committed audit |
| Rejected write readback | A test-only SQLite trigger removes the inserted Payment; two writes and the root readback succeed, but the child's zero-row SELECT fails persisted-snapshot acceptance; all four facts survive while the graph rolls back |

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

`SharedReferences.swift` uses a customer Mutation Policy to observe the actual
reviewed operations, not only emitted writes. Hydration cannot invent a pending
create or policy operation for a read-only reference. Its four
`OWNERSHIP_OBSERVED` JSON records retain real commands, optimistic versions,
SQL paths, per-entity lineage, audits and reviewed plans. A local fixture policy
without approval still produces the normal governance warning.

The runtime's query-scoped `LoadedEntitySnapshots` pool reuses only equal
records with the same typed identity and version. Different projections and
versions remain separate; the pool is never stored on `UserContext` and contains
no pending mutations. Swift value-copy access cannot modify its immutable stored
record. Generated scalar and Q/E APIs remain unchanged. Independent transactions
serialize at the existing Context gate; this is not parallel SQLite writers.

For only the four real generated Checker overlap cases, run
`bash Examples/TraceChain/verify-checker-overlap.sh [retained-sqlite-path]`.
Set `TEAQL_SWIFT_CHECKER_EVIDENCE` for the logs/fingerprints directory and
`TEAQL_SWIFT_SCRATCH_PATH` for the build cache. The script runs twice without
cleanup and removes inherited plaintext-log opt-in. The full verifier includes
these cases and ignores the focused selector.
Both verifier scripts require GNU `timeout`: each invocation has a 180-second
deadline with a 10-second termination grace period; timeout preserves the log
and fails the script rather than hanging on an actor rendezvous.

`CheckerOverlapProofs.swift` pauses the first real BEGIN while two public saves
remain outstanding; the existing Context gate serializes transactions and
Checker callbacks. Generated checkers are installed unchanged, with no fake
results. The rejected graph reaches no mutation-provider command or business
SQL metadata, but its transaction begins and rolls back. Raw successful SQL
bindings retain the private child value; safe telemetry/diagnostics mask it.
Committed audits are checked against an already successful COMMIT. Q/E confirms
the rejected database graph and shared Platform remain unchanged. A subsequent
independent save preserves its own lineage, including a formerly private word
now unrelated to its fields. This is not simultaneous Checker execution or a
claim of zero transaction-control SQL.

`PaginationProofs.swift` uses current list-page Assist and generated Q/E/save.
Its four `PAGE_OBSERVED` records retain real physical SQL (including COUNT),
mutation commands, reviewed plans and committed audits. SQLite's current
AlwaysProbe policy emits one row SELECT, two bounded Platform probes, two child
probes and one exact-count SELECT for the initial page. Sharing immutable loaded
records is not a promise to deduplicate physical relation queries. The count
uses the full active filter without the page's offset/limit. Native SQLite
tests also retain count failure diagnostics, descendant-value redaction and
isolation of redaction provenance between independent requests.

## Producer and API discovery

The original model, generated application `AGENTS.md`, evaluation and only the
needed entity/action/field Assist are retained alongside this example.
`SwiftTraceChainExampleGenerationTest` in Model-Aware Services regenerates the
entire library and current Assist and repoints only its dependency manifest to
local source. Never patch `Generated/Sources` to repair a test.

## Remaining scope

This is local generated acceptance, not immutable Registry consumer replay.
Generated list and page ownership have executed coverage; stream ownership is
not proved by the page test.
Prepared batches, all low-level/request-decoding entry points, complete privacy
coverage, persisted audit-row privacy/lineage,
cancellation and independent-Context/shared-provider coordination still
need their own gates. A zero-row SELECT here is successful SQL with rejected
snapshot validation, not a simulated SQL driver error or a COMMIT failure.
