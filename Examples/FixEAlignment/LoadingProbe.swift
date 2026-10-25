import Foundation
import GeneratedTeaQL
import TeaQLCore

enum LoadingProbe {
  static func require(_ value: Bool, _ message: String) throws {
    if !value { throw TeaQLError.execution(message) }
  }

  static func verify(_ context: UserContext, orderId: Int64) async throws {
    let rows = try await Q.purchaseOrders().withIdIs(orderId)
      .selectTenantWith(Q.tenantsWithMinimalFields().withIdIs(2).limit(1)
        .comment("Load only a different tenant's detail"))
      .limit(1).comment("Keep the selected FK when target detail is filtered out")
      .purpose("Verify filtered target detail is NotLoaded rather than loaded null").executeForList(context)
    try require(rows.count == 1, "Missing owner")
    var owner = rows[0]
    try require(try E.purchaseOrder(owner).tenantId().eval() == 1, "Selected FK was lost")
    let detail: NotLoadedDiagnostic
    do {
      _ = try E.purchaseOrder(owner).tenant().name().eval()
      throw TeaQLError.execution("A filtered target must be NotLoaded")
    } catch let error as TeaQLCore.TeaQLNotLoadedError {
      detail = error.toWire()
      try require(detail.attemptedInstancePath == "/tenant/name", "Lost the detail path")
    }
    owner.updateContactPhone("5550102")
    _ = try await owner.auditAs("Change only the complete owner").save(context)
    let complete = try await Q.purchaseOrders().withIdIs(orderId).limit(1)
      .comment("Reload the successful owner update")
      .purpose("Verify untouched partial targets do not prevent saving the owner").executeForList(context)
    try require(complete.count == 1, "Missing updated owner")
    try require(try E.purchaseOrder(complete[0]).contactPhone().eval() == "5550102", "Owner update lost")
    let version = try E.purchaseOrder(complete[0]).version().eval()
    let partialRows = try await Q.purchaseOrdersWithMinimalFields().withIdIs(orderId).limit(1)
      .comment("Load an identity-only owner")
      .purpose("Reject mutation of an incomplete owner before persistence").executeForList(context)
    try require(partialRows.count == 1, "Missing partial owner")
    var partial = partialRows[0]
    partial.updateContactPhone("5550103")
    do {
      _ = try await partial.auditAs("Attempt to modify an incomplete owner").save(context)
      throw TeaQLError.execution("Incomplete modified owner was not rejected")
    } catch let error as CheckException {
      try require(error.violations.contains { $0.ruleID == "invalid_type" }, "Missing completeness violation")
    }
    let unchanged = try await Q.purchaseOrders().withIdIs(orderId).limit(1)
      .comment("Reload after the rejected incomplete mutation")
      .purpose("Verify persisted values and optimistic version remain unchanged").executeForList(context)
    try require(unchanged.count == 1, "Missing unchanged owner")
    try require(try E.purchaseOrder(unchanged[0]).contactPhone().eval() == "5550102", "Rejected write changed phone")
    try require(try E.purchaseOrder(unchanged[0]).version().eval() == version, "Rejected write changed version")
    struct Result: Encodable {
      let language = "swift", passed = true, foreignKeyPreserved = true
      let untouchedPartialTargetSave = true, modifiedPartialOwnerRejected = true, rejectedVersionUnchanged = true
      let filteredDetailNotLoaded: NotLoadedDiagnostic
    }
    print("CORE_LOAD_EXAMPLE=" + String(decoding: try JSONEncoder().encode(Result(filteredDetailNotLoaded: detail)), as: UTF8.self))
  }
}
