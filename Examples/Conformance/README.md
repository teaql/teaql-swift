# Swift runtime conformance example

This retained SQLite example is generated from `model.xml` and verifies explicit
`ensureSchema`, Create, Update, Delete, typed Q/`SmartList`, E
loaded/null/not-loaded semantics, and Checker rejection before SQL.

```bash
swift build
swift run TeaQLConsole
```

Installing `GeneratedRuntimeModule.module` is passive. The executable calls
`database.ensureSchema(GeneratedRuntimeModule.module)` separately and explicitly.
