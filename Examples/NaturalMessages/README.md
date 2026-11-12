# Natural Checker messages

This example uses an evaluated/generated library, the repository-local Swift
runtime, SQLite, typed Q/E APIs and audited graph saves. Two rounds use the same
database without cleanup between them.

```sh
node scripts/verify-natural-messages.cjs --example --output /absolute/new/evidence
node --test scripts/verify-natural-messages.test.cjs
```

The default test gate runs the original complete Swift package and pinned SDK
dependencies. `--focused` selects only Core's natural-message and legacy-i18n
tests; it is not complete-runtime acceptance. `--example-only` runs the generated
SQLite consumer without claiming native test coverage. Set `SWIFT_EXE` to select
an installed Swift toolchain.

`AutomaticNaturalMessages.swift` uses the original generated module and Checker.
The module installs model metadata automatically; application code supplies no
presentation model or replacement Checker. `automatic-fixture/` retains 14
byte-exact generated files, the validated model, provenance and seven real
object/field Assist responses. Use those responses for API discovery.

An unchanged provisioned parent has two children selected in descending ID order.
Required rejects explicit null in English and Chinese. Only the second receives a private
value consisting of 101 combining-character sequences. Swift's original
`String.count` sees 101 grapheme clusters, not 202 Unicode scalars. The generated
Checker attaches this exact measurement before masking:

```text
The name of the 2nd entry must not exceed 100 grapheme clusters; its current length is 101.
```

The pointer remains `/entryList/1/name`. A trusted customer renderer receives
safe arguments and the original count, and runs once despite graph relocation.
Rejection and missing audit intent make zero provider/transaction/audit calls.
Restoring caller values produces no Context-only write. Correction writes and
audits only that child; Q/E and an independent readonly SQLite oracle check the
stored value, injected Business Clock time and all three versions. Swift value
semantics require retaining the value returned by Save.

Regenerate the automatic fixture with `SwiftNaturalMessagesGenerationTest` at
its recorded producer commit. The older `fixture/` and `NaturalMessages.swift`
are retained as historical manually composed source, not automatic acceptance.
The verifier retains compact evidence and the database, removes its own compiler
outputs/checkouts after reaping children, and never overwrites existing evidence.
No command above publishes a package or tag.
