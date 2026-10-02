# trace-chain-service application rules

Implement only application-owned code. Do not read or search generated library
source to discover APIs, and do not edit generated models. Use progressive
model-aware Assist with the original KSML input:

```bash
cargo teaql swift-assist-query/entity --input models/
cargo teaql swift-assist-query/entity.field --input models/
cargo teaql swift-assist-create/entity --input models/
```

Replace entity and field with KSML names. Ask for the current entity/action
first, then only the field help needed by the task. Do not fetch all Assist
outputs. If an operation is missing, report MISSING_ASSIST and stop that path;
fix the producer rather than guessing a method or reading generated source.

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