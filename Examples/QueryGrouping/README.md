# Generated query grouping example

Run `bash Examples/QueryGrouping/verify.sh` from the runtime repository. The
application depends on this repository's runtime, not a published runtime.
Swift, SQLite development headers and Node.js are required.

The generated Q API groups records under caller-selected result names:

```swift
let rows = try await Q.queryRecords()
    .groupByActiveAs("bucket")
    .countAs("hits")
    .sumRequiredIntegerAs("total")
    .orderByActiveAscending()
    .limit(10)
    .comment("inspect active grouping contributions")
    .purpose("verify named aggregate result values")
    .executeForRows(context)
```

Ten cases cover Boolean grouping, aliases that shadow entity fields, exact
Decimal and Int64 values, timestamps, group-only results, nullable references,
multiple group keys and duplicate-alias rejection. Generated E expressions
check the original entity values and versions. All sample records are saved
through generated mutation APIs with audit comments; no INSERT SQL seeds them.

Both runs use the same SQLite database. The first creates two groups and four
records; the second must reuse all six without writes. The verifier checks each
named result against explicit expected values. The generated library is
hash-checked before and after execution.

Logs and the database remain in the printed evidence directory. Set
`TEAQL_SWIFT_GROUPING_EVIDENCE_DIR` to retain them at a chosen fresh location.
Disposable build output is removed on exit. A caller-supplied
`TEAQL_SWIFT_SCRATCH_PATH` remains owned by that caller and is not deleted.

`model.xml` defines the three-object fixture. `Generated/` retains the evaluated
generator output unchanged; the application manifest compiles its source target
against the local runtime. Do not edit generated implementations.
