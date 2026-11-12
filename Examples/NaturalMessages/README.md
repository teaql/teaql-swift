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

The application installs immutable presentation metadata and decorates the real
generated Checker only to supply its declared IP/actor Context functions. The
string-length rule itself comes from the generated library, not a replacement
application rule. Automatic presentation metadata emission remains separate.

An unchanged parent has two loaded children. Only the second receives a private
value consisting of 101 combining-character sequences. Swift's original
`String.count` sees 101 grapheme clusters, not 202 Unicode scalars. The generated
Checker attaches this exact measurement before masking:

```text
The private token of the 2nd entry must not exceed 100 grapheme clusters; its current length is 101.
```

The pointer remains `/entryList/1/guardedToken`. Chinese rendering preserves the
same path and measurement. Rejection makes zero provider/audit calls; correction
writes and audits only that child. Q/E and an independent readonly SQLite oracle
check the final stored value and all three versions.

`fixture/` is unedited generated source sealed by its manifest. Regenerate it
using `SwiftContextFixGenerationTest` from the matching generator feature branch.
The verifier retains compact evidence and the database, removes its own compiler
outputs/checkouts after reaping children, and never overwrites existing evidence.
No command above publishes a package or tag.
