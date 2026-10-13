# Swift Standard OpenTelemetry Module

`TeaQLStandardTelemetry` is a local, unreleased source candidate. It exports
TeaQL operation traces, metrics and safe SQL diagnostics without instrumentation
in individual business methods. The advanced `TeaQLOpenTelemetry` adapter remains
available for applications that supply their own SDK.

## Application assembly and configuration

Add the `TeaQLStandardTelemetry` product to the application's Swift package
dependencies and register it once where the application assembles its runtime:

```swift
import TeaQLStandardTelemetry

StandardTelemetryModule.install()
// Construct the normal UserContext and install the generated module as usual.
```

Registration creates no SDK resources. The normal `UserContext` initializer
selects the shared standard pipeline only when these settings are valid:

```bash
TEAQL_TELEMETRY_ENABLED=true
TEAQL_TELEMETRY_SERVICE_NAME=payment-service
TEAQL_TELEMETRY_OTLP_ENDPOINT=http://collector:4318
```

Without enablement, startup reports that telemetry is supported and prints all
three settings. Invalid configuration produces a fixed explanation without
echoing credentials or invalid values. Enablement without assembly registration
reports that the optional module is unavailable. No public collector is selected
implicitly. Keep the settings in trusted process configuration, not user input.

SDK initialization is shared across contexts with the same configuration. A
five-second deadline keeps a stalled initializer from blocking business startup;
a late SDK result is closed instead of being published. A closed pipeline is
not reused by a new context.

## Recording and privacy

Enabled TeaQL operations are fully recorded by default, rather than deliberately
selecting a percentage of requests. No customer sampling code is required.
This is not a guarantee of lossless delivery.

Ordinary SQL logging is independent. Turning it off does not turn off enabled
telemetry. SQL diagnostics use the existing runtime's safe expanded SQL and
masking algorithm, including when console plaintext debugging is enabled. The
module does not export raw parameter arrays, result rows, entity IDs or exception
messages. Comments and purposes remain business explanation text: do not put
secrets in them.

SQLite captures an identity before each actual query, count, write or persisted
readback. The completion metadata carries that identity to log export. A write
and its readback have separate spans under their shared provider operation;
logs do not guess identity from completion order or a late active span.

Graph saves have one runtime-owned `graph.save` mutation operation. Transaction
begin, entity mutations, persisted readbacks, commit/rollback, completion
callbacks and post-commit audit delivery stay within its lifetime. Original
errors survive rollback failures, and failures after commit do not trigger a
rollback. An independent query after the save receives a separate trace.
Applications and generated libraries need no additional graph SDK calls.

The module owns its tracer, meter, logger and private task-local scope. It does
not register global SDK providers or close customer providers. Span names and
metric labels omit SQL, identifiers and free-form intent.

## Transport and shutdown

The transport uses official OTLP protobuf encoders and an owned ephemeral
`URLSession`. It does not inherit another SDK's authentication headers,
credential storage or global error callback. Requests have a three-second
deadline. Failed batches are counted and discarded, not retained in an unbounded
retry queue. Fixed per-signal notices, `exportLosses` and the
`teaql.telemetry.export.lost` counter expose export failures.

Responses are streamed into a buffer capped at four MiB. Redirects are not
followed. Official response decoding is preceded by strict known-field wire
validation; groups, malformed/truncated frames, negative rejection counts and
counts exceeding the submitted batch are invalid. Collector error text is never
printed. A partial acceptance counts rejected spans/log records or metric data
points separately from whole-batch failure. Failed metrics count MetricData
objects, not points. A zero-rejection warning is not loss.

`rejectedRecords`, `exportResponses`, `teaql.telemetry.export.rejected` and
`teaql.telemetry.export.response` expose these outcomes. Metric labels use fixed
signal/reason values and initialize healthy zero series. A timed-out or closed
private transport releases its pending request; late completion cannot change
the returned result. Empty successful acknowledgements remain supported.

Application shutdown uses the runtime lifecycle once, not after each query:

```swift
await context.runtimeTelemetry.flush()
await context.runtimeTelemetry.shutdown()
```

The owned lifecycle has a six-second caller deadline. Public SDK processor
wrappers admit at most 2,048 records per trace/log signal, including native
queued, staged and currently exporting records. Batches contain at most 128.
An identity ledger retains each permit until export completion; it is not
another payload queue. Logs use private tickets that are stripped before export.
Metrics export cumulative snapshots rather than an invented event queue.

Flush waits for the successful-handoff prefix captured when it starts. Newer
completions cannot replace older pending records, and later admissions do not
extend the wait. The SDK worker wakes at 200 ms; normal flush does not call the
native hook that can cancel staged batches. Shutdown closes admission, drains
for up to five seconds, then retires only unattempted records and cancels owned
exports once. Two actual generated Q/E backlog replays qualify closure at about
5.04 seconds, with zero outstanding/exporting records, private HTTP requests and
lifecycle jobs, and all three owned transports closed. Actual failed attempts
plus queued retirement account for every admitted record.

Closing admission is not the same as completing shutdown. Concurrent shutdown
calls and flushes during closing await the same resource-completion group and
the original six-second deadline. Earlier flushes overtaken by shutdown also
join that closure. Accepted flush work settles before final metrics. SDK
shutdown runs once; subsequent callers do not launch another SDK hook.

Trace/log prefix observations use callbacks outside the admission lock, not a
blocked Dispatch worker per caller. This leaves threads available for native
SDK exports. Twelve concurrent native flushes complete in about 0.2 seconds,
instead of the earlier roughly nine seconds with incomplete-prefix notices.
Native late-body tests preserve successful results, original errors and
once-only completion without new exports. Later transport callbacks remain
a separate qualification gate.

