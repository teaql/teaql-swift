# Order Management

`model.xml` owns the exact `swift-lib-core` and `swift-app-console` scopes.
The business program is byte-identical in the native workspace entry. Current
provenance is in `showcase.json`. Run `bash verify.sh` from this scene for two
starts of the workspace and two starts of the retained SDK product, each pair
on one SQLite file. Independent SQL checks validate stored orders; owned build
scratch is removed. The two package graphs use separate compilation outputs.

This terminal example is the shortest path from a clean checkout to a real TeaQL query and audited save. It uses SQLite, so no database server or prebuilt database file is required.

## Run it

From the repository root:

```bash
swift run teaql-order-management
```

The first run creates `order-management.sqlite`, ensures the generated module's
schema, seeds its root and constants, then creates a customer and order through
generated audited saves. Run it again to verify that those rows are reused.
Pass an explicit database path after the executable name to keep test data outside
the checkout.

`model.xml` is the maintained seven-entity shared Order Management model. The
generated runtime module installs its actual Checkers and bootstrap program;
creation uses allocated IDs and the generated Pending status helper, not invented
foreign keys. Create/update timestamps are supplied by Checker/Fix and order date
uses the context's Business Clock.

## Read the code

- `swift-app-console/Sources/TeaQLConsole/main.swift` is application code: database setup, trusted `UserContext`, purpose/comment, query, and audited save.
- `swift-lib-core/Sources/GeneratedTeaQL/Models` contains entities generated from the polyglot Order Management model.
- `swift-lib-core/Sources/GeneratedTeaQL/Requests` contains the typed request API.
- `swift-lib-core/Sources/GeneratedTeaQL/Q.swift` is the generated query entry point.
- `swift-lib-core/Sources/GeneratedTeaQL/E.swift` provides loaded, typed expression access.

Keep the generated domain sources read-only. Discover APIs through current model-aware Assist. Change the model or generator and regenerate it. The checked-in generated source makes the first experience inspectable and allows terminal builds without running the Java generator.

The application deliberately passes exactly one argument—`UserContext`—to `executeForList`. Trusted policy, executors, actor, and audit sink are injected when that context is initialized. A request must reach the `purpose(...)` stage before the execute API is available; `comment(...)` may appear anywhere in the chain.
