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
