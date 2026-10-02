import Foundation
import XCTest
@testable import TeaQLCore

final class CanonicalTraceTests: XCTestCase {
  private struct Fixture: Decodable {
    let cases: [Case]
    struct Case: Decodable {
      let id: String
      let operation: String
      let backend: String
      let source: [Node]
      let expectedIntent: Intent
      let expectedPath: [Node]
    }
    struct Intent: Decodable { let comment: String?; let purpose: String?; let auditReason: String? }
    struct Node: Decodable, Equatable {
      let kind: String; let name: String; let entityId: Int64?; let detail: String
      func native() -> TraceNode {
        TraceNode(entity: name, comment: detail, purpose: "", kind: kind.lowercased(), name: name,
          entityID: entityId.map(TeaQLValue.int))
      }
    }
  }

  func testTwelveFrozenSQLVectorsAndIdempotence() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let fixture = try JSONDecoder().decode(Fixture.self,
      from: Data(contentsOf: root.appendingPathComponent("Fixtures/sql-trace-path-v1.json")))
    XCTAssertEqual(fixture.cases.count, 12)
    for vector in fixture.cases {
      let source = vector.source.map { $0.native() }
      let output = TraceChain.canonical(source, backend: vector.backend, operation: vector.operation)
      // Compare the contract's four logical fields, not Swift's extra legacy
      // `entity` field (provider/sql frames need not name an entity there).
      XCTAssertEqual(output.map { node in
        Fixture.Node(kind: node.kind.lowercased(), name: node.name,
          entityId: node.entityID?.int64Value, detail: node.comment)
      }, vector.expectedPath.map { node in
        Fixture.Node(kind: node.kind.lowercased(), name: node.name,
          entityId: node.entityId, detail: node.detail)
      }, vector.id)
      XCTAssertEqual(output.map(\.level), Array(output.indices), vector.id)
      let intent = TraceChain.intent(source)
      XCTAssertEqual(intent.comment, vector.expectedIntent.comment, vector.id)
      XCTAssertEqual(intent.purpose, vector.expectedIntent.purpose, vector.id)
      XCTAssertEqual(intent.auditReason, vector.expectedIntent.auditReason, vector.id)
      XCTAssertEqual(TraceChain.canonical(output, backend: "ignored", operation: "ignored"), output, vector.id)
      XCTAssertEqual(source, vector.source.map { $0.native() }, vector.id)
    }
  }

  func testDerivedRequestsOwnOriginAndIntentDespitePolicyRewrite() throws {
    let root = EntityDescriptor(name: "CustomerOrder", table: "orders", properties: [])
    let child = EntityDescriptor(name: "Payment", table: "payments", properties: [])
    var query = SelectQuery(entity: root)
    query.comment = "what: read orders"; query.purpose = "why: inspect order details"
    let request = try QueryRequest(query: query)
    var payload = SelectQuery(entity: child)
    payload.comment = "wrong"; payload.purpose = "wrong"
    let derived = request.withQuery(payload)
    XCTAssertEqual(derived.originEntity, "CustomerOrder")
    XCTAssertEqual(derived.query.entity.name, "Payment")
    XCTAssertEqual(derived.intent, request.intent)
    XCTAssertEqual(derived.query.comment, query.comment)
    XCTAssertEqual(derived.query.purpose, query.purpose)
  }

  func testNestedRelationSnapshotSurvivesJSONRoundTrip() throws {
    let descriptor = EntityDescriptor(name: "Record", table: "records", properties: [])
    let leaf = SelectQuery(entity: descriptor)
    var child = SelectQuery(entity: descriptor)
    child.relationQuery("leaf", localKey: "id", foreignKey: "id", query: leaf)
    var parent = SelectQuery(entity: descriptor)
    parent.relationQuery("child", localKey: "id", foreignKey: "id", query: child)
    let snapshot = RelationQueryPlan(parent)
    let decoded = try JSONDecoder().decode(RelationQueryPlan.self, from: JSONEncoder().encode(snapshot))
    XCTAssertEqual(decoded, snapshot)
    XCTAssertEqual(decoded.makeQuery().relations.first?.query.makeQuery().relations.first?.name, "leaf")
    XCTAssertEqual(child.relations.count, 1)
  }
}
