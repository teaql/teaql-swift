import Foundation
import TeaQLCore
import TeaQLSQLite
import Testing

private actor PhysicalLeaseHolder {
  var lease: (any GraphPhysicalSQLLease)?
  func retain(_ value: any GraphPhysicalSQLLease) { lease = value }
  func get() -> (any GraphPhysicalSQLLease)? { lease }
}

private func physicalGraphFixture() async throws -> (UserContext, PhysicalLeaseHolder, EntityDescriptor) {
  let asset = EntityDescriptor(name: "Asset", table: "physical_asset", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "name", type: .string),
  ])
  let service = try SQLiteDataService(path: ":memory:")
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 })
  try await context.ensureSchema(RuntimeModule(name: "physical", entities: [asset]))
  try await context.executeGraphSave(comment: "create module table") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("CREATE TABLE module_binding (id INTEGER PRIMARY KEY, asset_id INTEGER NOT NULL)",
        parameters: [])
    }
  }
  return (context, PhysicalLeaseHolder(), asset)
}

private func physicalCounts(_ context: UserContext) async throws -> (Int, Int) {
  try await context.executeGraphSave(comment: "inspect physical rows") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      let assets = try await sql.query("SELECT id FROM physical_asset", parameters: [])
      let bindings = try await sql.query("SELECT id FROM module_binding", parameters: [])
      return (assets.count, bindings.count)
    }
  }
}

@Test
func swiftPhysicalSQLSharesNativeGraphCommitRollbackAndExpires() async throws {
  let (context, holder, asset) = try await physicalGraphFixture()
  func save(_ id: Int64, abort: Bool) async throws {
    try await context.executeGraphSave(comment: "save asset") { graph, session in
      _ = try await graph.execute(Mutation(kind: .create, entity: asset,
        values: ["id": .int(id), "name": .string("document")], auditReason: session.intent.comment))
      try await graph.withPhysicalSQL(session) { sql in
        await holder.retain(sql)
        _ = try await sql.execute("INSERT INTO module_binding(id, asset_id) VALUES (?, ?)",
          parameters: [.int(id), .int(id)])
        let rows = try await sql.query("SELECT id FROM physical_asset WHERE id = ?", parameters: [.int(id)])
        #expect(rows.count == 1)
      }
      if abort { throw TeaQLError.execution("abort graph") }
    }
  }
  try await save(1, abort: false)
  #expect(try await physicalCounts(context) == (1, 1))
  do { try await save(2, abort: true); Issue.record("graph should roll back") }
  catch { #expect(error as? TeaQLError == .execution("abort graph")) }
  #expect(try await physicalCounts(context) == (1, 1))
  do {
    _ = try await holder.get()!.execute("DELETE FROM module_binding", parameters: [])
    Issue.record("expired module lease was accepted")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_TRANSACTION_REQUIRED")) }
}

@Test(arguments: [false, true])
func swiftCaughtPhysicalCallbackOrSQLErrorPoisonsGraph(sqlFailure: Bool) async throws {
  let (context, _, asset) = try await physicalGraphFixture()
  do {
    try await context.executeGraphSave(comment: "save asset") { graph, session in
      _ = try await graph.execute(Mutation(kind: .create, entity: asset,
        values: ["id": .int(1), "name": .string("document")], auditReason: session.intent.comment))
      do {
        try await graph.withPhysicalSQL(session) { sql in
          _ = try await sql.execute("INSERT INTO module_binding(id, asset_id) VALUES (1, 1)", parameters: [])
          if sqlFailure {
            do {
              _ = try await sql.execute("INSERT INTO module_binding(id, asset_id) VALUES (1, 1)", parameters: [])
            } catch { }
          } else { throw TeaQLError.execution("module rejected binding") }
        }
      } catch { }
    }
    Issue.record("caught module failure committed")
  } catch { #expect(error as? TeaQLError == .execution("GRAPH_TRANSACTION_ROLLBACK_ONLY")) }
  #expect(try await physicalCounts(context) == (0, 0))
}
