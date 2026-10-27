import Foundation
import Testing
@testable import TeaQLCore

private let finiteEntity = EntityDescriptor(name: "FiniteProbe", table: "finite_probe", properties: [
  PropertyDescriptor(name: "id", type: .int, isID: true),
  PropertyDescriptor(name: "version", type: .int, isVersion: true),
  PropertyDescriptor(name: "requiredFloat", modelName: "required_float", type: .double),
  PropertyDescriptor(name: "optionalFloat", modelName: "optional_float", type: .double, nullable: true),
  PropertyDescriptor(name: "requiredDouble", modelName: "required_double", column: "legacy_required_double", type: .double),
  PropertyDescriptor(name: "optionalDouble", modelName: "optional_double", type: .double, nullable: true),
])

@Test func finiteMutationRejectsNonfiniteCreateAndUpdateWithoutCheckerBeforeProvider() async throws {
  for kind in [MutationKind.create, .update] {
    for field in ["required_float", "optional_float", "required_double", "optional_double"] {
      for value in [Double.nan, .infinity, -.infinity] {
        let provider = FiniteMutationProvider()
        let context = UserContext(queryExecutor: provider, mutationExecutor: provider,
          requestPolicy: RequestPolicy { $0 })
        do {
          _ = try await context.execute(Mutation(kind: kind, entity: finiteEntity, id: .int(1),
            values: [field: .double(value)], expectedVersion: kind == .update ? 1 : nil,
            auditReason: "verify finite numeric admission"))
          Issue.record("Non-finite \(kind.rawValue) \(field) reached the provider")
        } catch let error as CheckException {
          #expect(error.violations.contains { $0.ruleID == "invalid_type" && $0.location.modelPath == field })
        }
        #expect(await provider.writes == 0)
      }
    }
  }
}

@Test func finiteMutationValidatesFinalCustomFixButAllowsAFiniteRepair() async throws {
  for replacement in [Double.nan, .infinity, -.infinity, 7.25] {
    let provider = FiniteMutationProvider()
    var runtime = TeaQLRuntime()
    try runtime.install(RuntimeModule(name: "finite-fix", entities: [finiteEntity],
      checkers: [finiteEntity.name: FiniteMutationFix(value: replacement)]))
    let context = UserContext(runtime: runtime, queryExecutor: provider, mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 })
    do {
      let result = try await context.execute(Mutation(kind: .create, entity: finiteEntity,
        values: ["required_double": .double(.nan)], auditReason: "check the final custom Fix value"))
      #expect(replacement.isFinite)
      #expect(result.persistedRecord?["required_double"] == .double(7.25))
    } catch let error as CheckException {
      #expect(!replacement.isFinite)
      #expect(error.violations.contains { $0.ruleID == "invalid_type" && $0.location.modelPath == "required_double" })
    }
    #expect(await provider.writes == (replacement.isFinite ? 1 : 0))
  }
}

@Test func finiteMutationPreflightUsesCanonicalLocationForNativeAndColumnAliases() throws {
  let provider = FiniteMutationProvider()
  let context = UserContext(queryExecutor: provider, mutationExecutor: provider,
    requestPolicy: RequestPolicy { $0 })
  for field in ["required_double", "requiredDouble", "legacy_required_double"] {
    do {
      _ = try context.preflightMutation(Mutation(kind: .create, entity: finiteEntity,
        values: [field: .double(.infinity)], auditReason: "check preflight field location"))
      Issue.record("Preflight accepted a non-finite value")
    } catch let error as CheckException {
      #expect(error.violations.count == 1)
      #expect(error.violations.first?.location.modelPath == "required_double")
      #expect(error.violations.first?.wire().instancePath == "/requiredDouble")
    }
  }
  _ = try context.preflightMutation(Mutation(kind: .create, entity: finiteEntity,
    values: ["required_double": .double(-7.5), "optional_double": .null],
    auditReason: "finite negative values and explicit nullable null remain valid"))
}

@Test func finiteMutationRejectedCustomFixDoesNotPolluteTheCallerLedger() throws {
  let provider = FiniteMutationProvider()
  var runtime = TeaQLRuntime()
  try runtime.install(RuntimeModule(name: "finite-ledger", entities: [finiteEntity],
    checkers: [finiteEntity.name: FiniteMutationFix(value: .infinity)]))
  let context = UserContext(runtime: runtime, queryExecutor: provider, mutationExecutor: provider,
    requestPolicy: RequestPolicy { $0 })
  let ledger = EntityRoot(), key = EntityKey(entity: finiteEntity.name, id: .int(1))
  ledger.set(key, field: "required_double", value: .double(7.25))
  do {
    _ = try context.preflightMutation(Mutation(kind: .update, entity: finiteEntity, id: .int(1),
      values: ["required_double": .double(7.25)], expectedVersion: 1,
      auditReason: "retain the pending edit after rejected Fix"),
      ledgerRoot: ledger, ledgerKey: key)
    Issue.record("Invalid custom Fix was accepted")
  } catch is CheckException { }
  #expect(ledger.change(key)["required_double"] == .double(7.25))
}

private struct FiniteMutationFix: EntityChecker {
  let value: Double
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    mutation.values["required_double"] = .double(value)
    return []
  }
}

private actor FiniteMutationProvider: MutationExecutor, QueryExecutor {
  private(set) var writes = 0
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    writes += 1
    return MutationResult(affectedRows: 1, persistedRecord: request.mutation.values)
  }
  func execute(_ request: QueryRequest) async throws -> QueryResult { QueryResult(records: [], backend: "finite-spy") }
}
