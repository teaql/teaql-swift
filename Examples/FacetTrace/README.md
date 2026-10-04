# Generated Facet Trace example

This small School fixture uses generated Q, loaded E and audited graph save with
real SQLite. The ten generated source files are the unchanged output retained by
the producer's October 3 School Facet acceptance. Never inspect or patch them for
API discovery. The example's manifest depends on this repository's local runtime.

```bash
bash Examples/FacetTrace/verify.sh
```

Use Swift 6.3.3 and reuse an ABI-consistent `TEAQL_SWIFT_SCRATCH_PATH` to avoid
recompiling unchanged dependencies. The script uses a fresh retained SQLite file,
runs all 26 scenarios twice without cleanup, and verifies generated hashes.

Eight root/nested scenarios, eight loaded to-many scenarios (window/probe
thresholds), eight forward-detail scenarios and two audited writebacks cover
include-all/matched-only, full counts beyond a one-row page, loaded empty
collections, original-root ancestry, future-binding privacy and logging on/off.
The explicit safe telemetry collector remains active with diagnostic logging off.
`SWIFT_FACET` JSON lines retain real results, paths and counts, not just pass totals.

A filtered-out forward target is not null: its real FK identity remains, while
unfetched detail fails with NotLoaded. The prior fixture's loaded-null expectation
is corrected here, without changing runtime or generated library code.

An independent query on the same context proves that Facet redactions do not
escape invocation scope. No-op save of the loaded Facet graph emits zero writes
and audits; a real child address mutation saved through its parent emits exactly
one UPDATE and committed audit, and advances the child's version once. Facet
carriers do not enter model JSON or persistence records.

This is the generated SQLite Facet/count/writeback subset, not all 41 Trace Chain
cases or public-package acceptance. Runtime/provider and whole-goal claims need
their separate gates. Historical generated whitespace is deliberately retained.
