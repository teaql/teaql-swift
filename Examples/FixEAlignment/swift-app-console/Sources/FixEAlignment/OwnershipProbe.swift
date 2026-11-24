import Foundation
import GeneratedTeaQL
import TeaQLCore

enum OwnershipProbe {
  static func require(_ value: Bool, _ message: String) throws {
    if !value { throw TeaQLError.execution(message) }
  }

  static func verify(_ context: UserContext) async throws {
    let before = try await Q.purchaseOrders().limit(20).comment("Inspect the initial ownership fixture")
      .purpose("Verify independent roots never share pending mutations").executeForList(context)
    var first = try await Q.purchaseOrders().comment("Prepare independent new owner A")
      .purpose("Verify Context does not own mutation ledgers").newEntity(context)
    var second = try await Q.purchaseOrders().comment("Prepare independent new owner B")
      .purpose("Verify Context does not own mutation ledgers").newEntity(context)
    first.updateContactPhone("5550300"); second.updateContactPhone("5550400")
    let savedA = try await first.auditAs("Save only independent new owner A").save(context)
    let initial = try await Q.purchaseOrders().limit(20).comment("Inspect A's save before saving B")
      .purpose("Verify the unsaved new owner did not leak into persistence").executeForList(context)
    try require(initial.count == before.count + 1, "Saving A leaked new B")
    let savedB = try await second.auditAs("Explicitly save independent new owner B").save(context)
    let batch = try await Q.purchaseOrders().limit(20).comment("Load independent owners in one batch")
      .purpose("Verify independently saveable list roots retain separate mutation boundaries").executeForList(context)
    try require(batch.count == before.count + 2, "Missing independent batch roots")
    guard var ownerA = batch.first(where: { $0.id == savedA.id }),
          var ownerB = batch.first(where: { $0.id == savedB.id }) else {
      throw TeaQLError.execution("Batch identity changed")
    }
    ownerA.updateContactPhone("5550301"); ownerB.updateContactPhone("5550401")
    _ = try await ownerA.auditAs("Save only A from the multi-root query result").save(context)
    let unchanged = try await Q.purchaseOrders().withIdIs(savedB.id).limit(1)
      .comment("Inspect B after saving A").purpose("Verify A neither persists nor commits B").executeForList(context)
    try require(unchanged.count == 1, "Missing independent B")
    try require(try E.purchaseOrder(unchanged[0]).contactPhone().eval() == "5550400", "A persisted B's pending change")
    try require(try E.purchaseOrder(unchanged[0]).version().eval() == 1, "A changed B's version")
    _ = try await ownerB.auditAs("Save B after A without discarding its pending mutation").save(context)
    let changed = try await Q.purchaseOrders().withIdIs(savedB.id).limit(1)
      .comment("Inspect the later independent B save").purpose("Verify B's mutation survived A's save").executeForList(context)
    try require(changed.count == 1, "Missing committed B")
    try require(try E.purchaseOrder(changed[0]).contactPhone().eval() == "5550401", "A discarded B's pending mutation")
    try require(try E.purchaseOrder(changed[0]).version().eval() == 2, "B was not saved exactly once")
    try await PageOwnershipProbe.verify(context, idA: savedA.id, idB: savedB.id)
    struct Result: Encodable {
      let language = "swift", passed = true, independentNewRoots = true
      let batchRootIsolation = true, siblingVersionUnchanged = true, siblingPendingMutationRetained = true
    }
    print("CORE_MUTATION_OWNERSHIP=" + String(decoding: try JSONEncoder().encode(Result()), as: UTF8.self))
  }
}
