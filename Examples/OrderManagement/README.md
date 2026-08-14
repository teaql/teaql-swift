# Order Management

This terminal example is the shortest path from a clean checkout to a real TeaQL query and audited save. It uses SQLite, so no database server or prebuilt database file is required.

## Run it

From the repository root:

```bash
swift run teaql-order-management
```

On the first run TeaQL reports that `order-management.sqlite` was missing, creates it, ensures the schema, inserts a deterministic sample order, and searches it. Run it again to see that seeding is idempotent.

## Read the code

- `Sources/main.swift` is application code: database setup, trusted `UserContext`, purpose/comment, query, and audited save.
- `Generated/Sources/GeneratedTeaQL/Models` contains entities generated from the polyglot Order Management model.
- `Generated/Sources/GeneratedTeaQL/Requests` contains the typed request API.
- `Generated/Sources/GeneratedTeaQL/Q.swift` is the generated query entry point.

Do not edit `Generated`. Change the model or generator and regenerate it. The checked-in generated source makes the first experience inspectable and allows terminal builds without running the Java generator.

The application deliberately passes exactly one argument—`UserContext`—to `executeForList`. Trusted policy, executors, actor, and audit sink are injected when that context is initialized. A request must reach the `purpose(...)` stage before the execute API is available; `comment(...)` may appear anywhere in the chain.
