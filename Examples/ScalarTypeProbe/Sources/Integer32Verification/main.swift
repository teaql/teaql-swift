import Foundation
import CSQLite
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

private struct WidthEffects: Encodable, Equatable { var queries = 0, mutations = 0, begins = 0, commits = 0, rollbacks = 0 }
private actor WidthProvider: QueryExecutor, GraphTransactionExecutor, InternalIDGenerator {
  // Reservation is infrastructure I/O, not a business query/mutation/audit.
  func nextID(for entity: String, context: UserContext) async throws -> Int64 {
    try await service.nextID(for: entity, context: context)
  }
  let service: SQLiteDataService
  private var effects = WidthEffects()
  init(_ service: SQLiteDataService) { self.service = service }
  func snapshot() -> WidthEffects { effects }
  func execute(_ request: QueryRequest) async throws -> QueryResult { effects.queries += 1; return try await service.execute(request) }
  func execute(_ request: MutationRequest) async throws -> MutationResult { effects.mutations += 1; return try await service.execute(request) }
  func beginGraphTransaction() async throws { effects.begins += 1; try await service.beginGraphTransaction() }
  func commitGraphTransaction() async throws { effects.commits += 1; try await service.commitGraphTransaction() }
  func rollbackGraphTransaction() async throws { effects.rollbacks += 1; try await service.rollbackGraphTransaction() }
}
private final class WidthFix: EntityChecker, @unchecked Sendable {
  let base: any EntityChecker; let field: String; let replacement: TeaQLValue
  private let lock = NSLock(); private var count = 0
  init(base: any EntityChecker, field: String, replacement: TeaQLValue) { self.base = base; self.field = field; self.replacement = replacement }
  var calls: Int { lock.withLock { count } }
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    lock.withLock { count += 1 }; mutation.values[field] = replacement
    return try base.checkAndFix(context: context, mutation: &mutation, now: now)
  }
}
private enum WidthField: String, CaseIterable {
  case required = "required_integer", optional = "optional_integer"
  var native: String { self == .required ? "requiredInteger" : "optionalInteger" }
  func assign(_ entity: inout ScalarTypeProbe, _ value: Int64) {
    if self == .required { entity.updateRequiredInteger(value) } else { entity.updateOptionalInteger(value) }
  }
}
private struct WidthCase: Encodable {
  let name: String, passed: Bool, effectFree: Bool, fixCalls: Int?, error: String?
}
private struct WidthLegacyRow: Encodable { let id: Int64, field: String, fault: String }

