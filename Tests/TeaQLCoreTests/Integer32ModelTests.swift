import Foundation
import Testing
@testable import TeaQLCore

// Decode model metadata instead of referring to a newly added initializer label:
// exactly the same fixture compiles and executes on the pre-repair runtime.
private func integer32Model(_ extra: String = "") throws -> EntityDescriptor {
  let source = """
    {"name":"IntegerWidthProbe","table":"integer_width_probe","properties":[
      {"name":"id","type":"int","isID":true},
      {"name":"version","type":"int","isVersion":true},
      {"name":"requiredInteger","modelName":"required_integer","column":"legacy_required_integer","type":"int","isInt32":true\(extra)},
      {"name":"optionalInteger","modelName":"optional_integer","type":"int","nullable":true,"isInt32":true},
      {"name":"requiredLong","modelName":"required_long","type":"int"}]}
    """
  return try JSONDecoder().decode(EntityDescriptor.self, from: Data(source.utf8))
}

@Suite("Modeled Integer signed width")
struct Integer32ModelTests {
  @Test func integer32MutationRejectsBothBoundsForRequiredOptionalCreateAndUpdate() async throws {
    let entity = try integer32Model()
    for kind in [MutationKind.create, .update] {
      for field in ["required_integer", "optional_integer"] {
        for value: Int64 in [-2_147_483_649, 2_147_483_648] {
          let provider = IntegerWidthProvider(), context = integerContext(entity, provider)
          do {
            _ = try await context.execute(integerMutation(entity, kind, field, .int(value)))
            Issue.record("Out-of-domain modeled Integer reached the provider")
          } catch let error as CheckException {
            #expect(error.violations.contains { $0.ruleID == "invalid_type" && $0.location.modelPath == field && $0.entityType == entity.name })
            #expect(!String(describing: error).contains(String(value)))
          }
          #expect(await provider.writes == 0)
          #expect(await provider.queries == 0)
        }
      }
    }
  }

  @Test func integer32CustomFixCannotWidenAndRejectedFixPreservesPendingLedger() throws {
    let entity = try integer32Model()
    for field in ["required_integer", "optional_integer"] {
      for value: Int64 in [-2_147_483_649, 2_147_483_648] {
        let provider = IntegerWidthProvider(), calls = IntegerWidthCalls()
        let context = try integerContext(entity, provider, checker: IntegerWidthFix(field: field, value: .int(value), calls: calls))
        let root = EntityRoot(), key = EntityKey(entity: entity.name, id: .int(5))
        root.set(key, field: field, value: .int(7))
        do {
          _ = try context.preflightMutation(integerMutation(entity, .update, field, .int(7)), ledgerRoot: root, ledgerKey: key)
          Issue.record("Custom Fix bypassed the modeled Integer boundary")
        } catch let error as CheckException {
          #expect(error.violations.contains { $0.ruleID == "invalid_type" && $0.location.modelPath == field })
        }
        #expect(root.change(key)[field] == .int(7))
        #expect(calls.count == 1)
      }
    }
  }

  @Test func integer32LegalEndpointsAndWideLongIdentityVersionArePreserved() async throws {
    let entity = try integer32Model(), provider = IntegerWidthProvider(), context = integerContext(entity, provider)
    for value: Int64 in [-2_147_483_648, 0, 2_147_483_647] {
      let result = try await context.execute(integerMutation(entity, .create, "required_integer", .int(value)))
      #expect(result.persistedRecord?["required_integer"] == .int(value))
    }
    let wide: TeaQLRecord = ["id": .int(Int64.max), "version": .int(Int64.max - 1), "required_long": .int(Int64.min), "optional_integer": .null]
    let result = try await context.execute(Mutation(kind: .create, entity: entity, values: wide, auditReason: "keep wide values outside the modeled Integer domain"))
    #expect(result.persistedRecord == wide)
    #expect(await provider.writes == 4)
  }

  @Test func integer32FixCanRepairInputBeforeWidthAdmissionExactlyOnce() async throws {
    let entity = try integer32Model(), provider = IntegerWidthProvider(), calls = IntegerWidthCalls()
    let context = try integerContext(entity, provider, checker: IntegerWidthFix(field: "required_integer", value: .int(2_147_483_647), calls: calls))
    let result = try await context.execute(integerMutation(entity, .create, "required_integer", .int(Int64.max)))
    #expect(result.persistedRecord?["required_integer"] == .int(2_147_483_647))
    #expect(calls.count == 1)
    #expect(await provider.writes == 1)
  }

