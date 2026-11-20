# context-fix-service application rules

## TeaQL workspace rules

- Work in application-owned files. Keep the generated domain library read-only.
- Discover API names and signatures through model-aware Assist only.
  Do not read or search generated library source for API discovery. Use the
  original evaluated KSML file or directory and its exact entity and field names.
- Ask for the current entity and action first. Request field-level query help
  only for the fields you use. If Assist lacks the operation, report
  `MISSING_ASSIST` with the entity, action, and relevant field or diagnostic.

```text
cargo teaql --input [model] swift-assist-[action]/[entity]
cargo teaql --input [model] swift-assist-query/[entity].[field]
```

Replace the bracketed values with the actual model path, action, entity, and
field. Actions include `query`, `list-page`, `create`, `update`, `delete`, and
`expression`. Validate API usage by compiling and testing the application.

- Use the trusted `UserContext` as the only runtime argument for generated query
  execution and saves. Resolve tenant, actor, authorization, and provider
  resources from trusted application setup.
- Keep queries bounded and provide a non-empty purpose and comment. Supply a
  non-empty audit reason for writes through the API shown by Assist.

## Application entry and context

Start in `Sources/TeaQLConsole/main.swift`. Install `GeneratedRuntimeModule.module`
in `TeaQLRuntime`. Build the application `UserContext` with the installed runtime
and the configured query and mutation executors.

Queries are bounded and need a non-empty comment and purpose. A query's
purpose enters its executable stage; configure projection and filters first.
Use generated Q for loading and E for loaded-value traversal. NotLoaded is
an error, not a null. Mutations require the generated auditAs wrapper and
one save of the composed graph, with deletion marked before save.

Execute through one trusted UserContext argument. Install generated module
metadata passively, then explicitly call context.ensureSchema(module) at
startup; reuse its seeded Platform. Inject actor, policy, active root and
providers through trusted application initialization, not user input.

Validate with Swift compilation and executable tests. Make focused repairs
to application-owned code; do not rewrite an entire file to resolve a small
diagnostic. Keep generated-file hashes unchanged during implementation and
run tests twice without deleting the retained SQLite database. Record exact
commands, exits and observed SQL/audit evidence before claiming success.

## Optional standard telemetry

See [STANDARD_TELEMETRY.md](STANDARD_TELEMETRY.md) for the selected runtime's optional module, trusted activation variables and safe startup diagnostics.
