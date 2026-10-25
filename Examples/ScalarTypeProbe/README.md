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
Generation used fixed local generator `6fbd9be2db64a3c315c247d24122dd8164db64e9`,
scope `swift-lib-core`, and canonical `scalar_type_probe.xml`. The generator is
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
