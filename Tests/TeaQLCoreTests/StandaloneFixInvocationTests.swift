import Foundation
import Testing
@testable import TeaQLCore

@Suite("Invocation-owned Fix clock and evidence")
struct StandaloneFixInvocationTests {
  @Test func repeatedReadsShareOneInstantButIndependentStandaloneCallsCaptureAgain() throws {
    let f = try ScopeFixture()
    _ = try f.context.preflightMutation(f.parent)
    let previous = f.context.lastFixEvidence
    _ = try f.context.preflightMutation(f.child)
    #expect(f.clock.calls == 2)
    #expect(f.observer.times == [Array(repeating: 1000, count: 3), Array(repeating: 1001, count: 3)])
    #expect(previous.map(\.entityType) == ["ScopeParent"])
    #expect(f.context.lastFixEvidence.map(\.entityType) == ["ScopeChild"])
    #expect(f.context.fixTime.timeIntervalSince1970 == 1002)
  }

  @Test func standaloneAuditAndCheckerUseTheSameClockSnapshot() async throws {
    let f = try ScopeFixture()
    _ = try await f.context.execute(f.parent)
    #expect(f.clock.calls == 1)
    #expect(f.observer.times == [Array(repeating: 1000, count: 3)])
    #expect(f.observer.audits == [1000])
    #expect(f.context.lastFixEvidence.map(\.entityType) == ["ScopeParent"])
    #expect(f.provider.events == ["mutate:ScopeParent"])
  }

  @Test func failedStandalonePreservesTheErrorAndClosesItsCapturedCapability() throws {
    let f = try ScopeFixture(), original = ScopeFailure()
    f.observer.failNext(original)
    do { _ = try f.context.preflightMutation(f.parent); Issue.record("missing injected failure") }
    catch { #expect(error as? ScopeFailure === original) }
    let expired = try #require(f.observer.captured)
    #expect(throws: (any Error).self) { _ = try expired.preflightMutation(f.child) }
    #expect(f.clock.calls == 1 && f.observer.times.count == 1)
    let previous = f.context.lastFixEvidence
    _ = try f.context.preflightMutation(f.child)
    #expect(f.clock.calls == 2)
    #expect(f.observer.times == [Array(repeating: 1000, count: 3), Array(repeating: 1001, count: 3)])
    #expect(previous.map(\.entityType) == ["ScopeParent"])
    #expect(f.provider.events.isEmpty)
  }

  @Test func closedGraphContextCannotRunCheckerBeforeItIsRejected() async throws {
    let f = try ScopeFixture()
    try await f.graph()
    let expired = try #require(f.observer.captured)
    #expect(throws: (any Error).self) { _ = try expired.preflightMutation(f.parent) }
    #expect(f.clock.calls == 1 && f.observer.times.count == 2)
    try await f.graph()
    #expect(f.clock.calls == 2)
    #expect(f.observer.times == [Array(repeating: 1000, count: 3), Array(repeating: 1000, count: 3),
      Array(repeating: 1001, count: 3), Array(repeating: 1001, count: 3)])
  }

  @Test func aForeignStandaloneDoesNotInheritTheGraphClockOrEvidence() async throws {
    let f = try ScopeFixture(), foreign = try ScopeFixture(base: 9000)
    let p = f.parent, c = f.child, other = foreign.parent
    try await f.context.executeGraphSave(comment: "isolate the foreign standalone Fix", preparing: { context, _ in
      _ = try context.preflightMutation(p)
      _ = try foreign.context.preflightMutation(other)
      _ = try context.preflightMutation(c)
    }) { context, _ in
      _ = try await context.execute(p)
      _ = try await context.execute(c)
    }
    #expect(f.clock.calls == 1 && foreign.clock.calls == 1)
    #expect(f.observer.times == [Array(repeating: 1000, count: 3), Array(repeating: 1000, count: 3)])
    #expect(foreign.observer.times == [Array(repeating: 9000, count: 3)])
    #expect(f.context.lastFixEvidence.map(\.entityType) == ["ScopeParent", "ScopeChild"])
    #expect(foreign.context.lastFixEvidence.map(\.entityType) == ["ScopeParent"])
    #expect(foreign.provider.events.isEmpty)
  }

  @Test func taskCancellationRollsBackAndANewTaskCanRetryWithAFreshInstant() async throws {
    let f = try ScopeFixture()
    f.provider.cancelNextMutation()
    let attempt = Task { try await f.graph() }
    do { try await attempt.value; Issue.record("cancelled graph committed") }
    catch { #expect(error is CancellationError) }
    #expect(!Task.isCancelled)
    let previous = f.context.lastFixEvidence
    #expect(f.provider.events == ["begin", "mutate:ScopeParent", "rollback"])
    #expect(f.observer.audits.isEmpty)
    try await f.graph()
    #expect(f.clock.calls == 2)
    #expect(f.observer.times == [Array(repeating: 1000, count: 3), Array(repeating: 1000, count: 3),
      Array(repeating: 1001, count: 3), Array(repeating: 1001, count: 3)])
    #expect(f.provider.events == ["begin", "mutate:ScopeParent", "rollback", "begin",
      "mutate:ScopeParent", "mutate:ScopeChild", "commit"])
    #expect(f.observer.audits == [1001, 1001])
    #expect(previous.map(\.entityType) == ["ScopeParent", "ScopeChild"])
  }

  @Test func clockCallbackMayInspectCompletedReceiptsWithoutAStateLockDeadlock() async throws {
    let f = try ScopeFixture(), context = f.context
    f.clock.inspecting { _ = context.lastFixEvidence }
    defer { f.clock.clearInspection() }
    try await f.graph()
    #expect(f.clock.calls == 1 && f.observer.times.count == 2)
  }
}

