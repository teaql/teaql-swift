import Foundation
import Testing
import TeaQLCore
import TeaQLSQLite

@Test func legacyGeneratedDescriptorKeepsExecutionValuesButHidesDefaultSQLLog() async throws {
  let service = try SQLiteDataService(path: ":memory:")
  let sink = TextDiagnosticSQLLogSink(writer: { _ in })
  let entity = EntityDescriptor(name: "Customer", table: "legacy_customer", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "name", type: .string),
    PropertyDescriptor(name: "password", type: .string),
  ])
  #expect(entity.auditMaskFields == nil)
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }, diagnosticSQLLogSink: sink)
  try await context.ensureSchema(RuntimeModule(name: "legacy", entities: [entity]))
  _ = try await context.execute(Mutation(kind: .create, entity: entity,
    values: ["id": .int(1), "version": .int(1), "name": .string("CUSTOMER-CANARY"),
      "password": .string("PASSWORD-CANARY")],
    auditReason: "what: create legacy fixture"))

  var query = SelectQuery(entity: entity)
  query.filter = .equal("name", .string("CUSTOMER-CANARY"))
  query.limit = 1
  query.comment = "what: read legacy fixture"
  query.purpose = "why: verify old descriptor remains private"
  let rows = try await context.execute(query).records
  #expect(rows.count == 1)
  #expect(rows.first?["name"] == .string("CUSTOMER-CANARY"))
  #expect(rows.first?["password"] == .string("PASSWORD-CANARY"))

  let text = await sink.snapshot().joined(separator: "\n")
  #expect(text.contains("[REDACTED]"))
  #expect(text.contains("MASKED; NOT REPLAYABLE"))
  #expect(!text.contains("CUSTOMER-CANARY"))
  #expect(!text.contains("PASSWORD-CANARY"))
}
