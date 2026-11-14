import CSQLite
import Foundation
import Testing
@testable import TeaQLCore
import TeaQLSQLite

@Test func NestedPopulationKeepsCompleteDetailAndStatisticalGroups() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("teaql-nested-\(UUID())")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let path = directory.appendingPathComponent("probe.sqlite").path
  let bucket = EntityDescriptor(name: "Bucket", table: "np_bucket", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true)])
  let entry = EntityDescriptor(name: "Entry", table: "np_entry", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "bucket", type: .int)])
  let service = try SQLiteDataService(path: path)
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }, querySQLLogEnabled: false, mutationSQLLogEnabled: false)
  try await context.ensureSchema(RuntimeModule(name: "nested population", entities: [bucket, entry]))
  // Native provider fixture, not an application write/repair path.
  var database: OpaquePointer?
  guard sqlite3_open(path, &database) == SQLITE_OK else { throw TeaQLError.execution("fixture open") }
  defer { sqlite3_close(database) }
  let seed = "INSERT INTO np_bucket VALUES(1,1); WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<10003) INSERT INTO np_entry SELECT x,1,1 FROM n;"
  guard sqlite3_exec(database, seed, nil, nil, nil) == SQLITE_OK else { throw TeaQLError.execution("fixture seed") }
  func query(_ entity: EntityDescriptor) -> SelectQuery {
    var result = SelectQuery(entity: entity)
    result.comment = "inspect complete nested population"; result.purpose = "avoid silent statistical truncation"
    return result
  }
  let child = query(entry)
  #expect(try child.validatedForExecution().limit == nil)
  var root = query(bucket); root.limit = 1
  root.relationQuery("entries", localKey: "id", foreignKey: "bucket", query: child)
  let details = try await context.execute(root)
  guard case .array(let children) = details.records.first?["entries"] else { Issue.record("missing children"); return }
  #expect(children.count == 10003)
  root = query(bucket); root.limit = 1
  var groups = query(entry); groups.groupBy = ["id"]
  groups.aggregates = [QueryAggregate(.count, field: "id", alias: "n")]
  let owner = try QueryRequest(query: root)
  let grouped = owner.derive(groups, scope: try owner.scope.child(entity: "Entry", comment: "all grouped contributions"))
  let statistical = try await context.execute(grouped)
  #expect(statistical.records.count == 10003)
  var bounded = child; bounded.limit = 2
  root = query(bucket); root.limit = 1
  root.relationQuery("entries", localKey: "id", foreignKey: "bucket", query: bounded)
  let selected = try await context.execute(root)
  guard case .array(let selectedChildren) = selected.records.first?["entries"] else { Issue.record("missing selected children"); return }
  #expect(selectedChildren.count == 2)
  bounded.limit = 10001
  root = query(bucket); root.limit = 1
  root.relationQuery("entries", localKey: "id", foreignKey: "bucket", query: bounded)
  let wide = try await context.execute(root)
  guard case .array(let wideChildren) = wide.records.first?["entries"] else { Issue.record("missing wide selection"); return }
  #expect(wideChildren.count == 10001)
}
