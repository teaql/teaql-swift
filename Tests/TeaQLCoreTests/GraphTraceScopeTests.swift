import Foundation
import XCTest
@testable import TeaQLCore

final class GraphTraceScopeTests: XCTestCase {
  private struct Fixture: Decodable {
    let cases: [Vector]
    struct Vector: Decodable {
      let id: String; let requestComment: String; let nodes: [Node]; let expected: [Expected]
    }
    struct Node: Decodable {
      let nodeId: String; let entityType: String; let entityId: Int64?; let parent: String?
      let localComment: String?; let ledgerLineage: [LogicalNode]?; let assignedEntityId: Int64?
    }
    struct Expected: Decodable { let nodeId: String; let lineage: [LogicalNode] }
    struct LogicalNode: Decodable, Equatable {
      let kind: String; let name: String; let entityId: Int64?; let detail: String
      var native: TraceNode { TraceNode(entity: name, comment: detail, purpose: "",
        kind: kind.lowercased(), entityID: entityId.map(TeaQLValue.int)) }
    }
  }

  func testFiveFrozenGraphsAndFifteenKeyedExpectations() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/graph-mutation-lineage-v1.json")
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    XCTAssertEqual(fixture.cases.count, 5)
    XCTAssertEqual(fixture.cases.flatMap(\.expected).count, 15)
    for vector in fixture.cases {
      let session = GraphMutationSession(intent: try MutationIntent(comment: vector.requestComment),
        policy: MutationPolicyCoordinator(registry: nil, approvalProvider: nil, warningSink: nil))
      let ledger = EntityRoot()
      var scopes: [String: TraceScopeToken] = [:]
      var observations: [String: [TraceNode]] = [:]
      for node in vector.nodes {
        let key = EntityKey(entity: node.entityType, id: .int(node.entityId ?? 0))
        let scope = try session.scope(key: key, localReason: node.localComment,
          parent: node.parent.flatMap { scopes[$0] })
        scopes[node.nodeId] = scope
        if let specific = node.ledgerLineage { ledger.setTraceChain(key, chain: specific.map(\.native)) }
        let fallback = ledger.traceChain(key, fallback: scope)
        observations[node.nodeId] = node.assignedEntityId.map {
          TraceChain.assignedLineage(fallback, key: EntityKey(entity: key.entity, id: .int($0)))
        } ?? fallback
      }
      for expected in vector.expected {
        XCTAssertEqual(observations[expected.nodeId]?.map {
          Fixture.LogicalNode(kind: $0.kind.lowercased(), name: $0.name,
            entityId: $0.entityID?.int64Value, detail: $0.comment)
        }, expected.lineage.map {
          Fixture.LogicalNode(kind: $0.kind.lowercased(), name: $0.name,
            entityId: $0.entityId, detail: $0.detail)
        }, "\(vector.id):\(expected.nodeId)")
      }
    }
  }

  func testInheritedSameTypeScopeDoesNotAcquireChildIdentity() throws {
    let root = try TraceScopeToken(key: EntityKey(entity: "TreeNode", id: .int(100)), reason: "edit tree")
    let unchanged = try root.assigning(EntityKey(entity: "TreeNode", id: .int(-1)),
      to: EntityKey(entity: "TreeNode", id: .int(101)))
    XCTAssertTrue(unchanged === root)
    XCTAssertEqual(root.recover().first?.entityID, .int(100))
  }

  func testScopeCannotCrossSessionsOrOutliveItsInvocation() throws {
    func session(_ reason: String) throws -> GraphMutationSession {
      GraphMutationSession(intent: try MutationIntent(comment: reason),
        policy: MutationPolicyCoordinator(registry: nil, approvalProvider: nil, warningSink: nil))
    }
    let first = try session("first graph"); let second = try session("second graph")
    let key = EntityKey(entity: "CustomerOrder", id: .int(1))
    let scope = try first.scope(key: key)
    XCTAssertThrowsError(try second.scope(key: key, localReason: "wrong parent", parent: scope))
    _ = first.finish(committed: false)
    XCTAssertThrowsError(try first.scope(key: key))
    XCTAssertThrowsError(try first.afterCommit {})
    XCTAssertEqual(scope.recover().first?.comment, "first graph")
  }

  func testLedgerRekeyUpdatesOnlyMatchingTypedReferences() throws {
    let ledger = EntityRoot()
    let order = EntityKey(entity: "CustomerOrder", id: .int(-1))
    let payment = EntityKey(entity: "Payment", id: .int(-1))
    let orderScope = try TraceScopeToken(key: order, reason: "submit order")
    let paymentScope = try TraceScopeToken(parent: orderScope, key: payment, reason: "authorize payment")
    ledger.setTraceChain(payment, chain: paymentScope.recover())
    try ledger.rekey(order, to: EntityKey(entity: "CustomerOrder", id: .int(100)))
    let output = ledger.traceChain(payment, fallback: paymentScope)
    XCTAssertEqual(output.map(\.entityID), [.int(100), .int(-1)])
    XCTAssertEqual(output.map(\.name), ["CustomerOrder", "Payment"])
    XCTAssertEqual(paymentScope.recover().map(\.entityID), [.int(-1), .int(-1)])
  }
}
