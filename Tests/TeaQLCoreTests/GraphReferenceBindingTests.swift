import Foundation
import Testing
@_spi(Generated) @testable import TeaQLCore

@Suite("Reviewed type-qualified graph reference bindings")
struct GraphReferenceBindingTests {
  @Test func newEntityPreflightUsesCanonicalIntentionInsteadOfAStaleScalarDefault() async throws {
    let f = try ReferenceFixture()
    #expect(f.child.toRecord()["parent_id"] == .int(0))
    try await f.context.executeGraphSave(comment: "preserve the new entity's normalized intention", preparing: { context, _ in
      try AuditedEntity(entity: f.parent, reason: "save the reviewed relationship").preflight(context)
      try context.bindGraphReference(f.child, field: "parent_id", to: f.parent)
      try AuditedEntity(entity: f.child, reason: "save the reviewed relationship").preflight(context)
    }) { context, _ in
      _ = try await f.execute(f.parent, context)
      _ = try await f.execute(f.child, context)
    }
    #expect(f.provider.writes[1].values["parent_id"] == .int(101))
    #expect(f.child.toRecord()["parent_id"] == .int(0))
    #expect(f.ledger.change(f.child.teaqlEntityKey)["parent_id"] == .int(-1))
  }

  @Test func parentChildGrandchildResolveWithoutChangingCallerLedgers() async throws {
    let f = try ReferenceFixture(), before = f.ledger.snapshot()
    try await f.save()
    let writes = f.provider.writes
    #expect(writes.count == 3)
    #expect(writes[1].values["parent_id"] == .int(101))
    #expect(writes[2].values["child_id"] == .int(102))
    #expect(f.ledger.snapshot() == before)
    let operations = try #require(f.policy.plans.first).operations
    #expect(operations[1].changedValues["parent_id"] == .int(-1))
    #expect(operations[1].references == ["parent_id": MutationPolicyReference(entity: "ReferenceParent", id: .int(-1))])
    #expect(operations[2].references == ["child_id": MutationPolicyReference(entity: "ReferenceChild", id: .int(-1))])
    #expect(operations[0].graphIdentity == operations[1].references?["parent_id"])
    #expect(operations[1].graphIdentity == operations[2].references?["child_id"])
    #expect(operations.allSatisfy { $0.entityID == nil })
    #expect(f.provider.events == ["begin", "write:ReferenceParent", "write:ReferenceChild", "write:ReferenceGrandchild", "commit"])
  }

