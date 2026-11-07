import Foundation
import Testing
@testable import TeaQLCore

@Suite("Known loaded scalar restoration")
struct RestoredMutationTests {
  @Test(arguments: ["name", "optionalName", "active", "quantity", "unsigned", "amount", "ratio", "binary",
    "calendarDate", "timestamp", "json"])
  func restoredKnownValueDoesNotEnterFixPolicyOrProvider(_ field: String) async throws {
    var entity = try RestoredProbe()
    let original = try #require(entity.values[field])
    entity.assign(field, .null); entity.assign(field, original)
    let probe = RestoredEffects(), context = try context(probe)
    let saved = try await AuditedEntity(entity: entity, reason: "cancel a restored known scalar").save(context)
    #expect(saved.version == 7)
    #expect(!entity.teaqlEntityRoot.hasPending(entity.teaqlEntityKey))
    #expect(probe.fixes == 0 && probe.reviews == 0)
    let begins = await probe.provider.begins, writes = await probe.provider.writes
    #expect(begins == 0 && writes == 0)
    #expect(await probe.provider.audits == 0)
  }

  @Test func knownUnchangedMaximumVersionDoesNotExhaust() async throws {
    var entity = try RestoredProbe(version: .max)
    entity.assign("name", .string("temporary")); entity.assign("name", .string("original"))
    let probe = RestoredEffects(), context = try context(probe)
    let saved = try await AuditedEntity(entity: entity, reason: "a no-op is not a new version").save(context)
    #expect(saved.version == Int64.max)
    #expect(probe.fixes == 0 && probe.reviews == 0)
    #expect(await probe.provider.writes == 0)
  }

  @Test func unknownOriginalNullStillHasMutationIntent() async throws {
    var entity = try RestoredProbe(omit: ["optionalName"])
    entity.assign("optionalName", .null)
    let probe = RestoredEffects(), context = try context(probe)
    _ = try await AuditedEntity(entity: entity, reason: "write a null whose original was not loaded").save(context)
    #expect(probe.fixes == 1 && probe.reviews == 1)
    #expect(await probe.provider.commands.first?.values["optional_name"] == .null)
  }

