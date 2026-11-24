# Order list with item previews and status totals

A retailer pages through its orders by order date and checks the selected
paid order, the first three products, the full five-item count and the
status totals. The same business filter drives the list and facet totals.
It matches three orders and excludes one unrelated order per launch.
The empty status has a zero count and a null sum.

`model.xml` owns the customer, order, status and item definitions.
`swift-lib-core` retains the generated domain library. The generated domain
target in `swift-app-console` builds with the local runtime. The workspace
installs standard telemetry at startup and assembles a SQLite-backed Context
for audited writes and generated Q/E reads.

Run `bash Examples/TraceChain/verify-standard-order.sh` from the repository root.
The two launches share one SQLite file. The verifier checks initial schema
audits, no repeated seed writes, order membership, child previews, exact counts,
facets and audited writes. The standard launcher accepts `--enabled` when the
three trusted telemetry settings are supplied.
