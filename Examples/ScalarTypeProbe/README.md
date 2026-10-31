# Generated scalar fixture: exact SQLite Decimal

Run from the runtime repository:

```bash
bash Examples/ScalarTypeProbe/verify.sh
```

The example depends on this repository's local runtime by default, not the public
`0.3.1` package. It ensures schema twice and uses generated Q, E, Checker and
audited Mutation APIs. Three rows containing `2`, `10`, and
`123456789012.3456789` check numeric ordering, exact equality and SUM/MIN/MAX.
Ordinary Unicode text containing NUL round-trips unchanged. E distinguishes
unselected Decimal from a loaded value. An optional Decimal alternates between
`0.10` and null while the row version advances to 2 then 3.

The script runs twice on one unique SQLite file without deleting it. It checks
the canonical model and nine generated Swift source hashes before and after
each run, retaining build logs and the database in its printed evidence directory.
Generation uses the evaluated local generator source recorded in
`fixture-manifest.json`, scope `swift-lib-core`, and canonical
`scalar_type_probe.xml`. The generator is
not needed to run the example. Change the model and regenerate if the frozen
library needs to change; `Package.swift`, the executable and this script are
application-owned.

The exact SQLite provider uses checked TEXT affinity, numeric collation and an
exact Decimal accumulator rather than SQLite floating SUM. Foundation Decimal
normalizes trailing zeroes: this profile preserves the numeric value, not its
original lexical scale. Unrepresentable sums fail instead of rounding. Decimal
AVG requires a precision policy and is rejected. This does not establish JSON
wire, all scalar edge classes, historical database migration or other providers.

`TEAQL_SCALAR_DB` selects a retained database when directly running the
executable. `TEAQL_SWIFT_SCRATCH_PATH` selects the script's shared build directory.
`TEAQL_SWIFT_RUNTIME_PATH` is an explicit override for a separately unpacked
local-source-archive consumer; normal examples keep using the repository. No
new version, registry upload or tag push is part of this example.

The same script runs `EmptyAggregateVerification` twice on a separate retained
SQLite file. Its eight approved empty-aggregate vectors cover COUNT(*) versus
COUNT(value), nullable SUM, a genuine zero, all related/facet buckets, an explicit
caller-only fallback, empty grouped results, and selected null in generated
entity JSON. COUNT(value) uses the public query carrier; the other filters,
aggregates, relations, facets, E reads and audited writes use generated APIs.
An exact Decimal control never converts the sum to floating point. Every
request is compared before/after execution. Reversible table-rename fault DDL
proves a real nested SQLite failure and recovery through the same query/context,
without treating business TraceChain as the physical SQL Trace Path. Business
data is never inserted or queried with hand-written SQL.

`Integer32Verification` adds 83 named checks per round on its own retained
SQLite file. Modeled Integer has a signed 32-bit domain while its native carrier,
Long, ID and version stay `Int64`. Generated saves reject out-of-range values
after custom Fix and before provider/transaction work; a single Fix may repair
an input. Generated hydration, JSON and E terminals reject invalid loaded values,
but omitted fields remain NotLoaded and optional null remains valid. A derived
SUM of `4294967294` is deliberately allowed rather than narrowed to Integer.
Eight valid rows per round are then corrupted through an explicitly test-only
external SQLite writer. Their real Q read fails precisely, an ID-only projection
still works, and the corrupt data/version remain available for a read-only
oracle. All ordinary rows and updates use generated audited Mutation APIs.
