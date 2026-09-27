import Foundation
import Testing
import TeaQLCore
import TeaQLSQLite

@Test func sqliteCRUDLogPrivacyPreservesValues() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-privacy-crud-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let file = directory.appendingPathComponent("runtime.log")
  #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
  let handle = try FileHandle(forWritingTo: file)
  defer { try? handle.close() }
  let service = try SQLiteDataService(path: directory.appendingPathComponent("data.db").path)
  let entity = EntityDescriptor(name: "PrivatePerson", table: "private_person", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "name", type: .string),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
  ])
  let evidence = SQLExecutionEvidenceStore()
  let sink = TextDiagnosticSQLLogSink(writer: { text in
    handle.write(Data((text + "\n").utf8))
  })
  let context = UserContext(actor: "privacy-test", queryExecutor: service,
    mutationExecutor: service, requestPolicy: RequestPolicy { $0 },
    telemetrySink: evidence, diagnosticSQLLogSink: sink)
  try await context.ensureSchema(RuntimeModule(name: "privacy", entities: [entity]))
  let markers = ["PRIVATE-CREATE-CANARY", "PRIVATE-UPDATE-CANARY", "PRIVATE-FAILURE-CANARY"]
  func insert(_ value: String) async throws {
    _ = try await context.execute(Mutation(kind: .create, entity: entity,
      values: ["id": .int(1), "version": .int(1), "name": .string(value)],
      auditReason: "create privacy fixture"))
  }
  func read() async throws -> [TeaQLRecord] {
    var query = SelectQuery(entity: entity)
    query.limit = 1
    // Swift's mutation delete is soft deletion; query active rows explicitly.
    query.filter = .greaterThanOrEqual("version", .int(1))
    query.comment = "read privacy fixture"
    query.purpose = "verify original execution values"
    return try await context.execute(query).records
  }
  try await insert(markers[0])
  #expect(try await read().first?["name"] == .string(markers[0]))
  _ = try await context.execute(Mutation(kind: .update, entity: entity, id: .int(1),
    values: ["name": .string(markers[1])], expectedVersion: 1,
    auditReason: "update privacy fixture"))
  #expect(try await read().first?["name"] == .string(markers[1]))
  await #expect(throws: (any Error).self) { try await insert(markers[2]) }
  #expect(try await read().first?["name"] == .string(markers[1]))
  _ = try await context.execute(Mutation(kind: .delete, entity: entity, id: .int(1),
    expectedVersion: 2, auditReason: "delete privacy fixture"))
  #expect(try await read().isEmpty)
  let entries = await evidence.snapshot()
  #expect(entries.contains { $0.operation == .insert })
  #expect(entries.contains { $0.operation == .update })
  #expect(entries.contains { $0.operation == .delete })
  #expect(entries.contains { $0.operation == .select })
  let text = try String(contentsOf: file, encoding: .utf8)
  #expect(!text.isEmpty)
  let logs = text + String(describing: entries)
  for marker in markers { #expect(!logs.contains(marker)) }
}