@main enum Integer32Verification {
  private static let purpose = "Verify generated modeled Integer boundaries after Fix and during typed reads"
  private static func require(_ value: Bool, _ message: String) throws { if !value { throw TeaQLError.execution(message) } }
  private static func make(_ context: UserContext, tag: String, long: Int64 = 1_234_567) async throws -> ScalarTypeProbe {
    var entity = try await Q.scalarTypeProbes().comment("Prepare a generated Integer fixture").purpose(purpose).newEntity(context)
    entity.updateTypePlatform(1); entity.updateRequiredString(tag); entity.updateRequiredBoolean(true)
    entity.updateRequiredInteger(7); entity.updateRequiredLong(long); entity.updateRequiredDecimal(1)
    entity.updateRequiredFloat(1.25); entity.updateRequiredDouble(2.5)
    entity.updateRequiredDate(Date(timeIntervalSince1970: 1_792_454_400)); entity.updateRequiredTime("09:30:15")
    entity.updateRequiredDatetime(Date(timeIntervalSince1970: 1_792_488_600))
    return entity
  }
  private static func load(_ context: UserContext, _ id: Int64) async throws -> ScalarTypeProbe {
    let rows = try await Q.scalarTypeProbes().withIdIs(id).limit(1).comment("Reload the exact width-control row").purpose(purpose).executeForList(context)
    guard let row = rows.first else { throw TeaQLError.execution("Missing width-control row") }; return row
  }
  // A deliberately out-of-band legacy writer, never an application Mutation
  // implementation. It changes one test-owned row without changing its version.
  private static func corruptLegacy(_ path: String, id: Int64, field: WidthField, value: TeaQLValue) throws {
    var connection: OpaquePointer?, statement: OpaquePointer?
    guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
      if let connection { sqlite3_close(connection) }; throw TeaQLError.execution("Cannot open legacy fault database")
    }
    defer { sqlite3_finalize(statement); sqlite3_close(connection) }
    // The unrelated exact-Decimal CHECK uses provider-registered functions.
    // Only this external corruption connection bypasses CHECK evaluation.
    try require(sqlite3_exec(connection, "PRAGMA ignore_check_constraints=ON", nil, nil, nil) == SQLITE_OK, "Cannot initialize legacy fault writer")
    let sql = "UPDATE scalar_type_probe_data SET \"\(field.rawValue)\"=? WHERE id=?"
    try require(sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, "Cannot prepare legacy fault")
    let bound: Int32
    switch value {
    case .int(let number): bound = sqlite3_bind_int64(statement, 1, number)
    case .double(let number): bound = sqlite3_bind_double(statement, 1, number)
    case .string(let text): bound = text.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    default: throw TeaQLError.execution("Unsupported legacy fault value")
    }
    try require(bound == SQLITE_OK && sqlite3_bind_int64(statement, 2, id) == SQLITE_OK
      && sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(connection) == 1, "Legacy fault did not affect exactly one owned row")
  }
  private static func context(_ runtime: TeaQLRuntime, _ provider: WidthProvider) -> UserContext {
    UserContext(runtime: runtime, queryExecutor: provider, mutationExecutor: provider, requestPolicy: RequestPolicy { $0 },
      querySQLLogEnabled: false, mutationSQLLogEnabled: false, businessClock: FixedBusinessClock(Date(timeIntervalSince1970: 1_792_488_600.125)))
  }
  private static func rejected(_ name: String, field: WidthField, context: UserContext, provider: WidthProvider,
    fix: WidthFix? = nil, operation: () async throws -> Void) async -> WidthCase {
    let before = await provider.snapshot(), calls = fix?.calls ?? 0
    var correct = false, unexpected: String?
    do { try await operation() }
    catch let error as CheckException {
      correct = error.violations.contains { $0.ruleID == "invalid_type" && $0.location.modelPath == field.rawValue && $0.entityType == "ScalarTypeProbe" }
      if !correct { unexpected = "wrong checker location or rule" }
    } catch { unexpected = String(describing: error) }
    let effects = await provider.snapshot(), fixed = fix.map { $0.calls - calls }
    return WidthCase(name: name, passed: correct && before == effects && (fixed == nil || fixed == 1),
      effectFree: before == effects, fixCalls: fixed, error: unexpected)
  }
  private static func invalidRead(_ name: String, field: WidthField, operation: () throws -> Void) -> WidthCase {
    var correct = false, unexpected: String?
    do { try operation() }
    catch let error as CheckException {
      correct = error.violations.contains { $0.ruleID == "invalid_type" && $0.location.modelPath == field.rawValue && $0.entityType == "ScalarTypeProbe" }
      if !correct { unexpected = "wrong read diagnostic" }
    } catch { unexpected = String(describing: error) }
    return WidthCase(name: name, passed: correct, effectFree: true, fixCalls: nil, error: unexpected)
  }
  static func main() async {
    do { try await run() } catch { print("SWIFT_INTEGER32_FAILURE=" + String(describing: error)); exit(1) }
  }
  private static func run() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["TEAQL_INTEGER32_DB"], let round = env["TEAQL_INTEGER32_ROUND"].flatMap(Int.init), (1...2).contains(round) else {
      throw TeaQLError.execution("Set TEAQL_INTEGER32_DB and explicit round 1 or 2")
    }
    let service = try SQLiteDataService(path: path), provider = WidthProvider(service)
    var runtime = TeaQLRuntime(); try runtime.install(GeneratedRuntimeModule.module)
    let schema = UserContext(runtime: runtime, queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 }, querySQLLogEnabled: false, mutationSQLLogEnabled: false)
    try await schema.ensureSchema(GeneratedRuntimeModule.module)
    let ordinary = context(runtime, provider), prefix = "integer32-round-\(round)"
    var cases: [WidthCase] = [], controls: [Int64] = [], legacy: [WidthLegacyRow] = []
    for (index, bound) in [Int64(-2_147_483_648), 2_147_483_647].enumerated() {
      var value = try await make(ordinary, tag: "\(prefix)-control-\(index)", long: index == 0 ? Int64.min : Int64.max)
      value.updateRequiredInteger(bound); value.updateOptionalInteger(nil)
      let saved = try await value.auditAs("Persist exact Integer endpoints with a genuinely wide Long").save(ordinary)
      try require(try E.scalarTypeProbe(saved).requiredInteger().eval() == bound, "Endpoint changed")
      try require(try E.scalarTypeProbe(saved).requiredLong().eval() == (index == 0 ? Int64.min : Int64.max), "Long was narrowed")
      controls.append(saved.id)
    }
    guard let generatedChecker = runtime.checker(named: "ScalarTypeProbe") else { throw TeaQLError.execution("Generated Checker missing") }
    for field in WidthField.allCases {
      for (label, number) in [("below", Int64(-2_147_483_649)), ("above", Int64(2_147_483_648))] {
        let create = try await make(ordinary, tag: "\(prefix)-invalid-create-\(field.rawValue)-\(label)")
        var pendingCreate = create; field.assign(&pendingCreate, number)
        cases.append(await rejected("create-\(field.rawValue)-\(label)", field: field, context: ordinary, provider: provider) {
          _ = try await pendingCreate.auditAs("Reject an out-of-domain Integer before SQLite").save(ordinary)
        })
        var update = try await load(ordinary, controls[0]); let version = update.version
        field.assign(&update, number)
        cases.append(await rejected("update-\(field.rawValue)-\(label)", field: field, context: ordinary, provider: provider) {
          _ = try await update.auditAs("Reject a width-invalid update without changing persisted state").save(ordinary)
        })
        let after = try await load(ordinary, controls[0])
        cases.append(WidthCase(name: "unchanged-\(field.rawValue)-\(label)", passed: after.version == version
          && after.requiredInteger == -2_147_483_648 && after.optionalInteger == nil,
          effectFree: true, fixCalls: nil, error: nil))
        for isUpdate in [false, true] {
          let fix = WidthFix(base: generatedChecker, field: field.rawValue, replacement: .int(number))
          var customRuntime = runtime; try customRuntime.install(RuntimeModule(name: "width-fix", entities: [], checkers: ["ScalarTypeProbe": fix]))
          let custom = context(customRuntime, provider)
          var value = isUpdate ? try await load(ordinary, controls[0]) : try await make(custom, tag: "\(prefix)-invalid-fix-\(field.rawValue)-\(label)")
          field.assign(&value, 7)
          let originalPending = value.teaqlEntityRoot.change(value.teaqlEntityKey)
          cases.append(await rejected("fix-\(isUpdate ? "update" : "create")-\(field.rawValue)-\(label)", field: field, context: custom, provider: provider, fix: fix) {
            _ = try await value.auditAs("Final custom Fix must obey the model width").save(custom)
          })
          cases.append(WidthCase(name: "pending-\(isUpdate)-\(field.rawValue)-\(label)",
            passed: value.teaqlEntityRoot.change(value.teaqlEntityKey) == originalPending, effectFree: true, fixCalls: nil, error: nil))
        }
        for raw: TeaQLValue in [.int(number), .double(1.5), .string("INVALID-WIDTH-TEXT")] {
          cases.append(invalidRead("record-\(field.rawValue)-\(label)-\(String(describing: raw))", field: field) {
            _ = try ScalarTypeProbe.from(record: ["id": .int(9), "version": .int(7), field.native: raw])
          })
        }
        cases.append(invalidRead("json-decode-\(field.rawValue)-\(label)", field: field) {
          _ = try JSONDecoder().decode(ScalarTypeProbe.self, from: Data("{\"id\":9,\"version\":7,\"\(field.native)\":\(number)}".utf8))
        })
        var invalid = try await load(ordinary, controls[0]); field.assign(&invalid, number)
        let beforeReads = await provider.snapshot(), originalLedger = invalid.teaqlEntityRoot.change(invalid.teaqlEntityKey)
        for terminal in ["eval", "present", "fallback", "json-encode"] {
          cases.append(invalidRead("\(terminal)-\(field.rawValue)-\(label)", field: field) {
            if terminal == "json-encode" { _ = try JSONEncoder().encode(invalid); return }
            let value = field == .required ? E.scalarTypeProbe(invalid).requiredInteger() : E.scalarTypeProbe(invalid).optionalInteger()
            if terminal == "eval" { _ = try value.eval() } else if terminal == "present" { _ = try value.isPresent() } else { _ = try value.orElse(123) }
          })
        }
        cases.append(WidthCase(name: "pure-read-\(field.rawValue)-\(label)", passed: beforeReads == (await provider.snapshot())
          && invalid.teaqlEntityRoot.change(invalid.teaqlEntityKey) == originalLedger, effectFree: beforeReads == (await provider.snapshot()), fixCalls: nil, error: nil))
      }
    }
    for field in WidthField.allCases {
      let replacement: TeaQLValue = field == .required ? .int(2_147_483_647) : .decimal(Decimal(string: "2147483647.000")!)
      let fix = WidthFix(base: generatedChecker, field: field.rawValue, replacement: replacement)
      var customRuntime = runtime; try customRuntime.install(RuntimeModule(name: "width-repair", entities: [], checkers: ["ScalarTypeProbe": fix]))
      let custom = context(customRuntime, provider)
      var value = try await load(ordinary, controls[0]); let version = value.version
      field.assign(&value, Int64.max)
      let before = await provider.snapshot()
      let saved = try await value.auditAs("Allow one custom Fix to repair a wide input before admission").save(custom)
      let after = await provider.snapshot()
      let actual = field == .required ? saved.requiredInteger : saved.optionalInteger
      cases.append(WidthCase(name: "repair-\(field.rawValue)", passed: actual == 2_147_483_647 && saved.version == version + 1
        && fix.calls == 1 && after.mutations == before.mutations + 1 && after.begins == before.begins + 1,
        effectFree: false, fixCalls: fix.calls, error: nil))
    }
    let aggregates = try await Q.scalarTypeProbes().withIdIn(controls).sumRequiredIntegerAs("_wide_sum").limit(1)
      .comment("A derived sum may exceed the Integer domain of each contribution").purpose(purpose).executeForRows(ordinary)
    cases.append(WidthCase(name: "wide-derived-sum", passed: aggregates.first?["_wide_sum"] == .int(4_294_967_294),
      effectFree: false, fixCalls: nil, error: nil))
    for field in WidthField.allCases {
      for (fault, raw): (String, TeaQLValue) in [("below", .int(-2_147_483_649)), ("above", .int(2_147_483_648)),
        ("fractional", .double(1.5)), ("text", .string("INVALID-WIDTH-TEXT"))] {
        let value = try await make(ordinary, tag: "\(prefix)-legacy-\(field.rawValue)-\(fault)")
        let saved = try await value.auditAs("Prepare a valid row before the external legacy corruption").save(ordinary)
        try corruptLegacy(path, id: saved.id, field: field, value: raw)
        legacy.append(WidthLegacyRow(id: saved.id, field: field.rawValue, fault: fault))
        var correct = false
        do { _ = try await load(ordinary, saved.id) }
        catch let error as CheckException {
          correct = error.violations.contains { $0.ruleID == "invalid_type" && $0.location.modelPath == field.rawValue && $0.entityType == "ScalarTypeProbe" }
        }
        cases.append(WidthCase(name: "legacy-query-\(field.rawValue)-\(fault)", passed: correct, effectFree: false, fixCalls: nil, error: nil))
        let projected = try await Q.scalarTypeProbesWithMinimalFields().withIdIs(saved.id).limit(1)
          .comment("Keep corrupt unselected values outside a safe identity projection").purpose(purpose).executeForList(ordinary)
        var notLoaded = false
        do {
          if field == .required { _ = try E.scalarTypeProbe(projected[0]).requiredInteger().eval() }
          else { _ = try E.scalarTypeProbe(projected[0]).optionalInteger().eval() }
        } catch is TeaQLNotLoadedError { notLoaded = true }
        cases.append(WidthCase(name: "legacy-projection-\(field.rawValue)-\(fault)",
          passed: projected.count == 1 && projected[0].id == saved.id && projected[0].version == 1 && notLoaded,
          effectFree: false, fixCalls: nil, error: nil))
      }
    }
    // ID/version-only hydration remains partial; a missing field is not invalid
    // data and cannot be converted into a loaded zero by the new read guard.
    let partial = try ScalarTypeProbe.from(record: ["id": .int(Int64.max), "version": .int(Int64.max - 1)])
    do { _ = try E.scalarTypeProbe(partial).requiredInteger().eval(); throw TeaQLError.execution("Partial Integer became loaded") }
    catch is TeaQLNotLoadedError { }
    try require(partial.id == Int64.max && partial.version == Int64.max - 1, "Identity/version was narrowed")
    let markerNames = ScalarTypeProbe.descriptor.properties.filter(\.isInt32).map { $0.modelName ?? $0.name }.sorted()
    let metadataCorrect = markerNames == ["optional_integer", "required_integer"]
    struct Result: Encodable {
      let language = "swift", round: Int, passed: Bool, metadataCorrect: Bool, markerNames: [String]
      let controls: [Int64], cases: [WidthCase], legacy: [WidthLegacyRow]
    }
    let result = Result(round: round, passed: metadataCorrect && cases.allSatisfy(\.passed), metadataCorrect: metadataCorrect,
      markerNames: markerNames, controls: controls, cases: cases, legacy: legacy)
    print("SWIFT_INTEGER32=" + String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
    if !result.passed { exit(1) }
  }
}
