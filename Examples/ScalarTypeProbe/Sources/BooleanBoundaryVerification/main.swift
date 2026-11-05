import CSQLite
import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

private struct BooleanReport: Encodable {
  var passed = false, round = 0
  var checks: [String: Bool] = [:]
  var rows: [String: Int64] = [:]
  var error: String?
}

@main enum BooleanBoundaryVerification {
  static func main() async {
    var report = BooleanReport()
    let env = ProcessInfo.processInfo.environment
    report.round = Int(env["TEAQL_BOOLEAN_ROUND"] ?? "") ?? 0
    guard [1, 2].contains(report.round), let path = env["TEAQL_BOOLEAN_DB"] else { exit(2) }
    do { try await run(path, &report) } catch { report.error = String(describing: error) }
    report.passed = report.error == nil && !report.checks.isEmpty && report.checks.values.allSatisfy { $0 }
    do { print("SWIFT_BOOLEAN_BOUNDARY=" + String(decoding: try JSONEncoder().encode(report), as: UTF8.self)) }
    catch { exit(2) }
    if !report.passed { exit(1) }
  }

  private static func newProbe(_ context: UserContext, tag: String, flag: Bool, optional: Bool?) throws -> ScalarTypeProbe {
    var row = try Q.scalarTypeProbes().comment("Prepare a typed Boolean fixture")
      .purpose("Verify Boolean Q and E without truthiness conversions").newEntity(context)
    row.updateTypePlatform(1); row.updateRequiredString(tag); row.updateRequiredBoolean(flag)
    row.updateOptionalBoolean(optional); row.updateRequiredInteger(7); row.updateRequiredLong(1_234_567)
    row.updateRequiredDecimal(1); row.updateRequiredFloat(1.25); row.updateRequiredDouble(2.5)
    row.updateRequiredDate(Date(timeIntervalSince1970: 1_792_454_400)); row.updateRequiredTime("09:30:15")
    row.updateRequiredDatetime(Date(timeIntervalSince1970: 1_792_488_600))
    return row
  }

  private static func run(_ path: String, _ report: inout BooleanReport) async throws {
    let service = try SQLiteDataService(path: path)
    var runtime = TeaQLRuntime(); try runtime.install(GeneratedRuntimeModule.module)
    let context = UserContext(runtime: runtime, queryExecutor: service, mutationExecutor: service,
      requestPolicy: RequestPolicy { $0 }, querySQLLogEnabled: false, mutationSQLLogEnabled: false)
    try await context.ensureSchema(GeneratedRuntimeModule.module)
    try await context.ensureSchema(GeneratedRuntimeModule.module)
    let purpose = "Verify native generated Boolean semantics with retained SQLite data"
    for (name, flag, optional): (String, Bool, Bool?) in [("false", false, false), ("true", true, true), ("unknown", true, nil)] {
      let tag = "boolean-valid-" + name
      var rows = try await Q.scalarTypeProbes().withRequiredStringIs(tag).limit(1)
        .comment("Find a retained Boolean seed").purpose(purpose).executeForList(context)
      if rows.isEmpty {
        let row = try newProbe(context, tag: tag, flag: flag, optional: optional)
        _ = try await row.auditAs("Seed a Boolean fixture through generated audited Mutation APIs").save(context)
        rows = try await Q.scalarTypeProbes().withRequiredStringIs(tag).limit(1)
          .comment("Reload the persisted Boolean seed").purpose(purpose).executeForList(context)
      }
      guard let row = rows.first else { throw TeaQLError.execution("Missing Boolean fixture") }
      report.rows[name] = row.id
      report.checks[name + ".e"] = try E.scalarTypeProbe(row).requiredBoolean().eval() == flag
        && E.scalarTypeProbe(row).optionalBoolean().eval() == optional
      let base = Q.scalarTypeProbes().withIdIs(row.id).limit(1).comment("Filter the persisted Boolean value").purpose(purpose)
      let matching = try await (flag ? base.whichAreRequiredBoolean() : base.whichAreNotRequiredBoolean()).executeForList(context)
      report.checks[name + ".q"] = matching.count == 1
      let nullable = try await (optional == nil ? base.withOptionalBooleanIsUnknown() : base.withOptionalBooleanIsKnown()).executeForList(context)
      report.checks[name + ".nullable"] = nullable.count == 1
      for alias in ["required_boolean", "requiredBoolean", "required_datetime"] {
        let counts = try await base.countAs(alias).executeForRows(context)
        report.checks[name + ".count." + alias] = counts.first?[alias] == .int(1)
      }
    }
    var legacy = try await Q.scalarTypeProbesWithMinimalFields().withRequiredStringIs("boolean-legacy").limit(1)
      .comment("Find a legacy row without selecting its damaged field").purpose(purpose).executeForList(context)
    if legacy.isEmpty {
      let row = try newProbe(context, tag: "boolean-legacy", flag: true, optional: nil)
      let saved = try await row.auditAs("Seed a valid row before deliberately corrupting its storage").save(context)
      legacy = try await Q.scalarTypeProbesWithMinimalFields().withIdIs(saved.id).limit(1)
        .comment("Read only the identity of the corruption fixture").purpose(purpose).executeForList(context)
    }
    guard let row = legacy.first else { throw TeaQLError.execution("Missing legacy Boolean fixture") }
    report.rows["legacy"] = row.id
    // Explicit negative-test injection only. All ordinary seed writes above use
    // generated audited APIs; applications must never store Boolean INTEGER 2.
    var handle: OpaquePointer?, statement: OpaquePointer?
    guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else { throw TeaQLError.execution("Cannot open the owned corruption fixture") }
    defer { sqlite3_close(handle) }
    guard sqlite3_prepare_v2(handle, "UPDATE scalar_type_probe_data SET required_boolean=2 WHERE id=?", -1, &statement, nil) == SQLITE_OK,
      let statement else { throw TeaQLError.execution("Cannot prepare the explicit corruption fixture") }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_bind_int64(statement, 1, row.id) == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
      throw TeaQLError.execution("Cannot inject the Boolean corruption fixture")
    }
    do {
      _ = try await Q.scalarTypeProbesWithMinimalFields().withIdIs(row.id).selectRequiredBoolean().limit(1)
        .comment("Reject an invalid stored Boolean rather than pretending it is true").purpose(purpose).executeForList(context)
      report.checks["legacy.rejected"] = false
    } catch let error as CheckException {
      report.checks["legacy.rejected"] = error.violations.contains { $0.ruleID == "invalid_type" && $0.location.modelPath == "required_boolean" }
      report.checks["legacy.path"] = error.violations.first?.wire().instancePath == "/requiredBoolean"
    }
    let minimal = try await Q.scalarTypeProbesWithMinimalFields().withIdIs(row.id).limit(1)
      .comment("Keep unselected fields absent without eagerly reading damaged data").purpose(purpose).executeForList(context)
    report.checks["legacy.projection"] = minimal.first?.id == row.id && minimal.first?.isLoaded("requiredBoolean") == false
    do {
      _ = try E.scalarTypeProbe(minimal.first!).requiredBoolean().eval()
      report.checks["legacy.notLoaded"] = false
    } catch is TeaQLNotLoadedError { report.checks["legacy.notLoaded"] = true }
  }
}
