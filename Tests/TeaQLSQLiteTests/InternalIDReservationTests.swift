import Foundation
import Testing
import TeaQLCore
import TeaQLSQLite

@Suite("Durable creation ID reservation")
struct InternalIDReservationTests {
  private var entity: EntityDescriptor {
    EntityDescriptor(name: "CreationItem", table: "creation_item", properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "version", type: .int, isVersion: true),
      PropertyDescriptor(name: "name", type: .string),
    ])
  }
  private func context(_ service: SQLiteDataService) -> UserContext {
    UserContext(queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 },
      querySQLLogEnabled: false, mutationSQLLogEnabled: false)
  }
  private func database() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("teaql-creation-id-\(UUID().uuidString).sqlite").path
  }
  @Test func reservationIsCommittedBeforeReturnWithoutBusinessRowsOrAudits() async throws {
    let path = database(), service = try SQLiteDataService(path: path), ctx = context(service)
    try await ctx.ensureSchema(RuntimeModule(name: "creation", entities: [entity]))
    #expect(try await ctx.generateInternalID(for: entity.name) == 1)
    let reopened = try SQLiteDataService(path: path)
    #expect(try await context(reopened).generateInternalID(for: entity.name) == 2)
    var query = SelectQuery(entity: entity); query.limit = 10
    query.comment = "inspect reserved creation IDs"; query.purpose = "prove allocation did not insert a business row"
    #expect(try await ctx.execute(query).records.isEmpty)
    #expect(try await service.auditEvents().isEmpty)
  }
  @Test func explicitConstantFloorAndReservationsShareOnePersistentSpace() async throws {
    let service = try SQLiteDataService(path: database()), ctx = context(service)
    try await service.ensureIDFloor(typeName: entity.name, floor: 1002)
    #expect(try await ctx.generateInternalID(for: entity.name) == 1003)
    try await service.ensureIDFloor(typeName: entity.name, floor: 7)
    #expect(try await ctx.generateInternalID(for: entity.name) == 1004)
    #expect(try await ctx.generateInternalID(for: "AnotherEntity") == 1)
  }
  @Test func maximumIdentityDoesNotWrapOrChangeOnFailure() async throws {
    let service = try SQLiteDataService(path: database()), ctx = context(service)
    try await ctx.ensureSchema(RuntimeModule(name: "creation", entities: [entity]))
    try await service.ensureIDFloor(typeName: entity.name, floor: Int64.max - 1)
    #expect(try await ctx.generateInternalID(for: entity.name) == Int64.max)
    for _ in 0..<2 {
      do { _ = try await ctx.generateInternalID(for: entity.name); Issue.record("SQLite ID sequence wrapped") }
      catch { #expect(String(describing: error).contains("overflow")) }
    }
    #expect(try await ctx.generateInternalID(for: "UnaffectedEntity") == 1)
    #expect(try await service.auditEvents().isEmpty)
  }
  @Test func reservationCannotJoinOrRollbackAnExistingGraph() async throws {
    let service = try SQLiteDataService(path: database()), ctx = context(service)
    try await ctx.ensureSchema(RuntimeModule(name: "creation", entities: [entity]))
    try await service.beginGraphTransaction()
    do { _ = try await ctx.generateInternalID(for: entity.name); Issue.record("reservation joined graph") }
    catch let error as InternalIDError { #expect(error == .activeGraph) }
    try await service.rollbackGraphTransaction()
    #expect(try await ctx.generateInternalID(for: entity.name) == 1)
    // A separate graph rollback cannot reuse the already returned identity.
    try await service.beginGraphTransaction(); try await service.rollbackGraphTransaction()
    #expect(try await ctx.generateInternalID(for: entity.name) == 2)
  }
  @Test func independentContextReservationsStayUnique() async throws {
    let service = try SQLiteDataService(path: database()), a = context(service), b = context(service)
    let ids = try await withThrowingTaskGroup(of: Int64.self) { group in
      for i in 0..<32 { group.addTask { try await (i.isMultiple(of: 2) ? a : b).generateInternalID(for: "CreationItem") } }
      var result: [Int64] = []; for try await id in group { result.append(id) }; return result
    }
    #expect(ids.sorted() == Array(1...32).map(Int64.init))
  }
}
