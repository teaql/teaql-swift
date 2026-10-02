<!-- ephemeral -->
# Swift Assist — Expression `Payment`

The generated E facade preserves Value, loaded Null, and NotLoaded. `eval()`
returns a native optional for the first two and throws `TeaQLNotLoadedError` for
the third. `orElse` applies only to loaded Null and never hides NotLoaded.

```swift
import Foundation
import TeaQLCore

public func extractPaymentId(_ entity: Payment) throws -> Int64? {
    try E.payment(entity).id().eval()
}

public func extractPaymentIdOrElse(_ entity: Payment, fallback: Int64) throws -> Int64 {
    try E.payment(entity).id().orElse(fallback)
}

public func extractPaymentReferenceCode(_ entity: Payment) throws -> String? {
    try E.payment(entity).referenceCode().eval()
}

public func extractPaymentReferenceCodeOrElse(_ entity: Payment, fallback: String) throws -> String {
    try E.payment(entity).referenceCode().orElse(fallback)
}

public func extractPaymentVersion(_ entity: Payment) throws -> Int64? {
    try E.payment(entity).version().eval()
}

public func extractPaymentVersionOrElse(_ entity: Payment, fallback: Int64) throws -> Int64 {
    try E.payment(entity).version().orElse(fallback)
}

public func extractPaymentCustomerOrderId(_ entity: Payment) throws -> Int64? {
    try E.payment(entity).customerOrderId().eval()
}

public func traversePaymentCustomerOrder(_ entity: Payment) throws -> CustomerOrder? {
    try E.payment(entity).customerOrder().eval()
}

public func aggregatePaymentPaymentAttemptListSize(_ entity: Payment) throws -> Int? {
    try E.payment(entity).paymentAttemptList().size().eval()
}

public func firstPaymentPaymentAttemptListId(_ entity: Payment) throws -> Int64? {
    try E.payment(entity).paymentAttemptList().first().id().eval()
}

public func getPaymentPaymentAttemptListId(_ entity: Payment, index: Int) throws -> Int64? {
    try E.payment(entity).paymentAttemptList().get(index).id().eval()
}


```

Select every traversed field and relation. Never catch `TeaQLNotLoadedError`
merely to supply a default, and never replace generated E accessors with
optional chaining.

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

Capability: `expression`.

- Distinguish a loaded null from a field or relation that was not projected. A
  NotLoaded/coding error must remain visible; do not turn it into an ordinary null.
- Select every traversed relation first and use the generated E/expression API for
  scalar, object, and list traversal. Do not translate Java accessor names by guess.
