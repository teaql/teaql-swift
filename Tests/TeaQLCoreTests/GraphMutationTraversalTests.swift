import Foundation
import Testing
@_spi(Generated) @testable import TeaQLCore

@Suite("Invocation-owned graph traversal")
struct GraphMutationTraversalTests {
  private func session() throws -> GraphMutationSession {
    GraphMutationSession(intent: try MutationIntent(comment: "test once-only generated traversal"),
      policy: MutationPolicyCoordinator(registry: nil, approvalProvider: nil, warningSink: nil),
      fixTime: Date(timeIntervalSince1970: 2_145_916_800))
  }

  @Test func valueCopiesVisitOnceInEachPhaseButEachInvocationStartsFresh() throws {
    let entity = TraversalProbe(), copy = entity
    for _ in 0..<2 {
      let graph = try session()
      try graph.beginPreparation()
      #expect(try graph.visitEntity(entity, phase: .preflight))
      #expect(try !graph.visitEntity(copy, phase: .preflight))
      try graph.endPreparation()
      #expect(try graph.visitEntity(entity, phase: .write))
      #expect(try !graph.visitEntity(copy, phase: .write))
      _ = graph.finish(committed: false)
    }
  }

  @Test func independentLedgersAndTypedKeysDoNotAlias() throws {
    let graph = try session(), first = TraversalProbe(), second = TraversalProbe()
    var otherType = first; otherType.type = "OtherTraversalProbe"
    var otherID = first; otherID.id = 2
    try graph.beginPreparation()
    for entity in [first, second, otherType, otherID] { #expect(try graph.visitEntity(entity, phase: .preflight)) }
    _ = graph.finish(committed: false)
  }

  @Test func conflictingVersionValueAndLoadedShapeAreNotDeduplicated() throws {
    for route in 0..<3 {
      let graph = try session(), entity = TraversalProbe()
      var other = entity
      switch route {
      case 0: other.version = 2
      case 1: other.value = .string("conflict")
      default: other.value = nil
      }
      try graph.beginPreparation()
      #expect(try graph.visitEntity(entity, phase: .preflight))
      #expect(throws: MutationPolicyError.self) { try graph.visitEntity(other, phase: .preflight) }
      _ = graph.finish(committed: false)
    }
  }

  @Test func phaseAndClosedSessionAreEnforced() throws {
    let graph = try session(), entity = TraversalProbe()
    #expect(throws: TeaQLError.self) { try graph.visitEntity(entity, phase: .preflight) }
    try graph.beginPreparation()
    #expect(throws: TeaQLError.self) { try graph.visitEntity(entity, phase: .write) }
    try graph.endPreparation()
    #expect(throws: TeaQLError.self) { try graph.visitEntity(entity, phase: .preflight) }
    _ = graph.finish(committed: true)
    #expect(throws: TeaQLError.self) { try graph.visitEntity(entity, phase: .write) }
  }

  @Test func invalidFloatingPointSnapshotsRemainReflexive() throws {
    let graph = try session()
    var entity = TraversalProbe(); entity.value = .double(.nan)
    try graph.beginPreparation()
    #expect(try graph.visitEntity(entity, phase: .preflight))
    #expect(try !graph.visitEntity(entity, phase: .preflight))
    _ = graph.finish(committed: false)
  }
}

private struct TraversalProbe: TeaQLMutationRootedEntity {
  static let descriptor = EntityDescriptor(name: "TraversalProbe", table: "traversal_probe", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "value", type: .string, nullable: true),
  ])
  var id: Int64 = 1, version: Int64 = 1
  var value: TeaQLValue? = .string("original")
  var type = "TraversalProbe"
  let teaqlEntityRoot = EntityRoot()
  var teaqlEntityKey: EntityKey { EntityKey(entity: type, id: .int(id)) }
  func toRecord() -> TeaQLRecord {
    var result: TeaQLRecord = ["id": .int(id), "version": .int(version)]
    result["value"] = value
    return result
  }
  static func from(record: TeaQLRecord) throws -> Self { Self() }
  init() { }
  init(from decoder: any Decoder) throws { throw TeaQLError.execution("no wire interface for traversal fixture") }
  func encode(to encoder: any Encoder) throws { throw TeaQLError.execution("no wire interface for traversal fixture") }
}
