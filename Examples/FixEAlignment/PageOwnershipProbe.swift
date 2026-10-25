import Foundation
import GeneratedTeaQL
import TeaQLCore

enum PageOwnershipProbe {
  static func require(_ value: Bool, _ message: String) throws {
    if !value { throw TeaQLError.execution(message) }
  }
  static func verify(_ context: UserContext, idA: Int64, idB: Int64) async throws {
    let before = try await Q.purchaseOrders().limit(20).comment("Inspect the page ownership fixture")
      .purpose("Establish the bounded exact total").executeForList(context)
    var sentinel = try Q.purchaseOrders().comment("Prepare a page-offset sentinel")
      .purpose("Exercise a genuine nonzero page offset").newEntity(context)
    sentinel.updateContactPhone("5550500")
    _ = try await sentinel.auditAs("Save the synthetic page sentinel").save(context)
    let page = try await Q.purchaseOrders().orderByIdDescending().offset(1).limit(2).count()
      .comment("Load a nonzero-offset page of independent roots").purpose("Verify exact count and page ownership").executeForList(context)
    try require(page.count == 2 && page.totalCount == before.count + 1, "Incorrect page or exact total")
    guard var a = page.first(where: { $0.id == idA }), var b = page.first(where: { $0.id == idB }) else {
      throw TeaQLError.execution("Page lost the tested owner identities")
    }
    a.updateContactPhone("5550302"); b.updateContactPhone("5550402")
    _ = try await Q.tenantsWithMinimalFields().limit(1).comment("Run an unrelated query before deferred saves")
      .purpose("Verify deferred ownership survives Context reuse").executeForList(context)
    _ = try await a.auditAs("Save only A from the nonzero-offset page").save(context)
    let unchanged = try await Q.purchaseOrders().withIdIs(idB).limit(1).comment("Inspect B after deferred A save")
      .purpose("Verify unrelated root value and version remain untouched").executeForList(context)
    try require(unchanged.count == 1, "Missing independent B")
    try require(try E.purchaseOrder(unchanged[0]).contactPhone().eval() == "5550401", "A persisted B's pending mutation")
    try require(try E.purchaseOrder(unchanged[0]).version().eval() == 2, "A changed B's version")
    _ = try await b.auditAs("Save B later from the nonzero-offset page").save(context)
    let changed = try await Q.purchaseOrders().withIdIs(idB).limit(1).comment("Inspect the later deferred B save")
      .purpose("Verify B's pending mutation survived A's commit").executeForList(context)
    try require(changed.count == 1, "Missing committed B")
    try require(try E.purchaseOrder(changed[0]).contactPhone().eval() == "5550402", "A discarded B's pending mutation")
    try require(try E.purchaseOrder(changed[0]).version().eval() == 3, "B was not saved exactly once")
    struct Result: Encodable {
      let language = "swift", passed = true, pageOffset = 1, pageSize = 2
      let exactCount: Int
      let pageRootIsolation = true, deferredSaveAfterContextReuse = true, siblingPendingMutationRetained = true
      let streamProfile = "not-exposed"
    }
    print("CORE_MUTATION_PAGING=" + String(decoding: try JSONEncoder().encode(Result(exactCount: before.count + 1)), as: UTF8.self))
  }
}
