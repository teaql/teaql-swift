# Generated E diagnostics under model JSON naming profiles

Run from the Swift runtime repository:

```sh
node Examples/ExpressionProfiles/verify-local.cjs
```

The same application compiles and executes three evaluated generated libraries:
default `camelCase`, `snake_case`, and `PascalCase`. Models differ only in
`json_field_naming`; fixture files retain their producer hashes.

The context initializes SQLite, then a bounded generated Q query loads the root
without its reverse list. A generated E traversal must report NotLoaded with
the canonical KSML location, model-specific JSON pointer, complete native
expression, first `<broken>` position and preload guidance. It does not override
the diagnostic profile. An actor observes the actual query provider: E performs
no additional calls and leaves the selected root name unchanged.

Each model runs twice against one retained database without cleanup. The runner
uses a local SwiftPM runtime dependency, checks its described origin, and removes
only its owned build/dependency checkout after execution. Set
`TEAQL_GENERATED_E_PROFILE_EVIDENCE_DIR` to a new absolute output directory to
retain logs and compact receipts there. Existing evidence is never overwritten.

This tests local-source generated E diagnostics, not a new runtime implementation,
a published-package consumer, an audited-save flow, the full Swift test suite or
the complete example inventory. Literal punctuation and JSON-pointer escaping
belong to the separate native expression-path tests; modeled names here remain
legal multiword identifiers.
