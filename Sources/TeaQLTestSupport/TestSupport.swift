import Foundation
import TeaQLCore
import TeaQLSQLite

public actor RecordingAuditSink: AuditSink {
  private var storedEvents: [AuditEvent] = []

  public init() {}

  public func record(_ event: AuditEvent) async throws {
    storedEvents.append(event)
  }

  public func events() -> [AuditEvent] { storedEvents }
}

public enum TeaQLTestDatabase {
  public static func sqlite(
    entities: [EntityDescriptor],
    name: String = UUID().uuidString
  ) async throws -> (service: SQLiteDataService, path: String) {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("teaql-\(name).sqlite").path
    let service = try SQLiteDataService(path: path)
    let context = UserContext(
      queryExecutor: service, mutationExecutor: service,
      requestPolicy: RequestPolicy { $0 })
    try await context.ensureSchema(RuntimeModule(name: "TeaQLTestDatabase", entities: entities))
    return (service, path)
  }
}
