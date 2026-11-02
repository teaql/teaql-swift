# Local generated Q/E, Fix and graph-mutation example

Run `node Examples/FixEAlignment/verify-local.cjs` from this runtime checkout.
The consumer references this checkout's Core/SQLite products, not a published
runtime. The evaluated three-object model and generated implementations are
hash-bound by `fixture-manifest.json` and must not be hand edited.

The default executable checks BusinessClock Fix values, structured E failures,
loaded/NotLoaded/null JSON boundaries, mutation ownership and paging, partial
ancestors, active-root admission, and restoration of original values.

`ProjectionViewsProbe.swift` adds three independent-view regression scenarios:

1. A full query must not widen an earlier sparse view in the same Context.
2. Two complete views of one identity have separate pending mutation ledgers;
   saving one does not save the other. A stale second save must reject, roll
   back and retain pending business intent plus its exact successful clock Fix.
3. One query may encounter `Tenant#1` twice with different projections. The
   sparse outer view and complete nested alias keep their own E/JSON boundaries.

Both executions reuse one projection database without cleanup. The round number
comes from a bounded generated query: the first execution finds zero orders,
the second finds three. Business writes use generated audited saves only.
Provider, transaction, policy and audit observers are positively calibrated by
actual successful operations. Reading E/JSON must not perform provider work.

The generated native JSON also roundtrips the selected reverse/forward graph,
including sparse versus loaded-null and selected-empty versus NotLoaded.
Scalar FK input remains accepted when target detail is absent. Missing nested
identity, malformed nested scalars and malformed reverse rows reject with JSON
paths. Encoding cannot expose a loaded target whose ID does not match its FK.
No query metadata or pending mutation state is added by these JSON operations.

`UnchangedViewsProbe.swift` adds five Q/E/save scenarios to the same default
executable: a sparse selected-null forward view, an independent pending view,
an explicitly empty reverse list, and real transaction failures after UPDATE
and before COMMIT. Ten side-effect observers are positively calibrated. The
three no-op saves perform no provider/transaction/Fix/policy/audit/clock work;
selected readonly count zero and absent aliases keep their distinct presence.
Rollback must retain geometry, the original optimistic baseline and business
plus managed Fix intent. Retry uses the same Swift value and ledger without
requerying. A genuine commit returns a new authoritative value/graph, advances
both committed baselines and clears the old derived count. The returned graph
is not required to reuse the input ledger's memory address.

The provider delegates to real SQLite before either fault. A separate readonly
CSQLite connection checks persisted values and Business Clock timestamps; all
business writes still use generated audited saves. Each scenario has a separate
SQLite file, reused in the second execution without cleanup. This does not
establish persistent dynamic fields, typed dynamic schemas, public enclosing
transactions, performance or all-provider conformance.

Set `TEAQL_FIX_E_EVIDENCE_DIR` to a new absolute directory to retain compact
receipts, logs and synthetic stores. Task-owned build/dependency scratch is
removed on exit after child processes finish; shared caches are not deleted.
These are regression expectations, not a claim that an unexecuted candidate
passes. Conformance source/private-artifact acceptance is recorded separately.

`ExpressionBoundaryProbe.swift` runs twelve actual generated E cases in this
default two-round gate. Bounded Q and audited Save prepare complete, sparse,
FK-only and loaded-empty views. Late/indexed/first missing leaves, size operations,
null/absence, all three generated value/presence/fallback terminals, same-root
sibling isolation and repeated relation names retain the complete redacted error
chain. Ten provider/transaction/Fix/policy/audit boundaries are first positively
calibrated, then stay unchanged during E. JSON geometry, pending intent and ledger
identities are checked without exporting the graph. Generated code is unchanged;
the probe's ledger reads are test instrumentation, not application API guidance.

`CheckerBoundaryProbe.swift` adds omitted required relations, four independently
omitted business fields with ownership loaded, unchanged partial targets, and
real customer Fix rejection/repair. A separate store installs module Checkers
without schema creation. The public object-local JSON adapter plus explicit
generated setters tests declared aliases, escaped pointers, unknown fields and
equal/unequal collisions under three naming profiles. Swift dictionaries do not
promise submitted-key order: a collision must identify an actual submitted leaf.
The default verifier retains 33 observations per unreset round and three stores;
generated implementations stay hash-bound. This is not recursive HTTP/TFP or
installed-package acceptance.

The observed module also verifies bootstrap uses the injected Business Clock.
`UserContext._generatedBootstrapContext` preserves the configured policy registry,
approval provider and governance sink through a fresh coordinator; it must not
reset to an allowing default or import an already-reviewed caller plan. Native
positive/negative controls cover time, approval, denial, sink delivery and state
isolation. The generated bootstrap source is unchanged.
The third store exercises the actual generated `ensureSchema` program with a
rejecting customer policy: DDL is allowed, but no root data or audit is committed.
