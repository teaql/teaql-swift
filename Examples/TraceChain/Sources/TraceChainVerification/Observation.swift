import Foundation
import TeaQLCore
import TeaQLSQLite

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TeaQLError.execution(message) }
}

actor AuditCapture: AuditSink {
    private var events: [AuditEvent] = []
    func record(_ event: AuditEvent) { events.append(event) }
    func snapshot() -> [AuditEvent] { events }
    func clear() { events.removeAll() }
}

/// Records the real generated command before delegating to SQLite; it neither
/// creates nor modifies intent, IDs or lineage. Failure tests use the native
/// provider directly so its package-only diagnostic SPI is not erased.
actor CommandCapture: GraphTransactionExecutor {
    let service: SQLiteDataService
    let audit: AuditCapture
    private var requests: [MutationRequest] = []
    private var graphStarts = 0
    private var requireCommitBarrier = false

    init(service: SQLiteDataService, audit: AuditCapture) {
        self.service = service; self.audit = audit
    }
    func beginGraphTransaction() async throws {
        graphStarts += 1
        try await service.beginGraphTransaction()
    }
    func commitGraphTransaction() async throws { try await service.commitGraphTransaction() }
    func rollbackGraphTransaction() async throws { try await service.rollbackGraphTransaction() }
    func execute(_ request: MutationRequest) async throws -> MutationResult {
        requests.append(request)
        let result = try await service.execute(request)
        if requireCommitBarrier {
            let events = await audit.snapshot()
            try require(events.isEmpty, "committed audit escaped before graph commit")
        }
        return result
    }
    func snapshot() -> [MutationRequest] { requests }
    func starts() -> Int { graphStarts }
    func clear(commitBarrier: Bool = false) {
        requests.removeAll(); requireCommitBarrier = commitBarrier
    }
}

struct NodeExpectation {
    let type: String
    let id: Int64
    let reason: String
}

func checkChain(_ chain: [TraceNode], _ expected: [NodeExpectation], boundary: String) throws {
    try require(chain.count == expected.count, "\(boundary): wrong lineage length \(chain)")
    for (index, node) in chain.enumerated() {
        let value = expected[index]
        try require(node.kind == "auditReason" && node.name == value.type
            && node.entityID == .int(value.id) && node.comment == value.reason
            && node.level == index, "\(boundary): incorrect typed lineage at \(index): \(node)")
    }
}

func key(_ type: String, _ id: Int64) -> String { "\(type)#\(id)" }

func checkObservedGraph(
    _ expected: [String: [NodeExpectation]], commands: [MutationRequest],
    sql: [SQLExecutionMetadata], audit: [AuditEvent], rootReason: String
) throws {
    let writes = sql.filter { $0.operation != .select }
    try require(commands.count == expected.count && writes.count == expected.count
        && audit.count == expected.count, "graph command/SQL/audit cardinality differs")
    var commandKeys: Set<String> = []; var sqlKeys: Set<String> = []; var auditKeys: Set<String> = []
    for request in commands {
        let mutation = request.mutation
        guard let id = (mutation.id ?? mutation.values["id"])?.int64Value,
              let lineage = mutation.mutationLineage, let wanted = expected[key(mutation.entity.name, id)]
        else { throw TeaQLError.execution("command identity or lineage missing") }
        let identity = key(mutation.entity.name, id)
        try require(commandKeys.insert(identity).inserted, "duplicate graph command identity")
        try require(request.intent.comment == rootReason, "command lost request-owned root intent")
        try checkChain(lineage, wanted, boundary: "command \(identity)")
    }
    for (index, entry) in writes.enumerated() {
        // The frozen Rust-canonical rebuilt route intentionally has no Entity
        // ID. Bind the statement to its real command by execution index and
        // verify statement entity plus per-item lineage; do not change that
        // baseline or inject an ID into the metadata just to satisfy this test.
        let mutation = commands[index].mutation
        guard let entity = entry.tracePath.first(where: { $0.kind == "entity" }),
              let id = (mutation.id ?? mutation.values["id"])?.int64Value,
              let wanted = expected[key(entity.name, id)], entity.name == mutation.entity.name
        else { throw TeaQLError.execution("physical SQL identity missing") }
        let identity = key(entity.name, id)
        try require(sqlKeys.insert(identity).inserted, "duplicate physical SQL identity")
        try require(entry.executionOutcome == "success" && entry.auditReason == rootReason,
            "SQL lost completion outcome or root intent")
        try require(entry.tracePath.first?.name == "CustomerOrder"
            && entry.tracePath.last?.name == entry.operation.rawValue
            && !entry.tracePath.contains(where: { ["auditReason", "comment", "purpose"].contains($0.kind) }),
            "SQL route is noncanonical or includes intent prose")
        try checkChain(entry.mutationLineage, wanted, boundary: "SQL \(identity)")
    }
    for event in audit {
        guard let id = event.entityID?.int64Value, let lineage = event.mutationLineage,
              let wanted = expected[key(event.entity, id)]
        else { throw TeaQLError.execution("committed audit identity or lineage missing") }
        let identity = key(event.entity, id)
        try require(auditKeys.insert(identity).inserted, "duplicate committed audit identity")
        try require(event.reason == rootReason, "audit lost root intent")
        try checkChain(lineage, wanted, boundary: "audit \(identity)")
    }
    try require(commandKeys == Set(expected.keys) && sqlKeys == commandKeys && auditKeys == commandKeys,
        "typed identities diverged across boundaries")
}
