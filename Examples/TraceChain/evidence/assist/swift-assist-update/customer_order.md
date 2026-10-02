<!-- ephemeral -->

# Swift Assist — Update `Customer Order`

Load the tenant-scoped current value so its original version participates in
optimistic locking. Never reconstruct ID/version from client input.

An entity update is not a partial DTO patch. Load every scalar field before
modification so checker rules can validate the complete business state. Never
use `WithMinimalFields()` or a reduced projection for an entity that will be saved.

```swift
import TeaQLCore

public func updateCustomerOrder(
    _ context: UserContext,
    entityId: Int64,
    newOrderNumber: String?,
    newDescription: String?,
    throwWhenMissing: Bool = false
) async throws -> CustomerOrder? {
    guard var current = try await Q.customerOrders()
        .withIdIs(entityId)

        .comment("what: load current Customer Order and version")
        .purpose("why: authorize Customer Order update")
        .executeForList(context)
        .first
    else {
        if throwWhenMissing { throw TeaQLError.execution("Customer Order not found") }
        return nil
    }

    current.updateOrderNumber(newOrderNumber)
    current.updateDescription(newDescription)

    _ = try await current
        .auditAs("business reason: update authorized Customer Order fields")
        .save(context)
    return current
}
```

This source returns nil for not-found by default and can throw a distinct error.
Compile and execute it unchanged. Prove persisted update, stale-version conflict,
blank audit rejection, and unknown-updater compilation failure.

---

## TeaQL seven-language assist contract

Apply the verified Rust semantic ceiling while using only the exact SWIFT generated and
runtime APIs. Discover APIs through the generated application AGENTS.md and progressive
model-aware Assist. Do not inspect generated domain-library source.

- Do not create plurals by appending `s` or `es`; use the centralized generated plural.
- Human and non-human entities use different generated predicate vocabularies. Preserve
  forms such as “who are active” and “whose email is”; never infer them from English.
- Configure filters, projection, paging, and other query options before `purpose(...)`.
  Comment may appear anywhere in the chain. Purpose enters the executable stage; execution
  requires both values, but comment does not have to immediately precede purpose.
- Every execute/list/stream and every save accepts exactly one context argument:
  `UserContext`. Name that argument `context`, never `runtime`; data services and global
  policy are injected when the context is built. Reserve `runtime` for process-level
  runtime ownership, provider/pool setup, and module assembly.
- Tenant, merchant, identity, permissions, request policy, purpose policy, hard limit,
  and continuous-page cursor policy come only from trusted context, never dynamic JSON or TFP.
- If the required operation is absent after current entity/action and required field
  Assist, stop that path and report MISSING_ASSIST. Do not guess an API or search the
  generated library as a fallback.
- Create each application-owned source file once. After its first compile attempt,
  repair only the smallest block identified by the exact compiler or test diagnostic.
  Preserve unrelated code; do not rewrite the complete file as an error-recovery loop.
- Before a repair that would replace more than 25% of an existing application file,
  stop and report LARGE_REWRITE_REQUEST with the file, exact diagnostic, reason, and
  estimated scope. Initial creation and model-driven regeneration are not repairs.

Capability: `update`.

- Load the tenant-scoped current entity first so its original version participates
  in optimistic locking; do not reconstruct versioned state from untrusted JSON.
- Allow-list writable fields, attach the generated audit-reason API, and save with
  the same UserContext. Add a stale-version rejection test.
