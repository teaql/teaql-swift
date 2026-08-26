# School Management bootstrap example

This generated Swift package retains the shared `models/school-model.xml` fixture
and verifies explicit SQLite `ensureSchema`, root and constant seeding, unchanged
repeat idempotency, and versioned reconciliation of a changed constant.

Run `swift run SchoolBootstrapVerification`. The package dependency points to the
repository root intentionally: local runtime verification must pass before a
release is published and verified from a clean public dependency.
