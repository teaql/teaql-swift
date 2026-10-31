# Known persisted baseline restoration

Run `node Examples/FixEAlignment/verify-local.cjs` from the runtime repository.
This includes `RestorationProbe.swift` twice on the same SQLite stores, with no
reset between rounds. The existing evaluated model and generated library are
hash-checked; neither is edited for this example.

The example uses generated Q/E and audited saves for every business operation.
Independent SQL only reads persisted tables and the ID-allocation floor.

Nine scenarios cover known value/null restoration through typed and generic
mutation APIs, same-ID different-type isolation, another genuine remaining edit,
unknown originals, a sparse untouched ancestor, a clean parent with a dirty
child, and deletion that must not be cancelled by scalar restoration.

Successful graph creation first calibrates the real provider, Checker, policy
and committed audit observers. A no-op or incomplete rejection must then invoke
none of those boundaries, read no Business Clock, allocate no ID and change no
stored value/version. A genuine remaining edit or deletion must still execute.
The structured `CORE_SWIFT_RESTORATION_RESULT` contains each actual observation;
failure throws and exits nonzero, rather than being converted to a passing log.

The verifier removes its owned build outputs and retains compact logs and test
databases. This does not claim dynamic-field support, arbitrary outer
transaction ownership, a full mutation contract or installed-SDK acceptance.
