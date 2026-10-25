import Foundation
import Testing
@testable import TeaQLCore

@Suite("Graph preparation before provider admission")
struct GraphPreparationTests {
  private let descriptor = EntityDescriptor(name: "PreparationProbe", table: "preparation_probe", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "value", type: .double),
  ])

  @Test func rejectedWholeGraphPreparationNeverBeginsOrRollsBackATransaction() async throws {
    for number in [Double.nan, .infinity, -.infinity] {
      let provider = PreparationProvider(), clock = PreparationClock(), callbacks = PreparationLog()
      let context = UserContext(queryExecutor: provider, mutationExecutor: provider,
        requestPolicy: RequestPolicy { $0 }, businessClock: clock)
      let good = mutation(1), bad = mutation(number)
      do {
        try await context.executeGraphSave(comment: "reject the second graph node", preparing: { context, session in
          try session.afterRollback { callbacks.append("parent") }
          try session.afterRollback { callbacks.append("child") }
          _ = try context.preflightMutation(good)
          _ = try context.preflightMutation(bad)
        }) { context, _ in
          _ = try await context.execute(good)
          _ = try await context.execute(bad)
        }
        Issue.record("nonfinite graph reached execution")
      } catch is CheckException { }
      #expect(await provider.counts == PreparationCounts())
      #expect(callbacks.values == ["child", "parent"])
      #expect(clock.reads == 1)
    }
  }

  @Test func preparationCannotQueryCountMutateBootstrapOrUseAnExecutorEscape() async throws {
    for route in 0..<8 {
      let provider = PreparationProvider()
      let context = UserContext(queryExecutor: provider, mutationExecutor: provider, requestPolicy: RequestPolicy { $0 })
      let command = mutation(1), query = query()
      do {
        try await context.executeGraphSave(comment: "check preparation capability", preparing: { guarded, _ in
          switch route {
          case 0: _ = try await guarded.execute(query)
          case 1: _ = try await guarded.count(query)
          case 2: _ = try await guarded.execute(command)
          case 3: try await guarded.ensureSchema(RuntimeModule(name: "probe", entities: [descriptor]))
          case 4: _ = try await guarded.queryExecutor.execute(QueryRequest(query: query))
          case 5: _ = try await guarded.mutationExecutor.execute(MutationRequest(mutation: command))
          case 6: _ = try await context.execute(query) // original Context, same task/gate
          default: _ = try await context.count(query)
          }
        }) { _, _ in Issue.record("illegal preparation reached execution") }
        Issue.record("provider access was allowed during preparation")
      } catch let error as TeaQLError {
        #expect(error == .execution("GRAPH_PREPARATION_CANNOT_ACCESS_PROVIDER"))
      }
      #expect(await provider.counts == PreparationCounts())
    }
  }

  @Test func policyDenialReviewsAllNodesBeforeTransactionEntry() async throws {
    let provider = PreparationProvider(), log = PreparationLog()
    let context = UserContext(queryExecutor: provider, mutationExecutor: provider, requestPolicy: RequestPolicy { $0 },
      mutationPolicyRegistry: DelegatingMutationPolicyRegistry { _ in PreparationDeny(log: log) })
    let first = mutation(1), second = mutation(2)
    do {
      try await context.executeGraphSave(comment: "review both proposed nodes", preparing: { context, _ in
        _ = try context.preflightMutation(first)
        _ = try context.preflightMutation(second)
      }) { context, _ in
        _ = try await context.execute(first)
        _ = try await context.execute(second)
      }
      Issue.record("denying policy allowed execution")
    } catch let error as MutationPolicyError {
      #expect(error == .denied(code: "DENY_PREPARED", message: "not approved"))
    }
    #expect(log.values == ["review:2"])
    #expect(await provider.counts == PreparationCounts())
  }

  @Test func aCorrectedGraphCanRetryAfterPreparationFailure() async throws {
    let provider = PreparationProvider(), clock = PreparationClock()
    let context = UserContext(queryExecutor: provider, mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 }, businessClock: clock)
    do {
      try await context.executeGraphSave(comment: "invalid first attempt", preparing: { context, _ in
        _ = try context.preflightMutation(mutation(.infinity))
      }) { _, _ in Issue.record("rejected graph executed") }
    } catch is CheckException { }
    #expect(await provider.counts == PreparationCounts())
    let command = mutation(7.25)
    let result = try await context.executeGraphSave(comment: "corrected independent retry", preparing: { context, _ in
      _ = try context.preflightMutation(command)
    }) { context, _ in try await context.execute(command) }
    #expect(result.persistedRecord?["value"] == .double(7.25))
    #expect(await provider.counts == PreparationCounts(begin: 1, mutate: 1, commit: 1))
    #expect(clock.reads == 2)
  }

  @Test func batchPreparationRejectsBeforeItsFirstTransaction() async throws {
    let provider = PreparationProvider()
    let context = UserContext(queryExecutor: provider, mutationExecutor: provider, requestPolicy: RequestPolicy { $0 })
    do {
      _ = try await context.execute(MutationBatchRequest(mutations: [mutation(1), mutation(.infinity)],
        comment: "reject invalid second batch child"))
      Issue.record("invalid batch reached provider")
    } catch is CheckException { }
    #expect(await provider.counts == PreparationCounts())
  }

  @Test func childOnlyPreparationKeepsTheDeclaredParentPolicyEntryPoint() async throws {
    let provider = PreparationProvider(), log = PreparationLog()
    let context = UserContext(queryExecutor: provider, mutationExecutor: provider, requestPolicy: RequestPolicy { $0 },
      mutationPolicyRegistry: DelegatingMutationPolicyRegistry { _ in PreparationRootPolicy(log: log) })
    let child = EntityDescriptor(name: "PreparationChild", table: "preparation_child", properties: descriptor.properties)
    let command = Mutation(kind: .update, entity: child, id: .int(2), values: ["value": .double(3)],
      expectedVersion: 1, auditReason: "edit only the reached child")
    try await context.executeGraphSave(comment: "save the declared parent graph", rootEntityType: descriptor.name,
      preparing: { context, _ in _ = try context.preflightMutation(command) }) { context, _ in
        _ = try await context.execute(command)
    }
    #expect(log.values == ["PreparationProbe|PreparationProbe.saveGraph|PreparationChild"])
    #expect(await provider.counts == PreparationCounts(begin: 1, mutate: 1, commit: 1))
  }

  private func mutation(_ value: Double) -> Mutation {
    Mutation(kind: .create, entity: descriptor, values: ["value": .double(value)], auditReason: "prepare an explicit graph")
  }
  private func query() -> SelectQuery {
    var value = SelectQuery(entity: descriptor); value.comment = "inspect a bounded probe"
    value.purpose = "verify preparation capability"; value.limit = 1; return value
  }
}