  @Test func aDeclaredBindingDoesNotBlessAnExecutionTimeFKChange() async throws {
    let f = try ReferenceFixture()
    do {
      try await f.context.executeGraphSave(comment: "reject an unreviewed FK", preparing: { context, _ in
        try f.prepare(context)
      }) { context, _ in
        _ = try await f.execute(f.parent, context)
        var changed = f.command(f.child); changed.values["parent_id"] = .int(101)
        _ = try await context.execute(changed, ledgerRoot: f.ledger, ledgerKey: f.child.teaqlEntityKey)
      }
      Issue.record("guessed assigned FK bypassed reviewed values")
    } catch let error as MutationPolicyError { #expect(error == .operationOutsideReviewedPlan) }
    #expect(f.provider.writes.count == 1)
    #expect(f.provider.events.last == "rollback")
  }

  @Test func wrongTargetTypeAndUnrelatedLedgerAreRejectedBeforeProviderEntry() async throws {
    for wrongType in [false,true] {
      let f = try ReferenceFixture(), foreign = ReferenceModel<ParentKind>(root: EntityRoot())
      do {
        try await f.context.executeGraphSave(comment: "reject a foreign binding", preparing: { context, _ in
          _ = try f.preflight(f.parent, context)
          if wrongType { try context.bindGraphReference(f.child, field: "parent_id", to: f.child) }
          else { try context.bindGraphReference(f.child, field: "parent_id", to: foreign) }
        }) { _, _ in Issue.record("invalid binding reached execution") }
        Issue.record("invalid target was accepted")
      } catch let error as MutationPolicyError { #expect(error == .operationOutsideReviewedPlan) }
      #expect(f.provider.events.isEmpty && f.policy.plans.isEmpty)
    }
  }

  @Test func onlyCanonicalRelationFieldsCanDeclareBindings() async throws {
    for field in ["unknown","value","parentId"] {
      let f = try ReferenceFixture()
      do {
        try await f.context.executeGraphSave(comment: "reject an invalid reference field", preparing: { context, _ in
          _ = try f.preflight(f.parent, context)
          try context.bindGraphReference(f.child, field: field, to: f.parent)
        }) { _, _ in Issue.record("invalid reference field reached execution") }
        Issue.record("invalid field was accepted")
      } catch let error as MutationPolicyError { #expect(error == .operationOutsideReviewedPlan) }
      #expect(f.provider.events.isEmpty)
    }
  }

  @Test func anUnreviewedOrUnpersistedTargetCannotResolveAReference() async throws {
    for unreviewed in [false,true] {
      let f = try ReferenceFixture()
      do {
        try await f.context.executeGraphSave(comment: "require an actual reviewed target", preparing: { context, _ in
          if !unreviewed { _ = try f.preflight(f.parent, context) }
          try context.bindGraphReference(f.child, field: "parent_id", to: f.parent)
          _ = try f.preflight(f.child, context)
        }) { context, _ in _ = try await f.execute(f.child, context) }
        Issue.record("unavailable target resolved")
      } catch let error as MutationPolicyError { #expect(error == .operationOutsideReviewedPlan) }
      #expect(f.provider.writes.isEmpty)
      #expect(f.provider.events == (unreviewed ? [] : ["begin","rollback"]))
    }
  }

  @Test func declarationAfterReviewOrAfterGraphCompletionCannotAddAuthority() async throws {
    let f = try ReferenceFixture(), captured = ReferenceContext()
    do {
      try await f.context.executeGraphSave(comment: "reject a late declaration", preparing: { context, _ in
        _ = try f.preflight(f.parent, context); captured.put(context)
      }) { context, _ in try context.bindGraphReference(f.child, field: "parent_id", to: f.parent) }
      Issue.record("late binding was accepted")
    } catch let error as MutationPolicyError { #expect(error == .preflightAfterReview) }
    let old = try #require(captured.get())
    #expect(throws: (any Error).self) { try old.bindGraphReference(f.child, field: "parent_id", to: f.parent) }
    #expect(f.provider.writes.isEmpty)
  }

  @Test func conflictingTargetsAndFixRetargetingFailBeforePolicyOrTransaction() async throws {
    for route in 0..<3 {
      let f = try ReferenceFixture(retarget: route > 0 ? route : nil)
      do {
        try await f.context.executeGraphSave(comment: "retain the declared target", preparing: { context, _ in
          _ = try f.preflight(f.parent, context)
          try context.bindGraphReference(f.child, field: "parent_id", to: f.parent)
          if route == 0 {
            let another = ReferenceModel<ParentKind>(root: f.ledger, temporary: -2)
            _ = try f.preflight(another, context)
            try context.bindGraphReference(f.child, field: "parent_id", to: another)
          }
          _ = try f.preflight(f.child, context)
        }) { _, _ in Issue.record("changed reference reached execution") }
        Issue.record("reference retargeting was accepted")
      } catch let error as MutationPolicyError { #expect(error == .operationOutsideReviewedPlan) }
      #expect(f.provider.events.isEmpty && f.policy.plans.isEmpty)
    }
  }

  @Test func deniedPolicySeesTypedReferencesAndStopsBeforeTransaction() async throws {
    let f = try ReferenceFixture(deny: true)
    do { try await f.save(); Issue.record("denied plan executed") }
    catch let error as MutationPolicyError { #expect(error == .denied(code: "REFERENCE_DENIED", message: "rejected")) }
    #expect(f.provider.events.isEmpty)
    #expect(f.policy.plans.first?.operations[1].references?["parent_id"]?.entity == "ReferenceParent")
  }

  @Test func failedTargetResultsDoNotAuthorizeChildrenAndRetriesDoNotReuseOldIDs() async throws {
    for zeroResult in [false,true] {
      let f = try ReferenceFixture()
      f.provider.failNext(zeroResult: zeroResult)
      do { try await f.save(); Issue.record("failed graph committed") } catch { }
      #expect(f.provider.events.last == "rollback")
      try await f.save()
      let child = try #require(f.provider.writes.last(where: { $0.entity.name == "ReferenceChild" }))
      let parent = try #require(f.provider.writes.last(where: { $0.entity.name == "ReferenceParent" }))
      #expect(child.values["parent_id"] == parent.values["assigned_for_test"])
      #expect(child.values["parent_id"] != .int(101))
    }
  }

  @Test func equalTemporaryIDsOfDifferentTypesKeepSeparateBindings() async throws {
    let f = try ReferenceFixture()
    try await f.save()
    #expect(f.parent.teaqlEntityKey.id == f.child.teaqlEntityKey.id)
    #expect(f.provider.writes[1].values["parent_id"] == .int(101))
    #expect(f.provider.writes[2].values["child_id"] == .int(102))
  }

  @Test func policyCannotEditTheCallerLedgerBehindABinding() async throws {
    let f = try ReferenceFixture(editAfterReview: true)
    do { try await f.save(); Issue.record("changed ledger reached execution") }
    catch let error as MutationPolicyError { #expect(error == .operationOutsideReviewedPlan) }
    #expect(f.provider.events.isEmpty)
    #expect(f.ledger.change(f.child.teaqlEntityKey)["parent_id"] == .int(999))
  }
}

private protocol ReferenceKind: Sendable { static var descriptor: EntityDescriptor { get } }
private enum ParentKind: ReferenceKind {
  static let descriptor = EntityDescriptor(name: "ReferenceParent", table: "parent", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true), PropertyDescriptor(name: "value", type: .double)])
}
private enum ChildKind: ReferenceKind {
  static let descriptor = EntityDescriptor(name: "ReferenceChild", table: "child", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true), PropertyDescriptor(name: "value", type: .double),
    PropertyDescriptor(name: "parentId", modelName: "parent_id", column: "parent_id", type: .int, isRelation: true, referencedEntity: "ReferenceParent")])
}
private enum GrandchildKind: ReferenceKind {
  static let descriptor = EntityDescriptor(name: "ReferenceGrandchild", table: "grandchild", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true), PropertyDescriptor(name: "value", type: .double),
    PropertyDescriptor(name: "childId", modelName: "child_id", column: "child_id", type: .int, isRelation: true, referencedEntity: "ReferenceChild")])
}
private struct ReferenceModel<K: ReferenceKind>: TeaQLMutationRootedEntity {
  static var descriptor: EntityDescriptor { K.descriptor }
  var id: Int64 = 0, version: Int64 = 0
  let temporary: Int64, teaqlEntityRoot: EntityRoot
  var teaqlEntityKey: EntityKey { EntityKey(entity: K.descriptor.name, id: .int(id == 0 ? temporary : id)) }
  init(root: EntityRoot, temporary: Int64 = -1) {
    self.temporary = temporary; teaqlEntityRoot = root
    root.markAsNew(teaqlEntityKey); root.set(teaqlEntityKey, field: "value", value: .double(7))
  }
  func toRecord() -> TeaQLRecord {
    var record: TeaQLRecord = ["id": .int(id), "value": .double(7)]
    for property in K.descriptor.properties where property.isRelation {
      record[property.modelName ?? property.name] = .int(0)
    }
    return record
  }
  static func from(record: TeaQLRecord) throws -> Self { throw TeaQLError.execution("native binding fixture has no hydration API") }
  init(from decoder: any Decoder) throws { throw TeaQLError.execution("native binding fixture has no wire API") }
  func encode(to encoder: any Encoder) throws { throw TeaQLError.execution("native binding fixture has no wire API") }
}
private final class ReferenceContext: @unchecked Sendable {
  private let lock = NSLock(); private var value: UserContext?
  func put(_ context: UserContext) { lock.withLock { value = context } }
  func get() -> UserContext? { lock.withLock { value } }
}
private final class ReferencePolicy: MutationPolicy, @unchecked Sendable {
  let identity = MutationPolicyIdentity(policyID: "references", version: "1", fingerprint: "test")
  private let lock = NSLock(); private var values: [MutationPlan] = []
  let deny: Bool, edit: EntityRoot?
  init(deny: Bool, edit: EntityRoot?) { self.deny = deny; self.edit = edit }
  func review(context: UserContext, plan: MutationPlan) throws -> MutationPolicyDecision {
    lock.withLock { values.append(plan) }
    edit?.set(EntityKey(entity: "ReferenceChild", id: .int(-1)), field: "parent_id", value: .int(999))
    return MutationPolicyDecision(verdict: deny ? .deny : .allow, code: deny ? "REFERENCE_DENIED" : nil, message: deny ? "rejected" : nil)
  }
  var plans: [MutationPlan] { lock.withLock { values } }
}
private struct ReferenceFix: EntityChecker {
  let route: Int
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    if route == 1 { mutation.values["parent_id"] = .int(999) } else { mutation.values.removeValue(forKey: "parent_id") }
    return []
  }
}
private final class ReferenceProvider: QueryExecutor, GraphTransactionExecutor, @unchecked Sendable {
  private let lock = NSLock(); private var values: [Mutation] = [], log: [String] = [], serial: Int64 = 100
  private var fault = false, zero = false
  func failNext(zeroResult: Bool) { lock.withLock { fault = true; zero = zeroResult } }
  func beginGraphTransaction() async throws { lock.withLock { log.append("begin") } }
  func commitGraphTransaction() async throws { lock.withLock { log.append("commit") } }
  func rollbackGraphTransaction() async throws { lock.withLock { log.append("rollback") } }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    try lock.withLock {
      serial += 1
      if fault && (zero || request.mutation.entity.name == "ReferenceChild") {
        fault = false
        if zero { return MutationResult(affectedRows: 0) }
        throw TeaQLError.execution("injected child failure")
      }
      var recorded = request.mutation; recorded.values["assigned_for_test"] = .int(serial)
      values.append(recorded); log.append("write:" + recorded.entity.name)
      var record = request.mutation.values; record["id"] = .int(serial)
      return MutationResult(affectedRows: 1, generatedValues: ["id": .int(serial)], persistedRecord: record)
    }
  }
  func execute(_ request: QueryRequest) async throws -> QueryResult { QueryResult(records: [], backend: "native-reference-observer") }
  var writes: [Mutation] { lock.withLock { values } }
  var events: [String] { lock.withLock { log } }
}
private final class ReferenceFixture: @unchecked Sendable {
  let ledger = EntityRoot(), provider = ReferenceProvider()
  let parent: ReferenceModel<ParentKind>, child: ReferenceModel<ChildKind>, grandchild: ReferenceModel<GrandchildKind>
  let policy: ReferencePolicy, context: UserContext
  init(retarget: Int? = nil, deny: Bool = false, editAfterReview: Bool = false) throws {
    parent = ReferenceModel(root: ledger); child = ReferenceModel(root: ledger); grandchild = ReferenceModel(root: ledger)
    ledger.set(child.teaqlEntityKey, field: "parent_id", value: parent.teaqlEntityKey.id)
    ledger.set(grandchild.teaqlEntityKey, field: "child_id", value: child.teaqlEntityKey.id)
    policy = ReferencePolicy(deny: deny, edit: editAfterReview ? ledger : nil)
    var runtime = TeaQLRuntime()
    try runtime.install(RuntimeModule(name: "typed references", entities: [ParentKind.descriptor,ChildKind.descriptor,GrandchildKind.descriptor],
      checkers: retarget.map { [ChildKind.descriptor.name: ReferenceFix(route: $0)] } ?? [:]))
    let policy = self.policy
    context = UserContext(runtime: runtime, queryExecutor: provider, mutationExecutor: provider, requestPolicy: RequestPolicy { $0 },
      mutationPolicyRegistry: DelegatingMutationPolicyRegistry { _ in policy })
  }
  func command<K>(_ model: ReferenceModel<K>) -> Mutation {
    Mutation(kind: .create, entity: K.descriptor, values: ledger.change(model.teaqlEntityKey), auditReason: "save the reviewed relationship")
  }
  func preflight<K>(_ model: ReferenceModel<K>, _ context: UserContext) throws -> Mutation {
    try context.preflightMutation(command(model), ledgerRoot: ledger, ledgerKey: model.teaqlEntityKey)
  }
  func execute<K>(_ model: ReferenceModel<K>, _ context: UserContext) async throws -> MutationResult {
    try await context.execute(command(model), ledgerRoot: ledger, ledgerKey: model.teaqlEntityKey)
  }
  func prepare(_ context: UserContext) throws {
    _ = try preflight(parent, context)
    try context.bindGraphReference(child, field: "parent_id", to: parent)
    _ = try preflight(child, context)
    try context.bindGraphReference(grandchild, field: "child_id", to: child)
    _ = try preflight(grandchild, context)
  }
  func save() async throws {
    try await context.executeGraphSave(comment: "save a declared three-level graph", preparing: { context, _ in try self.prepare(context) }) { context, _ in
      _ = try await self.execute(self.parent, context)
      _ = try await self.execute(self.child, context)
      _ = try await self.execute(self.grandchild, context)
    }
  }
}