  @Test func integer32ModelMarkerSurvivesMetadataRoundTripButLegacyIntStaysWide() async throws {
    let entity = try integer32Model(), bytes = try JSONEncoder().encode(entity)
    let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    let properties = object["properties"] as! [[String: Any]]
    #expect(properties[2]["isInt32"] as? Bool == true)
    #expect(properties[3]["isInt32"] as? Bool == true)
    #expect(properties[4]["isInt32"] as? Bool != true)
    let legacy = EntityDescriptor(name: "Legacy", table: "legacy", properties: [PropertyDescriptor(name: "number", type: .int)])
    let provider = IntegerWidthProvider(), context = integerContext(legacy, provider)
    let result = try await context.execute(Mutation(kind: .create, entity: legacy, values: ["number": .int(Int64.max)], auditReason: "do not narrow legacy 64-bit metadata"))
    #expect(result.persistedRecord?["number"] == .int(Int64.max))
  }

  @Test func integer32ExactDecimalDoesNotTruncateFractionalOrCoerceOtherScalarKinds() throws {
    let entity = try integer32Model(), provider = IntegerWidthProvider(), context = integerContext(entity, provider)
    for value: TeaQLValue in [.decimal(Decimal(string: "3.5")!), .decimal(.nan), .double(3), .string("3"), .bool(true), .timestamp(3), .uint(UInt64.max)] {
      do {
        _ = try context.preflightMutation(integerMutation(entity, .create, "required_integer", value))
        Issue.record("An inexact or unrelated scalar masqueraded as Integer")
      } catch let error as CheckException {
        #expect(error.violations.contains { $0.ruleID == "invalid_type" && $0.location.modelPath == "required_integer" })
      }
    }
    for value: TeaQLValue in [.decimal(Decimal(string: "42.000")!), .uint(42)] {
      let result = try context.preflightMutation(integerMutation(entity, .create, "required_integer", value))
      #expect(result.values["required_integer"] == .int(42))
    }
  }
}

private func integerMutation(_ entity: EntityDescriptor, _ kind: MutationKind, _ field: String, _ value: TeaQLValue) -> Mutation {
  Mutation(kind: kind, entity: entity, id: kind == .update ? .int(5) : nil, values: [field: value],
    expectedVersion: kind == .update ? 7 : nil, auditReason: "verify modeled Integer width after Fix")
}
private func integerContext(_ entity: EntityDescriptor, _ provider: IntegerWidthProvider) -> UserContext {
  UserContext(queryExecutor: provider, mutationExecutor: provider, requestPolicy: RequestPolicy { $0 }, querySQLLogEnabled: false, mutationSQLLogEnabled: false)
}
private func integerContext(_ entity: EntityDescriptor, _ provider: IntegerWidthProvider, checker: any EntityChecker) throws -> UserContext {
  var runtime = TeaQLRuntime(); try runtime.install(RuntimeModule(name: "integer-width", entities: [entity], checkers: [entity.name: checker]))
  return UserContext(runtime: runtime, queryExecutor: provider, mutationExecutor: provider,
    requestPolicy: RequestPolicy { $0 }, querySQLLogEnabled: false, mutationSQLLogEnabled: false)
}
private final class IntegerWidthCalls: @unchecked Sendable {
  private let lock = NSLock(); private var value = 0
  func increment() { lock.withLock { value += 1 } }
  var count: Int { lock.withLock { value } }
}
private struct IntegerWidthFix: EntityChecker {
  let field: String; let value: TeaQLValue; let calls: IntegerWidthCalls
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    calls.increment(); mutation.values[field] = value; return []
  }
}
private actor IntegerWidthProvider: MutationExecutor, QueryExecutor {
  private(set) var writes = 0, queries = 0
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    writes += 1; return MutationResult(affectedRows: 1, persistedRecord: request.mutation.values)
  }
  func execute(_ request: QueryRequest) async throws -> QueryResult {
    queries += 1; return QueryResult(records: [], backend: "integer-width-spy")
  }
}
