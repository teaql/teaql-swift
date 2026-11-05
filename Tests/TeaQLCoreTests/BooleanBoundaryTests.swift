import Foundation
import Testing
@testable import TeaQLCore

private let booleanEntity = EntityDescriptor(name: "BooleanBoundary", table: "boolean_boundary", properties: [
  PropertyDescriptor(name: "id", type: .int, isID: true),
  PropertyDescriptor(name: "version", type: .int, isVersion: true),
  PropertyDescriptor(name: "requiredFlag", modelName: "required_flag", column: "legacy_flag", type: .bool),
  PropertyDescriptor(name: "optionalFlag", modelName: "optional_flag", type: .bool, nullable: true),
])

@Test func booleanBoundaryCoreRejectsWrongCarriersBeforeProvider() async throws {
  let invalid: [TeaQLValue] = [.int(0), .int(1), .int(2), .int(-1), .uint(1), .double(1),
    .decimal(1), .string("PRIVATE-BOOLEAN-MARKER"), .data(Data([1])), .array([]), .object([:])]
  for kind in [MutationKind.create, .update] {
    for field in ["required_flag", "requiredFlag", "legacy_flag", "optional_flag"] {
      for value in invalid {
        let provider = BooleanBoundaryProvider()
        let context = UserContext(queryExecutor: provider, mutationExecutor: provider,
          requestPolicy: RequestPolicy { $0 }, querySQLLogEnabled: false, mutationSQLLogEnabled: false)
        do {
          _ = try await context.execute(Mutation(kind: kind, entity: booleanEntity, id: .int(1),
            values: [field: value], expectedVersion: kind == .update ? 1 : nil,
            auditReason: "Reject a non-Boolean mutation carrier"))
          Issue.record("A non-Boolean value reached the provider")
        } catch let error as CheckException {
          let canonical = field == "required_flag" || field == "optional_flag"
          let path = field == "optional_flag" ? "optional_flag" : "required_flag"
          // Mutation keys are KSML names. Native/column aliases must already
          // fail canonical-name admission, not be reinterpreted as valid keys.
          #expect(error.violations.contains { $0.ruleID == (canonical ? "invalid_type" : "unknown_field") && $0.location.modelPath == path })
          #expect(!String(describing: error).contains("PRIVATE-BOOLEAN-MARKER"))
        }
        #expect(await provider.writes == 0)
      }
    }
  }
}

@Test func booleanBoundaryCoreChecksFinalFixWithoutPollutingLedger() throws {
  for value: TeaQLValue in [.int(2), .bool(false)] {
    let provider = BooleanBoundaryProvider()
    var runtime = TeaQLRuntime()
    try runtime.install(RuntimeModule(name: "boolean-fix", entities: [booleanEntity],
      checkers: [booleanEntity.name: BooleanBoundaryFix(value: value)]))
    let context = UserContext(runtime: runtime, queryExecutor: provider, mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 }, querySQLLogEnabled: false, mutationSQLLogEnabled: false)
    let ledger = EntityRoot(), key = EntityKey(entity: booleanEntity.name, id: .int(1))
    ledger.set(key, field: "required_flag", value: .bool(true))
    do {
      let result = try context.preflightMutation(Mutation(kind: .update, entity: booleanEntity,
        id: .int(1), values: ["required_flag": .int(2)], expectedVersion: 1,
        auditReason: "Validate the final Boolean Fix before publishing it"), ledgerRoot: ledger, ledgerKey: key)
      #expect(value == .bool(false))
      #expect(result.values["required_flag"] == .bool(false))
    } catch let error as CheckException {
      #expect(value == .int(2))
      #expect(error.violations.first?.wire().instancePath == "/requiredFlag")
      #expect(ledger.change(key)["required_flag"] == .bool(true))
    }
  }
}

@Test func booleanBoundaryCoreRetainsTrueFalseNullAndAbsence() throws {
  let provider = BooleanBoundaryProvider()
  let context = UserContext(queryExecutor: provider, mutationExecutor: provider,
    requestPolicy: RequestPolicy { $0 }, querySQLLogEnabled: false, mutationSQLLogEnabled: false)
  for value: TeaQLValue in [.bool(true), .bool(false)] {
    let result = try context.preflightMutation(Mutation(kind: .create, entity: booleanEntity,
      values: ["required_flag": value, "optional_flag": .null], auditReason: "Keep valid Boolean states"))
    #expect(result.values["required_flag"] == value && result.values["optional_flag"] == .null)
  }
  let partial = try context.preflightMutation(Mutation(kind: .update, entity: booleanEntity,
    id: .int(1), values: ["optional_flag": .null], expectedVersion: 1, auditReason: "Keep an absent field absent"))
  #expect(partial.values["required_flag"] == nil)
}

private struct BooleanBoundaryFix: EntityChecker {
  let value: TeaQLValue
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    mutation.values["required_flag"] = value
    return []
  }
}

private actor BooleanBoundaryProvider: MutationExecutor, QueryExecutor {
  private(set) var writes = 0
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    writes += 1
    return MutationResult(affectedRows: 1, persistedRecord: request.mutation.values)
  }
  func execute(_ request: QueryRequest) async throws -> QueryResult { QueryResult(records: [], backend: "boolean-spy") }
}
