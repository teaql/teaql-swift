import Foundation
import TeaQLCore

func queryRoutes(_ branch: String, threshold: Int = 0) -> [[String]] {
    if branch == "root" {
        return [[], [], ["schoolType"], ["schoolType"], ["schoolType", "platform"]]
    }
    if branch == "to-one" {
        return [[], ["schoolType"], ["schoolType"], ["schoolType"],
            ["schoolType", "platform"], ["schoolType"], ["schoolType", "platform"]]
    }
    return [[], ["schoolList"]] + (threshold == 0 ? [] : [["schoolList"]])
        + [["schoolList"], ["schoolList", "schoolType"], ["schoolList", "schoolType"],
           ["schoolList", "schoolType", "platform"], ["schoolList"],
           ["schoolList", "schoolType"], ["schoolList", "schoolType"],
           ["schoolList", "schoolType", "platform"]]
}

struct StatementProof: Codable {
    let operation: String
    let comment: String?
    let purpose: String?
    let auditReason: String?
    let path: [TraceNode]
    let lineage: [TraceNode]
    let sql: String
    let resultCount: Int?
    let affectedRows: Int?
    let outcome: String?

    init(_ fact: SQLExecutionMetadata) {
        operation = fact.operation.rawValue
        comment = fact.comment; purpose = fact.purpose; auditReason = fact.auditReason
        path = fact.tracePath; lineage = fact.mutationLineage
        sql = fact.debugSQL; resultCount = fact.resultCount
        affectedRows = fact.affectedRows; outcome = fact.executionOutcome
    }
}
func choices(_ records: SmartList<[String: TeaQLValue]>) throws -> [[Int64]] {
    try records.map { row in
        guard let id = row["id"]?.int64Value, let count = row["count"]?.int64Value else {
            throw TeaQLError.execution("Facet identity/count absent; missing is not zero")
        }
        return [id, count]
    }
}
struct ChildProof: Codable {
    let id: Int64
    let members: [Int64]
    let loaded: Bool
    let types: [[Int64]]
    let platforms: [[Int64]]
}
func childProof<T>(_ list: SmartList<T>, id: Int64, members: [Int64]) throws -> ChildProof {
    guard let types = list.facets["types"], let platforms = types.facets["platforms"] else {
        throw TeaQLError.execution("requested nested Facet metadata is missing")
    }
    return ChildProof(id: id, members: members, loaded: list.isLoaded,
        types: try choices(types), platforms: try choices(platforms))
}
struct QueryProof: Codable {
    let branch: String
    let logging: Bool
    let includeAll: Bool
    var empty: Bool? = nil
    var threshold: Int? = nil
    let visible: Int
    var types: [[Int64]]? = nil
    var platforms: [[Int64]]? = nil
    var children: [ChildProof]? = nil
    var identities: [Int64]? = nil
    var hiddenDetailFailures: Int? = nil
    let sql: [StatementProof]
    let diagnostics: Int
    var nextSQL: [StatementProof]? = nil
}
struct WritebackProof: Encodable {
    let branch = "writeback"
    let logging: Bool
    let id: Int64
    let oldAddress: String
    let newAddress: String
    let beforeVersion: Int64
    let afterVersion: Int64
    let noopWrites: Int
    let noopAudits: Int
    let updateWrites: Int
    let audits: Int
    let auditEvents: [AuditEvent]
    let sql: [StatementProof]
}
func emitProof<T: Encodable>(_ proof: T) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    print("SWIFT_FACET " + String(decoding: try encoder.encode(proof), as: UTF8.self))
}