Metrics collect after trace/log draining so the final cumulative snapshot
includes drain failures and retirement. The final metric attempt receives only
the remaining six-second caller budget; an absolute deadline also cancels an
already-running owned request. Final metric delivery can fail and that failure
is locally counted. An acknowledgement is not proof of durable receiver storage.

`exportQueues` reports bounded admission/completion/overflow/retirement state.
`exportLossReasons` and `teaql.telemetry.export.lost` distinguish
`queue_overflow`, `export_failure`, `shutdown` and `handoff_failure`.
Overflow and export failure are not receiver-reported rejection. Late business
operations remain functional and count local shutdown losses without inventing
SQL correlation. A closed provider does not export another metric snapshot.
`exportResources` reports only counts of active HTTP requests, owned/closed
transports and lifecycle jobs, not URLs, payloads or identifiers.

## Repository verification

The generated example uses repository-local dependencies, normal schema setup,
audited bootstrap, bounded Q queries and E traversal. It checks one committed
root seed, no repeated seed write and six physical SQL statements. Its verifier
checks startup hints and unchanged generated-library hashes:

```bash
bash Examples/TraceChain/verify-standard-telemetry.sh
```

The [complete Order example](Examples/TraceChain/standard-order/Application/Main.swift)
also uses generated Q and E for forward detail, reverse previews, full child
counts and facets. Counted and uncounted lists use the same terminal. The runtime
owns one root through entity construction, applies root policy once and preserves
its filter and bounded slice. Private order numbers are declared in the model.

```bash
bash Examples/TraceChain/verify-standard-order.sh
```

Both examples are included in `scripts/verify-examples.sh`. Conformance's
`telemetry/capture-swift-standard-order.cjs` verifies actual Collector/OpenObserve
delivery: two enabled runs produce eight roots and sixty physical SQL logs, with
ordinary SQL logging off. Fifteen retained domain files match the current
producer. Bootstrap and the application replay twice on one retained database.
The [generated graph example](Examples/TraceChain/Sources/StandardGraphVerification/Main.swift)
adds six-entity creation, an actual SQLite-triggered failure, rollback with no
committed audit, mixed retry and marked deletion. It uses Q/E and generated
audited save, not handwritten domain SQL. Only the fault-injection trigger is
test DDL. The graph replays twice on retained SQLite; explicit/inherited comments,
independent row ledgers and shared immutable reference snapshots are verified.

```bash
bash Examples/TraceChain/verify-standard-graph.sh
```

This gate is also part of `scripts/verify-examples.sh`. Final-source Collector/
OpenObserve readback exports six business graph roots, sixty-six graph SQL logs
and twenty-four committed audits, with 106 SQL logs in total including bootstrap
and independent reloads. Seventeen generated files match the evaluated producer;
three producer/retired-entry cases and all five example groups pass. Intent checks
reuse runtime `QueryIntent`. Modeled relations are excluded from computed
properties, whose absent values return nil. Mutated objects explicitly load
complete self fields. Six application lockfiles retain the SDK 2.5.1 pin set.
Local graph-boundary regression has 251 passes and one skip, including
[six core cases](Tests/TeaQLCoreTests/GraphTelemetryTests.swift) and
[two real SQLite/official-SDK cases](Tests/TeaQLStandardTelemetryTests/GraphSDKTests.swift).
All five example groups pass. Two actual generated bootstrap replays each
export one graph root with the seed write beneath it, preserving the three
startup settings, six SQL statements per replay and repeated-seed idempotence.
After a runtime value-layout
change, use a separate scratch directory to qualify consumers; refreshing only
the build manifest can leave old compiled callers in place.

The current concurrent gate has 277 native passes, one skip and 42 standard-module
cases. Ten real three-signal HTTP receiver scenarios are independently decoded
from retained protobuf packets. Every case preserves the generated graph's
create/rollback/retry/delete results and committed audit. All five example groups
pass; refreshed healthy startup, graph and Order deliver twelve, 106 and sixty
physical SQL logs respectively. Seventeen generated domain files are unchanged.

Earlier healthy receiver-pressure replays each execute 1,500 generated SQLite Q/E
queries, offering 4,500 spans and 6,000 logs. Both quotas hold exactly 2,048
outstanding records, including the held 128-record export. Overflow is 2,452
spans and 3,952 logs. Receiver release drains the captured prefix and restores
capacity without changing business data or committed audit. The Q/E fixture
does not create spans, SDK log records or exporters in individual queries.

Current timeout-pressure/recovery replays retain the three-second HTTP deadline.
Each offers 4,500 spans and 6,000 logs through 1,500 generated Q/E queries, with a
2,048-record peak. Timed-out exports release permits, so cumulative admissions
and overflow vary with timing; actual attempts and native counters are reconciled
instead of assuming every receiver delay is healthy. Recovery drains the prefix
and permits another query. Two real backlog replays also preserve committed
audit and allow Q/E after shutdown, counting two local late offers per signal.

Two actual generated Q/E replays with held HTTP exports each verify 19
concurrent lifecycle callers. Every caller observes zero private HTTP requests
and lifecycle jobs and three closed owned transports when it returns. A late
query preserves business data and audit and diagnoses two late offers per signal.

Later transport callbacks,
advanced graph/stream, child-task ownership, stronger SDK coexistence and
internal-registry consumer gates remain open. Local evidence
does not qualify a public package release.
