import Foundation
import TeaQLCore
import TeaQLSQL
import TeaQLSQLite
import Testing

@Test
func swiftModeledBlobSQLIsTypedAndNativeMutationFailsClosed() async throws {
  let reference = try BlobRef("blob_swift_typed_1")
  let spec = try BlobFieldSpec(entity: "Asset", field: "document", extensions: ["pdf"],
    nullable: true, policyProfile: "default")
  let asset = EntityDescriptor(name: "Asset", table: "blob_asset", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "document", type: .blobRef, nullable: true, blobSpec: spec),
  ])
  let control = EntityDescriptor(name: "Control", table: "blob_control", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
  ])
  let service = try SQLiteDataService(path: ":memory:")
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 })
  try await context.ensureSchema(RuntimeModule(name: "modeled-blob", entities: [asset, control]))
  #expect(try SQLiteCompiler().createTable(asset).contains("VARCHAR(128)"))
  #expect(SQLParameterLogPolicy.field("document", in: asset) == .credential)
  let diagnostic = CompiledSQL(sql: "SELECT ?", parameters: [.blobRef(reference)])
  #expect(diagnostic.debugSQL().contains("[REDACTED]"))
  #expect(!diagnostic.debugSQL().contains(reference.key))
  do { _ = try JSONEncoder().encode(TeaQLValue.blobRef(reference)); Issue.record("raw Blob JSON accepted") }
  catch { }

  try await context.executeGraphSave(comment: "trusted SQL fixture") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("INSERT INTO blob_asset(id,version,document) VALUES (1,1,?)",
        parameters: [.blobRef(reference)])
      let rows = try await sql.query("SELECT document FROM blob_asset WHERE id=1", parameters: [])
      #expect(rows.first?["document"]?.stringValue == reference.key)
    }
  }
  var query = SelectQuery(entity: asset)
  query.filter = .equal("id", .int(1))
  query.limit = 1
  query.comment = "read typed document"
  query.purpose = "verify model-bound Blob readback"
  let result = try await context.execute(query)
  #expect(result.records.first?["document"] == .blobRef(reference))

  do {
    try await context.executeGraphSave(comment: "caught modeled Blob mutation") { actor, session in
      _ = try await actor.execute(Mutation(kind: .create, entity: control,
        values: ["id": .int(1)], auditReason: session.intent.comment))
      do {
        _ = try await actor.execute(Mutation(kind: .create, entity: asset,
          values: ["id": .int(2), "document": .blobRef(reference)],
          auditReason: session.intent.comment))
        Issue.record("modeled mutation without catalog participant accepted")
      } catch { }
    }
    Issue.record("caught Blob failure committed ordinary row")
  } catch { #expect(error as? TeaQLError == .execution("GRAPH_TRANSACTION_ROLLBACK_ONLY")) }
  try await context.executeGraphSave(comment: "inspect rollback") { actor, session in
    try await actor.withPhysicalSQL(session) { sql in
      let controls = try await sql.query("SELECT id FROM blob_control", parameters: [])
      let assets = try await sql.query("SELECT id FROM blob_asset", parameters: [])
      #expect(controls.isEmpty)
      #expect(assets.count == 1)
    }
  }

  try await context.executeGraphSave(comment: "seed invalid legacy Key") { actor, session in
    try await actor.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("INSERT INTO blob_asset(id,version,document) VALUES (3,1,'raw-url')",
        parameters: [])
    }
  }
  query.filter = .equal("id", .int(3))
  do { _ = try await context.execute(query); Issue.record("invalid legacy Key read as a BlobRef") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_REFERENCE_INVALID")) }
}
