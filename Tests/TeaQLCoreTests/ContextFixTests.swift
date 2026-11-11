import Foundation
import Testing
@testable import TeaQLCore

private struct ContextFixUnusedExecutor: QueryExecutor, MutationExecutor {
  func execute(_ request: QueryRequest) async throws -> QueryResult { throw TeaQLError.execution("unexpected provider query") }
  func execute(_ request: MutationRequest) async throws -> MutationResult { throw TeaQLError.execution("unexpected provider mutation") }
}
private final class ContextFixProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  private var retained: UserContext?
  func record(_ context: UserContext) { lock.withLock { calls += 1; retained = context } }
  var count: Int { lock.withLock { calls } }
  var context: UserContext? { lock.withLock { retained } }
}
private struct ContextFixTestResolver: ContextFixResolver {
  let probe: ContextFixProbe
  let mode: String
  func resolve(context: UserContext, input: ContextFixInput) throws -> TeaQLValue {
    probe.record(context)
    if input.function == "now" { return .timestamp(Int64(input.now.timeIntervalSince1970 * 1_000)) }
    if mode == "throw" { throw TeaQLError.execution("PRIVATE_CONTEXT_PROVIDER_SECRET") }
    if mode == "wrong-type" { return .int(4) }
    return .string("prepared-IP")
  }
}
private struct ContextFixTestChecker: EntityChecker {
  let reject: Bool
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    if mutation.kind == .create { try ContextFix.apply(context, mutation: &mutation, now: now, field: "born_at", function: "now") }
    try ContextFix.apply(context, mutation: &mutation, now: now, field: "touched_at", function: "now")
    try ContextFix.apply(context, mutation: &mutation, now: now, field: "source_ip", function: "ip")
    return reject ? [CheckResult(ruleID: "required", location: .property("name"))] : []
  }
}

