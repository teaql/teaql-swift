import Foundation
import TeaQLCore

struct GraphIdentity: Hashable {
    let entity: String
    let id: Int64
    var json: [String: String] { ["entity": entity, "id": String(id)] }
}

func expectedIdentities(_ expected: [String: [NodeExpectation]]) throws -> Set<GraphIdentity> {
    try Set(expected.keys.map { key in
        let parts = key.split(separator: "#")
        guard parts.count == 2, let id = Int64(parts[1]), id > 0 else {
            throw TeaQLError.execution("invalid expected typed graph identity")
        }
        return GraphIdentity(entity: String(parts[0]), id: id)
    })
}

func checkIdentities(_ expected: Set<GraphIdentity>, _ observed: [GraphIdentity], boundary: String) throws {
    try require(observed.allSatisfy { $0.id > 0 && !$0.entity.isEmpty }, "\(boundary): graph identity guard invalid target")
    try require(observed.count == expected.count && Set(observed).count == observed.count
        && Set(observed) == expected, "\(boundary): graph identity guard duplicate, missing or incorrect typed target")
}

func graphIdentityControls() throws {
    let values = [GraphIdentity(entity: "CustomerOrder", id: 1), GraphIdentity(entity: "Payment", id: 1),
        GraphIdentity(entity: "OrderItem", id: 2), GraphIdentity(entity: "OrderItem", id: 3),
        GraphIdentity(entity: "PaymentAttempt", id: 1), GraphIdentity(entity: "Shipment", id: 1)]
    let expected = Set(values)
    try checkIdentities(expected, values, boundary: "identity control")
    var duplicate = values; duplicate[3] = duplicate[2]
    var collapsed = values; collapsed[1] = GraphIdentity(entity: "CustomerOrder", id: 1)
    for invalid in [Array(values.dropLast()), duplicate, collapsed] {
        do {
            try checkIdentities(expected, invalid, boundary: "identity control")
        } catch let error as TeaQLError {
            guard case .execution(let message) = error, message.contains("graph identity guard") else { throw error }
            continue
        }
        throw TeaQLError.execution("invalid typed identity control was accepted")
    }
    print("PASS Swift graph identity controls: duplicate, missing and equal-ID type collapse rejected")
}

func printIdentities(_ expected: Set<GraphIdentity>, commands: [GraphIdentity], physical: [GraphIdentity], audit: [GraphIdentity]) throws {
    func rows(_ identities: [GraphIdentity]) -> [[String: String]] {
        identities.sorted { ($0.entity, $0.id) < ($1.entity, $1.id) }.map(\.json)
    }
    let output = ["expected": rows(Array(expected)), "commands": rows(commands),
        "physical": rows(physical), "audit": rows(audit)]
    let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    guard let text = String(data: data, encoding: .utf8) else { throw TeaQLError.execution("identity evidence encoding failed") }
    print("GRAPH IDENTITY EVIDENCE \(text)")
}
