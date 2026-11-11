# Context-derived fields and business intent

This small two-entity SQLite example uses an evaluated, unedited generated
library, typed Q/E and audited graph saves with local runtime source.

```sh
node Examples/ContextDerived/verify-local.cjs
```

The verifier checks the complete fixture inventory, uses this runtime's pinned
dependency revisions, proves the local package origin, and runs twice on one
database. An independent read-only SQLite query verifies the typed E observation.
Its owned build outputs and dependency checkouts are removed after children exit;
compact logs, receipt, lockfile and database remain. Shared caches/services remain
untouched. Set `TEAQL_CONTEXT_FIX_EVIDENCE_DIR` to a new absolute evidence path.

Checks include changed clock/IP/actor without business changes (zero provider
calls, audits or version bumps), scoped create/update defaults, once-only Fix,
safe field-local provider errors, failed Check rollback and retry, indexed
`/entryList/1/name`, and child-only updates without refreshing parent/sibling.

The actual generated Checker supplies clock/unique-string behavior; application
SPI decorates it for IP/actor string fields. `RuntimeModule.contextFixFields`
declares these trusted supplemental functions without replacing the generated
entity descriptor. `ContextFixResolver` supplies synchronous strongly typed
values. Prepare external asynchronous results before entering Save.

Swift's value-copy and prepared-graph boundary stages all fields privately until
the whole graph and policy pass. Short-lived Context undo removes automatic
ledger values after rollback without replacing business intent or version state.
The Context Fix frame exists only in the Checker's invocation-owned Context copy;
retained copies expire and cannot be used as reusable mutation capabilities.

No generated source is hand-edited and no SQL mutation alternative is used.
This source qualification does not claim published-package/clean-room acceptance,
full example-inventory acceptance or extra APIs from other generator branches.