private struct PreparationCounts: Sendable, Equatable {
  var begin = 0, mutate = 0, commit = 0, rollback = 0, query = 0
}
private actor PreparationProvider: QueryExecutor, GraphTransactionExecutor {
  private(set) var counts = PreparationCounts()
  func beginGraphTransaction() async throws { counts.begin += 1 }
  func commitGraphTransaction() async throws { counts.commit += 1 }
  func rollbackGraphTransaction() async throws { counts.rollback += 1 }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    counts.mutate += 1; return MutationResult(affectedRows: 1, persistedRecord: request.mutation.values)
  }
  func execute(_ request: QueryRequest) async throws -> QueryResult {
    counts.query += 1; return QueryResult(records: [], backend: "preparation-spy")
  }
  func count(_ request: QueryRequest) async throws -> Int { counts.query += 1; return 0 }
}
private final class PreparationClock: @unchecked Sendable, BusinessClock {
  private let lock = NSLock(); private var count = 0
  func now() -> Date { lock.withLock { count += 1; return Date(timeIntervalSince1970: 1_792_488_600.125) } }
  var reads: Int { lock.withLock { count } }
}
private final class PreparationLog: @unchecked Sendable {
  private let lock = NSLock(); private var items: [String] = []
  func append(_ item: String) { lock.withLock { items.append(item) } }
  var values: [String] { lock.withLock { items } }
}
private struct PreparationDeny: MutationPolicy {
  let log: PreparationLog
  let identity = MutationPolicyIdentity(policyID: "deny-prepared", version: "1", fingerprint: "local-fixture")
  func review(context: UserContext, plan: MutationPlan) throws -> MutationPolicyDecision {
    log.append("review:\(plan.operations.count)")
    return MutationPolicyDecision(verdict: .deny, code: "DENY_PREPARED", message: "not approved")
  }
}
private struct PreparationRootPolicy: MutationPolicy {
  let log: PreparationLog
  let identity = MutationPolicyIdentity(policyID: "parent-entry", version: "1", fingerprint: "local-fixture")
  func review(context: UserContext, plan: MutationPlan) throws -> MutationPolicyDecision {
    log.append("\(plan.rootEntityType)|\(plan.requestKey)|\(plan.operations[0].entity)")
    return MutationPolicyDecision(verdict: .allow)
  }
}
