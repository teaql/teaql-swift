import Foundation
import Testing
@_spi(Generated) @testable import TeaQLCore

@Suite("Pure graph readback")
struct GraphReadbackTests {
  @Test func updatedScalarsUsePhysicalAliasesWithoutExpandingProjection() throws {
    let entity = ReadbackProbe(), graph = GraphReadback(records: [entity.teaqlEntityKey:
      ["id": .int(1), "version": .int(2), "full_name": .string("persisted"), "hidden": .string("not selected")]])
    let record = try graph.scalarRecord(for: entity)
    #expect(record == ["id": .int(1), "version": .int(2), "fullName": .string("persisted")])
    #expect(graph.contains(entity))
    #expect(!entity.teaqlEntityRoot.hasPending(entity.teaqlEntityKey))
  }

  @Test func loadedNullIsNotAnOmittedField() throws {
    let entity = ReadbackProbe(extra: ["optionalName": .null]), graph = GraphReadback(records: [entity.teaqlEntityKey:
      ["id": .int(1), "version": .int(2), "full_name": .string("persisted"), "optional_name": .null]])
    let record = try graph.scalarRecord(for: entity)
    #expect(record["optionalName"] == .null && record["hidden"] == nil)
  }

  @Test func unchangedViewsUseImmutableLoadedValuesNotUnsavedNativeAssignments() throws {
    var entity = ReadbackProbe(); entity.values["fullName"] = .string("unrecorded edit")
    let graph = GraphReadback(records: [:]), record = try graph.scalarRecord(for: entity)
    #expect(record["fullName"] == .string("original") && record["version"] == .int(1))
    #expect(!graph.contains(entity))
  }

  @Test func equalIDsOfDifferentTypesNeverShareReadback() throws {
    let entity = ReadbackProbe(), other = EntityKey(entity: "OtherProbe", id: .int(1))
    let graph = GraphReadback(records: [other: ["id": .int(1), "version": .int(99), "full_name": .string("other")]])
    #expect(try graph.scalarRecord(for: entity)["version"] == .int(1))
    #expect(!graph.contains(entity))
  }

  @Test func temporaryIdentityResolvesToTheAuthoritativeCreatedID() throws {
    let entity = ReadbackProbe(id: 0, version: 0), graph = GraphReadback(records: [entity.teaqlEntityKey:
      ["id": .int(7), "version": .int(1), "full_name": .string("created")]])
    let record = try graph.scalarRecord(for: entity)
    #expect(record["id"] == .int(7) && record["version"] == .int(1))
    #expect(entity.id == 0 && entity.teaqlEntityRoot.originalVersion(entity.teaqlEntityKey) == 0)
  }