@Suite("Context-derived values supplement business intent")
struct ContextFixTests {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private var descriptor: EntityDescriptor {
    EntityDescriptor(name: "Probe", table: "probe", properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "version", type: .int, isVersion: true),
      PropertyDescriptor(name: "name", type: .string),
      PropertyDescriptor(name: "bornAt", modelName: "born_at", type: .timestamp, createFunction: "now"),
      PropertyDescriptor(name: "touchedAt", modelName: "touched_at", type: .timestamp, createFunction: "now", updateFunction: "now"),
      PropertyDescriptor(name: "sourceIp", modelName: "source_ip", type: .string, createFunction: "ip", updateFunction: "ip")
    ])
  }
  private func context(_ probe: ContextFixProbe, mode: String = "normal", reject: Bool = false) throws -> UserContext {
    var runtime = TeaQLRuntime()
    try runtime.install(RuntimeModule(name: "Context Fix", entities: [descriptor], checkers: ["Probe": ContextFixTestChecker(reject: reject)]))
    return UserContext(runtime: runtime, queryExecutor: ContextFixUnusedExecutor(), mutationExecutor: ContextFixUnusedExecutor(),
      requestPolicy: RequestPolicy { $0 }, querySQLLogEnabled: false, mutationSQLLogEnabled: false,
      businessClock: FixedBusinessClock(now), contextFixResolver: ContextFixTestResolver(probe: probe, mode: mode))
  }
  private func update(_ values: TeaQLRecord, old: TeaQLRecord = [:]) -> Mutation {
    var mutation = Mutation(kind: .update, entity: descriptor, id: .int(1), values: values, expectedVersion: 7, auditReason: "check frozen Context eligibility")
    mutation.loadedValues = old; return mutation
  }

  @Test(arguments: ["empty", "managed", "restored"])
  func noBusinessIntentDoesNotResolveContext(_ kind: String) throws {
    let probe = ContextFixProbe(), ctx = try context(probe)
    let values: TeaQLRecord = kind == "managed" ? ["touched_at": .timestamp(17)] : kind == "restored" ? ["name": .string("same")] : [:]
    let fixed = try ctx.preflightMutation(update(values, old: ["name": .string("same")]))
    #expect(probe.count == 0); #expect(fixed.values == values)
  }

  @Test func createWithoutCallerDirtyFieldsAndUpdatePreservesCreateOnlyValues() throws {
    let probe = ContextFixProbe(), ctx = try context(probe)
    let created = try ctx.preflightMutation(Mutation(kind: .create, entity: descriptor, values: [:], auditReason: "create Context defaults"))
    #expect(probe.count == 3); #expect(created.values["born_at"] == .timestamp(1_700_000_000_000))
    let fixed = try ctx.preflightMutation(update(["name": .string("edit"), "born_at": .timestamp(17)]))
    #expect(probe.count == 5); #expect(fixed.values["born_at"] == .timestamp(17)); #expect(fixed.values["source_ip"] == .string("prepared-IP"))
  }

  @Test(arguments: ["throw", "wrong-type"])
  func providerFailureIsSafeFieldLocalAndDoesNotChangeCallerLedger(_ mode: String) throws {
    let probe = ContextFixProbe(), ctx = try context(probe, mode: mode), ledger = EntityRoot(), key = EntityKey(entity: "Probe", id: .int(1))
    ledger.set(key, field: "name", value: .string("caller edit"))
    do {
      _ = try ctx.preflightMutation(update(ledger.change(key)), ledgerRoot: ledger, ledgerKey: key)
      Issue.record("Provider failure must reject")
    } catch let error as CheckException {
      #expect(error.violations.count == 1); #expect(error.violations.first?.location.modelPath == "source_ip")
      #expect(!String(describing: error).contains("PRIVATE_CONTEXT_PROVIDER_SECRET"))
      #expect(ledger.change(key) == ["name": .string("caller edit")])
    }
    let retry = try context(ContextFixProbe())
    let result = try retry.preflightMutation(update(ledger.change(key)), ledgerRoot: ledger, ledgerKey: key)
    #expect(result.values["source_ip"] == .string("prepared-IP"))
  }

  @Test func rejectedCheckPublishesNothingAndRetainedCapabilityExpires() throws {
    let probe = ContextFixProbe(), ctx = try context(probe, reject: true), ledger = EntityRoot(), key = EntityKey(entity: "Probe", id: .int(1))
    ledger.set(key, field: "name", value: .string("caller edit"))
    #expect(throws: CheckException.self) { _ = try ctx.preflightMutation(update(ledger.change(key)), ledgerRoot: ledger, ledgerKey: key) }
    #expect(ledger.change(key) == ["name": .string("caller edit")])
    var value = update(["name": .string("edit")]); let retained = try #require(probe.context)
    #expect(!ContextFix.allowed(retained, mutation: value))
    #expect(throws: CheckException.self) { try ContextFix.apply(retained, mutation: &value, now: now, field: "source_ip", function: "ip") }
  }

  @Test func metadataDecodesOlderShapeAndRoundTripsContextScope() throws {
    let old = try JSONDecoder().decode(PropertyDescriptor.self, from: Data(#"{"name":"name","type":"string"}"#.utf8))
    #expect(old.createFunction == nil && old.updateFunction == nil)
    let scoped = descriptor.properties[4]
    #expect(try JSONDecoder().decode(PropertyDescriptor.self, from: JSONEncoder().encode(scoped)) == scoped)
  }

  @Test func defaultClockAndUniqueStringUseDeclaredStrongTypes() throws {
    let entity = EntityDescriptor(name: "Token", table: "token", properties: [
      PropertyDescriptor(name: "when", type: .timestamp, createFunction: "now"),
      PropertyDescriptor(name: "token", type: .string, createFunction: "uniStr")])
    struct Checker: EntityChecker {
      func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
        try ContextFix.apply(context, mutation: &mutation, now: now, field: "when", function: "now")
        try ContextFix.apply(context, mutation: &mutation, now: now, field: "token", function: "uniStr", arguments: ["prefix-"])
        return []
      }
    }
    var runtime = TeaQLRuntime(); try runtime.install(RuntimeModule(name: "Defaults", entities: [entity], checkers: ["Token": Checker()]))
    let ctx = UserContext(runtime: runtime, queryExecutor: ContextFixUnusedExecutor(), mutationExecutor: ContextFixUnusedExecutor(),
      requestPolicy: RequestPolicy { $0 }, businessClock: FixedBusinessClock(now))
    let mutation = Mutation(kind: .create, entity: entity, values: [:], auditReason: "typed default Context functions")
    let first = try ctx.preflightMutation(mutation), second = try ctx.preflightMutation(mutation)
    #expect(first.values["when"] == .timestamp(1_700_000_000_000))
    #expect(first.values["token"]?.stringValue?.hasPrefix("prefix-") == true)
    #expect(first.values["token"] != second.values["token"])
  }

  @Test func trustedContextMetadataDoesNotReplaceTheGeneratedEntityDescriptor() throws {
    let entity = EntityDescriptor(name: "Peer", table: "peer", properties: [
      PropertyDescriptor(name: "name", type: .string), PropertyDescriptor(name: "sourceIp", modelName: "source_ip", type: .string)])
    struct Checker: EntityChecker {
      func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
        try ContextFix.apply(context, mutation: &mutation, now: now, field: "source_ip", function: "ip"); return []
      }
    }
    var runtime = TeaQLRuntime()
    try runtime.install(RuntimeModule(name: "Peer", entities: [entity], checkers: ["Peer": Checker()],
      contextFixFields: ["Peer": ["source_ip": ContextFieldFunctions(update: "ip")]]))
    #expect(runtime.entity(named: "Peer") == entity)
    let probe = ContextFixProbe()
    let ctx = UserContext(runtime: runtime, queryExecutor: ContextFixUnusedExecutor(), mutationExecutor: ContextFixUnusedExecutor(),
      requestPolicy: RequestPolicy { $0 }, businessClock: FixedBusinessClock(now), contextFixResolver: ContextFixTestResolver(probe: probe, mode: "normal"))
    let fixed = try ctx.preflightMutation(Mutation(kind: .update, entity: entity, id: .int(1), values: ["name": .string("edit")],
      expectedVersion: 1, auditReason: "verify trusted Context declaration"))
    #expect(fixed.values["source_ip"] == .string("prepared-IP")); #expect(probe.count == 1)
    var invalid = TeaQLRuntime()
    #expect(throws: (any Error).self) { try invalid.install(RuntimeModule(name: "Invalid", entities: [entity],
      contextFixFields: ["Peer": ["sourceIp": ContextFieldFunctions(update: "ip")]])) }
  }

  @Test func graphUndoTouchesOnlyAutomaticFieldsAndPreservesTypedCallerIntent() throws {
    let ledger = EntityRoot(), key = EntityKey(entity: "Probe", id: .int(1)), other = EntityKey(entity: "Other", id: .int(1))
    try ledger.setOriginalVersion(key, version: 7); try ledger.setOriginalVersion(other, version: 19)
    ledger.set(key, field: "name", value: .string("before")); ledger.set(key, field: "source_ip", value: .string("original IP"))
    let undo = ledger.captureContextFields(key, fields: ["source_ip", "touched_at"])
    ledger.set(key, field: "source_ip", value: .string("automatic IP")); ledger.set(key, field: "touched_at", value: .timestamp(17))
    ledger.set(key, field: "name", value: .string("caller edit")); ledger.set(other, field: "source_ip", value: .string("other type intent"))
    try undo()
    #expect(ledger.change(key) == ["name": .string("caller edit"), "source_ip": .string("original IP")])
    #expect(ledger.change(other) == ["source_ip": .string("other type intent")])
    #expect(ledger.originalVersion(key) == 7 && ledger.originalVersion(other) == 19)
  }
}
