# Generated scalar fixture: exact SQLite Decimal

`BooleanBoundaryVerification` additionally verifies generated Boolean Q/E,
true/false/unknown, and COUNT aliases that resemble modeled fields. It runs twice
without resetting `boolean.sqlite`. A clearly labeled negative-test UPDATE
injects INTEGER `2` into one separate legacy row; selecting that field must fail
with `invalid_type` and `/requiredBoolean`, while ID-only queries still succeed
and E reports NotLoaded. Ordinary seeds use generated audited Mutation APIs.
The runtime also rejects non-Boolean mutation carriers before provider execution
and validates custom Fix results before publishing them into the ledger.

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

`TombstoneVerification` runs six cases twice on one additional retained SQLite
database. Generated Q/E and audited Save exercise ordinary soft deletion,
trigger-authored version/text/null/temporal values, commit failure followed by
retry of the same deletion intent, and rejection of repeated deletion before
clock, policy or provider calls. Explicit provider transactions separately test
commit and rollback/retry without pretending they deliver Context audit events.
The recovery control restores visibility and rejects versionless deletion.
`MutationResult.generatedValues` must agree with the transaction's actual
`persistedRecord`, including trigger-authored versions. CSQLite is used only for
trigger injection and the independent read-only storage/audit oracle. This does
not establish physical delete or caller-owned transactions around generated
Save. No generated implementation is edited.

`ScalarRoundtripVerification` exercises all 21 scalar fields through generated
Mutation/Q/E and native Codable. It covers ASCII/Unicode/NUL text (including a
large text), empty string versus null, Boolean states, Integer boundaries and
zero, Long above JavaScript's safe-number range and `Int64.min`, exact positive
and negative Decimal values, finite positive/negative Float/Double, leap and
ordinary dates, fractional wall-clock time, and an offset-normalized instant.
All nullable families are populated then cleared; complete native JSON can be
saved again, but a modified incomplete projection is rejected before provider,
clock or audit activity. Each of 24 nonfinite create/update cases rejects before
provider I/O. The script runs twice on one retained `roundtrip.sqlite`.

The current Swift carrier profiles are explicit: Time is a String and modeled
Float uses a Double carrier. Native Codable retains exact Swift Int64/Decimal
values; this is not a JavaScript-number-safe or TFP wire guarantee, a binary32
native-carrier guarantee, or acceptance of the complete scalar workstream.

Dynamic Date search uses the same executable and frozen library. Both canonical
and native field aliases exercise equality, comparisons, IN/NOT IN, nulls,
schema-drift warnings, invalid dates, request immutability and preserved trusted
identity scope. DateTime controls retain exact milliseconds. Every round now
contains 522 named checks, including 178 dynamic Date/DateTime checks, plus the
same 24 nonfinite rejection vectors. This local search path is not TFP.

`DynamicDecimalVerification` uses that same frozen generated library, a separate
retained SQLite file and the generated audited Mutation/Q/E APIs. Four exact
values include `0.1`, a 38-digit coefficient, `10^80`, and the rounded value that
an invalid 59-digit search used to match incorrectly. Each round has 116 checks:
20 positive storage/query checks and 96 rejected predicates across two aliases,
eight operators, positive/negative/fractional inputs, and quoted/raw JSON.
Rejected input never reaches the query provider or emits partial drift warnings.
Numbers retain their original JSON lexemes until exact Decimal validation;
equivalent scales and exactly representable large powers are accepted.
The package-only exact parser is shared with SQLite, not a public API.
Decimal operands must fit Foundation Decimal exactly and the existing 256-byte
storage-parser limit. Ordinary floating fields and JSON wire remain separate
profiles. Running twice retains the same four rows and versions; no cleanup is
performed between rounds. This is source verification, not an artifact release.