private final class ScopeFailure: Error, @unchecked Sendable {}
private final class ScopeClock: BusinessClock, @unchecked Sendable {
  private let lock = NSLock()
  private let base: TimeInterval
  private var count = 0
  private var inspect: (@Sendable () -> Void)?
  init(base: TimeInterval) { self.base = base }
  func inspecting(_ action: @escaping @Sendable () -> Void) { lock.withLock { inspect = action } }
  func clearInspection() { lock.withLock { inspect = nil } }
  func now() -> Date {
    let (tick, callback) = lock.withLock { let tick = count; count += 1; return (tick, inspect) }
    callback?()
    return Date(timeIntervalSince1970: base + Double(tick))
  }
  var calls: Int { lock.withLock { count } }
}
private final class ScopeObserver: EntityChecker, AuditSink, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [[TimeInterval]] = [], auditValues: [TimeInterval] = []
  private var failure: ScopeFailure?, saved: UserContext?
  func failNext(_ error: ScopeFailure) { lock.withLock { failure = error } }
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    let time = [now.timeIntervalSince1970, context.fixTime.timeIntervalSince1970, context.fixTime.timeIntervalSince1970]
    let error = lock.withLock {
      values.append(time); saved = context; let error = failure; failure = nil; return error
    }
    context.recordFixEvidence(FixEvidence(entityType: mutation.entity.name, modelPath: "name", source: .clock, sourceLabel: "BusinessClock"))
    if let error { throw error }
    return []
  }
  func record(_ event: AuditEvent) async throws { lock.withLock { auditValues.append(event.occurredAt.timeIntervalSince1970) } }
  var times: [[TimeInterval]] { lock.withLock { values } }
  var audits: [TimeInterval] { lock.withLock { auditValues } }
  var captured: UserContext? { lock.withLock { saved } }
}
private final class ScopeProvider: QueryExecutor, GraphTransactionExecutor, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = [], shouldCancel = false
  func cancelNextMutation() { lock.withLock { shouldCancel = true } }
  func beginGraphTransaction() async throws { lock.withLock { values.append("begin") } }
  func commitGraphTransaction() async throws { lock.withLock { values.append("commit") } }
  func rollbackGraphTransaction() async throws { lock.withLock { values.append("rollback") } }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    let cancel = lock.withLock {
      values.append("mutate:" + request.mutation.entity.name)
      let cancel = shouldCancel; shouldCancel = false; return cancel
    }
    if cancel { withUnsafeCurrentTask { $0?.cancel() } }
    return MutationResult(affectedRows: 1, persistedRecord: request.mutation.values)
  }
  func execute(_ request: QueryRequest) async throws -> QueryResult { QueryResult(records: [], backend: "scope-fixture") }
  var events: [String] { lock.withLock { values } }
}
private final class ScopeFixture: @unchecked Sendable {
  let clock: ScopeClock, observer = ScopeObserver(), provider = ScopeProvider()
  let context: UserContext, parent: Mutation, child: Mutation
  init(base: TimeInterval = 1000) throws {
    clock = ScopeClock(base: base)
    func descriptor(_ name: String) -> EntityDescriptor {
      EntityDescriptor(name: name, table: name.lowercased(), properties: [PropertyDescriptor(name: "id", type: .int, isID: true), PropertyDescriptor(name: "name", type: .string)])
    }
    let p = descriptor("ScopeParent"), c = descriptor("ScopeChild")
    var runtime = TeaQLRuntime()
    try runtime.install(RuntimeModule(name: "invocation test", entities: [p,c], checkers: [p.name: observer,c.name: observer]))
    context = UserContext(runtime: runtime, queryExecutor: provider, mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 }, auditSink: observer, businessClock: clock)
    parent = Mutation(kind: .create, entity: p, values: ["name": .string("parent")], auditReason: "test a standalone parent")
    child = Mutation(kind: .create, entity: c, values: ["name": .string("child")], auditReason: "test a standalone child")
  }
  func graph() async throws {
    let p = parent, c = child
    try await context.executeGraphSave(comment: "test a bounded two-node graph", preparing: { context, _ in
      _ = try context.preflightMutation(p); _ = try context.preflightMutation(c)
    }) { context, _ in _ = try await context.execute(p); _ = try await context.execute(c) }
  }
}