  @Test func missingAuthoritativeFieldsDoNotBecomeLoadedDefaults() throws {
    let entity = ReadbackProbe(), graph = GraphReadback(records: [entity.teaqlEntityKey: ["id": .int(1), "version": .int(2)]])
    do { _ = try graph.scalarRecord(for: entity); Issue.record("missing readback field became a default") }
    catch { #expect(String(describing: error).contains("PERSISTED_FIELD_MISSING")) }
  }

  @Test func aReadbackRecordIsDetachedFromInputAndReturnedValueMutations() throws {
    let entity = ReadbackProbe()
    var input: [EntityKey: TeaQLRecord] = [entity.teaqlEntityKey:
      ["id": .int(1), "version": .int(2), "full_name": .string("persisted")]]
    let graph = GraphReadback(records: input)
    input[entity.teaqlEntityKey]?["full_name"] = .string("changed input")
    var first = try graph.scalarRecord(for: entity); first["fullName"] = .string("changed return")
    #expect(try graph.scalarRecord(for: entity)["fullName"] == .string("persisted"))
  }

  @Test func replacementPreservesQueryMetadataWithoutRecomputingIt() throws {
    let facet = SmartList<TeaQLRecord>([["code": .string("OPEN")]], totalCount: 3)
    let original = SmartList([1], totalCount: 42, aggregations: ["sum": .decimal(7.5)],
      summary: ["count": .int(42)], facets: ["status": facet], isLoaded: true)
    let result = original.replacingData([2, 3])
    #expect(result.data == [2, 3] && result.totalCount == 42 && result.isLoaded)
    #expect(result.aggregations == original.aggregations && result.summary == original.summary)
    #expect(result.facets["status"]?.data == facet.data && result.facets["status"]?.totalCount == 3)
    #expect(original.data == [1])
  }

  @Test func replacementDoesNotInventLoadedEmptyRelations() {
    #expect(!SmartList<Int>.empty.replacingData([]).isLoaded)
    #expect(SmartList<Int>([]).replacingData([]).isLoaded)
  }

  @Test func forwardDetailsMustMatchTheirFKAndOriginalLoadState() {
    let entity = ReadbackProbe(), graph = GraphReadback(records: [:])
    #expect(graph.forwardMatches(.int(1), related: SmartList([entity])))
    #expect(!graph.forwardMatches(.int(2), related: SmartList([entity])))
    #expect(!graph.forwardMatches(.int(1), related: SmartList<ReadbackProbe>([])))
    #expect(!graph.forwardMatches(.int(1), related: SmartList([entity, entity])))
    #expect(graph.forwardMatches(.null, related: SmartList<ReadbackProbe>([])))
    #expect(!graph.forwardMatches(.null, related: SmartList([entity])))
    #expect(!graph.forwardMatches(.null, related: SmartList<ReadbackProbe>.empty))
    #expect(!graph.forwardMatches(nil, related: SmartList<ReadbackProbe>([])))
  }

  @Test func eachReconstructedGraphOwnsItsLedgerAndSnapshotPool() {
    let entity = ReadbackProbe(), first = GraphReadback(records: [:]), second = GraphReadback(records: [:])
    #expect(first.root !== second.root && first.root !== entity.teaqlEntityRoot)
    let a = first.snapshots.capture(key: entity.teaqlEntityKey, version: 1, record: entity.values)
    let b = first.snapshots.capture(key: entity.teaqlEntityKey, version: 1, record: entity.values)
    let c = second.snapshots.capture(key: entity.teaqlEntityKey, version: 1, record: entity.values)
    #expect(a === b && a !== c)
  }

  @Test func sessionReadbackIsDeniedDuringPreparationAndAfterClose() throws {
    let session = try session()
    try session.beginPreparation()
    #expect(throws: TeaQLError.self) { try session.readback() }
    try session.endPreparation()
    _ = try session.readback()
    _ = session.finish(committed: false)
    #expect(throws: TeaQLError.self) { try session.readback() }
  }

  @Test func sessionCapturesBothSourceAndPersistedTypedKeys() throws {
    let session = try session(), source = ReadbackProbe(id: 0, version: 0)
    let mutation = Mutation(kind: .create, entity: ReadbackProbe.descriptor, auditReason: "capture one successful write")
    try session.recordPersisted(mutation, result: MutationResult(affectedRows: 1,
      persistedRecord: ["id": .int(7), "version": .int(1), "full_name": .string("created")]), sourceKey: source.teaqlEntityKey)
    let graph = try session.readback()
    #expect(try graph.scalarRecord(for: source)["id"] == .int(7))
    #expect(graph.contains(ReadbackProbe(id: 7)))
    _ = session.finish(committed: true)
  }

  @Test func anAffectedRowsZeroResultDoesNotClaimAuthoritativePersistence() throws {
    let session = try session(), entity = ReadbackProbe()
    try session.recordPersisted(Mutation(kind: .update, entity: ReadbackProbe.descriptor, id: .int(1),
      expectedVersion: 1, auditReason: "do not invent a write"), result: MutationResult(affectedRows: 0,
      persistedRecord: ["id": .int(1), "version": .int(2)]), sourceKey: entity.teaqlEntityKey)
    #expect(try !session.readback().contains(entity))
    _ = session.finish(committed: false)
  }

  private func session() throws -> GraphMutationSession {
    GraphMutationSession(intent: try MutationIntent(comment: "inspect pure graph reconstruction"),
      policy: MutationPolicyCoordinator(registry: nil, approvalProvider: nil, warningSink: nil),
      fixTime: Date(timeIntervalSince1970: 1_792_488_600.125))
  }
}

private struct ReadbackProbe: TeaQLMutationRootedEntity {
  static let descriptor = EntityDescriptor(name: "ReadbackProbe", table: "readback_probe", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true), PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "fullName", modelName: "full_name", column: "full_name", type: .string),
    PropertyDescriptor(name: "optionalName", modelName: "optional_name", column: "optional_name", type: .string, nullable: true),
    PropertyDescriptor(name: "hidden", type: .string, nullable: true),
  ])
  var values: TeaQLRecord
  var id: Int64 { get { values["id"]?.int64Value ?? 0 } set { values["id"] = .int(newValue) } }
  var version: Int64 { get { values["version"]?.int64Value ?? 0 } set { values["version"] = .int(newValue) } }
  let teaqlEntityRoot = EntityRoot()
  let teaqlLoadedSnapshot: LoadedEntitySnapshot?
  var teaqlEntityKey: EntityKey { EntityKey(entity: Self.descriptor.name, id: .int(id == 0 ? -1 : id)) }
  init(id: Int64 = 1, version: Int64 = 1, extra: TeaQLRecord = [:]) {
    values = ["id": .int(id), "version": .int(version), "fullName": .string("original")].merging(extra) { _, new in new }
    let key = EntityKey(entity: Self.descriptor.name, id: .int(id == 0 ? -1 : id))
    try! teaqlEntityRoot.setOriginalVersion(key, version: version)
    teaqlLoadedSnapshot = LoadedEntitySnapshots().capture(key: key, version: version, record: values)
  }
  func toRecord() -> TeaQLRecord { values }
  static func from(record: TeaQLRecord) throws -> Self { Self(id: record["id"]?.int64Value ?? 0, version: record["version"]?.int64Value ?? 0) }
  init(from decoder: any Decoder) throws { throw TeaQLError.execution("native readback fixture has no wire API") }
  func encode(to encoder: any Encoder) throws { throw TeaQLError.execution("native readback fixture has no wire API") }
}