  @Test func signedZeroIsNotAnEqualAssignment() async throws {
    var entity = try RestoredProbe(overrides: ["ratio": .double(-0.0)])
    entity.assign("ratio", .double(0.0))
    let probe = RestoredEffects(), context = try context(probe)
    _ = try await AuditedEntity(entity: entity, reason: "retain an exact floating-point change").save(context)
    #expect(probe.fixes == 1 && probe.reviews == 1)
    let value = await probe.provider.commands.first?.values["ratio"]
    if case .double(let number) = value { #expect(number.bitPattern == Double(0).bitPattern) }
    else { Issue.record("signed-zero mutation was omitted") }
  }

  @Test func nonfiniteLoadedAndAssignedValuesStillReachValidation() async throws {
    var entity = try RestoredProbe(overrides: ["ratio": .double(.nan)])
    entity.assign("ratio", .double(.nan))
    let probe = RestoredEffects(), context = try context(probe)
    do {
      _ = try await AuditedEntity(entity: entity, reason: "do not normalize away invalid scalars").save(context)
      Issue.record("non-finite assignment bypassed admission")
    } catch is CheckException { }
    #expect(await probe.provider.writes == 0)
    #expect(entity.teaqlEntityRoot.hasPending(entity.teaqlEntityKey))
  }

  @Test func newEntitiesRetainTheirAssignmentsEvenWithAnEqualSnapshot() async throws {
    var entity = try RestoredProbe(version: 0, snapshotOrigin: .creationBaseline)
    entity.teaqlEntityRoot.markAsNew(entity.teaqlEntityKey)
    entity.assign("name", .string("original"))
    let probe = RestoredEffects(), context = try context(probe)
    _ = try await AuditedEntity(entity: entity, reason: "a new entity must still be inserted").save(context)
    #expect(await probe.provider.commands.first?.kind == .create)
    #expect(await probe.provider.commands.first?.values["name"] == .string("original"))
  }

  @Test func restorationNeverCancelsAnExplicitDeletion() async throws {
    var entity = try RestoredProbe(version: .max)
    entity.assign("name", .string("original"))
    entity.teaqlEntityRoot.markAsDeleted(entity.teaqlEntityKey)
    let probe = RestoredEffects(), context = try context(probe)
    let saved = try await AuditedEntity(entity: entity, reason: "preserve explicit deletion").save(context)
    #expect(saved.version == Int64.min)
    #expect(await probe.provider.commands.first?.kind == .delete)
  }

  @Test func normalizationOnlyTouchesTheReachedTypedEntity() async throws {
    var entity = try RestoredProbe()
    let other = EntityKey(entity: "AnotherType", id: .int(entity.id))
    entity.teaqlEntityRoot.set(other, field: "name", value: .string("unrelated pending"))
    entity.assign("name", .string("original"))
    let probe = RestoredEffects(), context = try context(probe)
    _ = try await AuditedEntity(entity: entity, reason: "do not drain an independent root").save(context)
    #expect(entity.teaqlEntityRoot.change(other)["name"] == .string("unrelated pending"))
    #expect(entity.teaqlEntityRoot.hasPending(other))
    #expect(await probe.provider.writes == 0)
  }

  @Test func anUnrepresentableFractionalMillisecondIsNotCancelled() async throws {
    var entity = try RestoredProbe(overrides: ["timestamp": .date(Date(timeIntervalSince1970: 42.00125))])
    entity.assign("timestamp", .timestamp(42_001))
    let probe = RestoredEffects(), context = try context(probe)
    _ = try await AuditedEntity(entity: entity, reason: "do not hide temporal precision loss").save(context)
    #expect(await probe.provider.writes == 1)
  }

  @Test func exactNativeDateAndCanonicalTimestampCanCancel() async throws {
    var entity = try RestoredProbe()
    entity.assign("timestamp", .date(Date(timeIntervalSince1970: 1_792_488_600.125)))
    let probe = RestoredEffects(), context = try context(probe)
    _ = try await AuditedEntity(entity: entity, reason: "cancel only exact typed timestamp equality").save(context)
    #expect(await probe.provider.writes == 0)
    #expect(probe.fixes == 0 && probe.reviews == 0)
  }

  @Test func equalityDoesNotCoerceTypesOrHideInvalidNestedValues() {
    let integer = PropertyDescriptor(name: "quantity", type: .int)
    let json = PropertyDescriptor(name: "json", type: .json)
    let timestamp = PropertyDescriptor(name: "timestamp", type: .timestamp)
    #expect(!LoadedScalarRestoration.same(.double(1), .int(1), property: integer))
    #expect(!LoadedScalarRestoration.same(.string("1"), .int(1), property: integer))
    #expect(!LoadedScalarRestoration.same(.bool(true), .int(1), property: integer))
    #expect(!LoadedScalarRestoration.same(.int(1), .timestamp(1), property: timestamp))
    #expect(!LoadedScalarRestoration.same(.array([.double(-0.0)]), .array([.double(0.0)]), property: json))
    #expect(!LoadedScalarRestoration.same(.object(["n": .double(.infinity)]), .object(["n": .double(.infinity)]), property: json))
    #expect(!LoadedScalarRestoration.same(.decimal(.nan), .decimal(.nan), property: PropertyDescriptor(name: "amount", type: .decimal)))
  }

  @Test func unknownAndProtectedFieldsCannotBeDiscarded() throws {
    for field in ["id", "version", "_derived_total", "_persistent_custom"] {
      var entity = try RestoredProbe(overrides: [field: .int(7)])
      entity.assign(field, .int(7))
      LoadedScalarRestoration.discardRestoredFields(of: entity)
      #expect(entity.teaqlEntityRoot.hasPending(entity.teaqlEntityKey))
    }
  }

  @Test func inconsistentSnapshotAliasesDoNotBecomeAKnownNull() throws {
    var entity = try RestoredProbe(overrides: ["optional_name": .string("conflicting alias")])
    entity.assign("optionalName", .null)
    LoadedScalarRestoration.discardRestoredFields(of: entity)
    #expect(entity.teaqlEntityRoot.change(entity.teaqlEntityKey)["optional_name"] == .null)
  }

  @Test func sharedSnapshotsDoNotConflateSignedZero() {
    let pool = LoadedEntitySnapshots(), key = EntityKey(entity: "FloatingProbe", id: .int(1))
    let negative = pool.capture(key: key, version: 1, record: ["ratio": .double(-0.0)])
    let positive = pool.capture(key: key, version: 1, record: ["ratio": .double(0.0)])
    let repeatedPositive = pool.capture(key: key, version: 1, record: ["ratio": .double(0.0)])
    #expect(negative !== positive)
    #expect(positive === repeatedPositive)
    if case .double(let number) = positive.record["ratio"] { #expect(number.bitPattern == Double(0).bitPattern) }
    else { Issue.record("floating snapshot field missing") }
  }

  private func context(_ effects: RestoredEffects) throws -> UserContext {
    var runtime = TeaQLRuntime()
    try runtime.install(RuntimeModule(name: "restored", entities: [RestoredProbe.descriptor],
      checkers: [RestoredProbe.descriptor.name: effects]))
    return UserContext(runtime: runtime, queryExecutor: effects.provider, mutationExecutor: effects.provider,
      requestPolicy: RequestPolicy { $0 }, auditSink: effects.provider,
      mutationPolicyRegistry: DelegatingMutationPolicyRegistry { _ in effects })
  }
}

private struct RestoredProbe: TeaQLMutationRootedEntity {
  static let descriptor = EntityDescriptor(name: "RestoredProbe", table: "restored_probe", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true), PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "name", type: .string), PropertyDescriptor(name: "optionalName", modelName: "optional_name", column: "optional_name", type: .string, nullable: true),
    PropertyDescriptor(name: "active", type: .bool), PropertyDescriptor(name: "quantity", type: .int),
    PropertyDescriptor(name: "unsigned", type: .uint), PropertyDescriptor(name: "amount", type: .decimal),
    PropertyDescriptor(name: "ratio", type: .double), PropertyDescriptor(name: "binary", type: .data),
    PropertyDescriptor(name: "calendarDate", modelName: "calendar_date", type: .date),
    PropertyDescriptor(name: "timestamp", type: .timestamp), PropertyDescriptor(name: "json", type: .json),
  ])
  var id: Int64 = 1
  var version: Int64
  var values: TeaQLRecord
  let teaqlEntityRoot: EntityRoot
  let teaqlLoadedSnapshot: LoadedEntitySnapshot?
  var teaqlEntityKey: EntityKey { EntityKey(entity: Self.descriptor.name, id: .int(id)) }
  init(version: Int64 = 7, omit: Set<String> = [], overrides: TeaQLRecord = [:],
       snapshotOrigin: EntitySnapshotOrigin = .hydrated) throws {
    self.version = version; teaqlEntityRoot = EntityRoot()
    var original: TeaQLRecord = ["name": .string("original"), "optionalName": .null, "active": .bool(true),
      "quantity": .int(9_007_199_254_740_993), "unsigned": .uint(UInt64.max),
      "amount": .decimal(Decimal(string: "12345678901234567890.1234")!), "ratio": .double(1.25),
      "binary": .data(Data([0, 1, 255])), "calendarDate": .calendarDate("2026-10-27"),
      "timestamp": .timestamp(1_792_488_600_125), "json": .object(["items": .array([.int(3), .null])])]
    for field in omit { original.removeValue(forKey: field) }
    original.merge(overrides) { _, value in value }; values = original
    let key = EntityKey(entity: Self.descriptor.name, id: .int(1))
    try teaqlEntityRoot.setOriginalVersion(key, version: version)
    teaqlLoadedSnapshot = LoadedEntitySnapshots().capture(key: key, version: version, record: original, origin: snapshotOrigin)
  }
  mutating func assign(_ name: String, _ value: TeaQLValue) {
    values[name] = value
    let canonical = Self.descriptor.property(named: name)?.modelName ?? name
    teaqlEntityRoot.set(teaqlEntityKey, field: canonical, value: value)
  }
  func toRecord() -> TeaQLRecord { values.merging(["id": .int(id), "version": .int(version)]) { _, value in value } }
  func toMutationRecord() -> TeaQLRecord { toRecord() }
  static func from(record: TeaQLRecord) throws -> Self {
    var result = try Self(version: record["version"]?.int64Value ?? 0)
    result.values.merge(record) { _, value in value }; return result
  }
  init(from decoder: any Decoder) throws { throw TeaQLError.execution("handwritten test entity has no wire API") }
  func encode(to encoder: any Encoder) throws { throw TeaQLError.execution("handwritten test entity has no wire API") }
}

