# District school directory statistics

The district uses its school directory to count schools and classes by school
type. Primary has two schools with three classes, Secondary has one with
three classes, and an unclassified school contributes four classes to its
own group. A filter for an unknown school returns no groups.

`model.xml` defines the district, school types and schools. The generated
`swift-lib-core` is immutable. The `swift-app-console` workspace retains
the generated domain target and uses the local TeaQL SDK for verification.
The application assembles a SQLite-backed UserContext, seeds schools through
audited generated mutations, and uses generated Q and E to read the results.

```swift
let statistics = try await Q.schools()
    .groupBySchoolTypeAs("owner")
    .countAs("hits")
    .sumClassCountAs("classes")
    .orderBySchoolTypeAscending()
    .limit(10)
    .comment("inspect school type totals")
    .purpose("publish the district school directory")
    .executeForRows(context)
```

The workspace also checks Boolean grouping, aliases that shadow entity fields,
exact Decimal budgets and Int64 registry numbers, timestamps, grouping without
aggregates, multiple group keys, duplicate-alias rejection and entity versions.

Run `bash Examples/QueryGrouping/verify.sh` from the runtime repository with
Swift, SQLite development headers, Node.js and Python 3 installed. The two
launches share a SQLite database. The second must neither reseed nor change the
rows. Independent SQLite checks and the verifier's result remain in the
evidence directory. Set `TEAQL_SWIFT_GROUPING_EVIDENCE_DIR` to choose a fresh
output location. The verifier removes the build directory it creates.
