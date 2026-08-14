# TeaQL Swift Agent Rules

- Read generated Entity and Request sources before using their APIs. Never guess method names.
- Never hand-edit generated source. Fix the Swift generator or runtime and regenerate.
- Query execution accepts exactly one caller-supplied argument: `UserContext`.
- A query is executable only after non-empty `comment` and `purpose` values have been supplied.
- Every mutation requires a non-empty audit reason.
- Tenant, actor, permissions, request policy, and purpose policy come from trusted server initialization of `UserContext`; dynamic JSON and TFP payloads cannot replace them.
- Generated plurals must come from the generator's centralized pluralization algorithm. Never append `s` or `es` in Swift templates.
- Java generated Request APIs are the predicate naming gold standard. Human entities declared with `cat="human"` use `whose` and plural `whoAre`; non-human entities use `with` and plural `whichAre`.
- Run the complete Swift test suite before committing runtime changes.