private final class RestoredEffects: @unchecked Sendable, EntityChecker, MutationPolicy {
  let provider = RestoredProvider()
  private let lock = NSLock()
  private var fixCount = 0, reviewCount = 0
  var fixes: Int { lock.withLock { fixCount } }
  var reviews: Int { lock.withLock { reviewCount } }
  let identity = MutationPolicyIdentity(policyID: "restoration", version: "1", fingerprint: "fixture")
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    lock.withLock { fixCount += 1 }; return []
  }
  func review(context: UserContext, plan: MutationPlan) throws -> MutationPolicyDecision {
    lock.withLock { reviewCount += 1 }; return MutationPolicyDecision(verdict: .allow)
  }
}
private actor RestoredProvider: QueryExecutor, GraphTransactionExecutor, AuditSink {
  private(set) var begins = 0, writes = 0, audits = 0
  private(set) var commands: [Mutation] = []
  func beginGraphTransaction() async throws { begins += 1 }
  func commitGraphTransaction() async throws {}
  func rollbackGraphTransaction() async throws {}
  func record(_ event: AuditEvent) { audits += 1 }
  func execute(_ request: QueryRequest) async throws -> QueryResult { QueryResult(records: [], backend: "restoration-spy") }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    let mutation = request.mutation
    writes += 1; commands.append(mutation)
    let next = try MutationVersion.next(for: mutation.kind, original: mutation.expectedVersion)
    return MutationResult(affectedRows: 1, persistedRecord: mutation.values.merging(["id": .int(1), "version": .int(next)]) { _, value in value })
  }
}
