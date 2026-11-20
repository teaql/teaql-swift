# School startup and query showcase

`models/school-model.xml` owns the exact native `swift-lib-core` and
`swift-app-console` scopes. The workspace retains the original business and
regression assertions in `Sources/TeaQLConsole/main.swift`. It also reassembles
a second application Context against the same SQLite file, reconciles the model
constant once and proves another ensure adds no write or duplicate School.
`showcase.json` records current provenance; the root fixture index is historical.
Run `bash verify.sh` from this scene for the focused gate and independent SQLite
check. The gate retains compact receipts and removes its owned build scratch.

This generated Swift package retains the shared `models/school-model.xml` fixture
and verifies explicit SQLite `ensureSchema`, root and constant seeding, unchanged
repeat idempotency, and versioned reconciliation of a changed constant.
It also verifies that mutation-ledger composition keeps optimistic versions
isolated when different entity types share the same numeric ID.

From `swift-app-console`, run `swift run TeaQLConsole`. The package dependency points to the
repository root intentionally: local runtime verification must pass before a
release is published and verified from a clean public dependency.
