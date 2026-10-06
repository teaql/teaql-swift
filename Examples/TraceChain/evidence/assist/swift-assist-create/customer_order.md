<!-- ephemeral -->
# Swift Assist — Create `Customer Order`

Use the exact generated `Q.customerOrders()` entry point. The
trusted `UserContext` supplies actor, tenant, policy, provider, and audit sink;
none of those values may be accepted from the writable input.

```swift
import TeaQLCore

public struct CreateCustomerOrderInput: Sendable {
    public let platform: Int64
    public let orderNumber: String?
    public let description: String?

    public init(
        platform: Int64,
        orderNumber: String?,
        description: String?,

    ) {
        self.platform = platform
        self.orderNumber = orderNumber
        self.description = description

    }
}

public func createCustomerOrder(
    _ input: CreateCustomerOrderInput,
    context: UserContext
) async throws -> CustomerOrder {
    var entity = try Q.customerOrders()
        .comment("what: initialize Customer Order")
        .purpose("why: create Customer Order")
        .newEntity(context)

    entity.updatePlatform(input.platform)
    entity.updateOrderNumber(input.orderNumber)
    entity.updateDescription(input.description)

    _ = try await entity
        .auditAs("Create Customer Order for the requested business operation")
        .save(context)
    return entity
}
```

Only the generated updater methods shown above are writable. Constant relation
candidate methods, when present, are also generated and must be copied exactly:

By default the runtime allocates the new ID. A trusted migration or deterministic
fixture may set an explicit ID using `entity.updateId(100)` before saving; never
derive it from untrusted input. ID and version are not ordinary writable fields.

## Compose children before one graph save

The generated reverse lists below are arrays. Initialize each child with its
generated Q entry point and fill its scalar fields using its own create Assist.
Append it before saving the root; the generated traversal sets its parent FK.
No implicit database fetch happens when appending a child.

```swift
var child = try Q.orderItems()
    .comment("what: initialize Order Item")
    .purpose("why: compose Customer Order graph")
    .newEntity(context)
// Fill child fields using Order Item create Assist.
// Omit the next line to inherit the parent's reason without a duplicate node.
_ = child.auditAs("local business reason")
entity.orderItemList.append(child)
```

```swift
var child = try Q.payments()
    .comment("what: initialize Payment")
    .purpose("why: compose Customer Order graph")
    .newEntity(context)
// Fill child fields using Payment create Assist.
// Omit the next line to inherit the parent's reason without a duplicate node.
_ = child.auditAs("local business reason")
entity.paymentList.append(child)
```

```swift
var child = try Q.shipments()
    .comment("what: initialize Shipment")
    .purpose("why: compose Customer Order graph")
    .newEntity(context)
// Fill child fields using Shipment create Assist.
// Omit the next line to inherit the parent's reason without a duplicate node.
_ = child.auditAs("local business reason")
entity.shipmentList.append(child)
```


Save only the root via `entity.auditAs("root business reason").save(context)`.
Do not independently save a composed child or replace its local reason with
the parent's. For an existing child, load all its scalar fields and use its
delete Assist before composing it into a graph.

Compile the result unchanged. Test successful persistence and query-back, and
prove that blank/missing intent, missing audit reason, unknown fields, and
attempted trusted-context overrides fail. Do not edit generated sources.

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

Capability: `create`.

- Validate and allow-list writable business fields; never mass-assign dynamic JSON.
- Create through the generated request/entity API, attach a non-empty audit reason,
  save with the same UserContext, and return the runtime's native save result.
- Add a negative test proving a missing audit reason cannot write.
