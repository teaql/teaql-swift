import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite
#if os(Linux)
import Glibc
#else
import Darwin
#endif

private actor QueryObserver: QueryExecutor {
  let service: SQLiteDataService
  var calls = 0
  init(_ service: SQLiteDataService) { self.service = service }
  func execute(_ request: QueryRequest) async throws -> QueryResult { calls += 1; return try await service.execute(request) }
  func count(_ request: QueryRequest) async throws -> Int { calls += 1; return try await service.count(request) }
  func reset() { calls = 0 }
  func countCalls() -> Int { calls }
}

private struct Report: Encodable {
  let schema = "teaql.swift-generated-dynamic-decimal/v1"
  var round = 0
  var checks: [String: Bool] = [:]
  var rejections = 0
  var rows: [String: Int64] = [:]
  var error: String?
  var passed = false
  let fullScalarContractAccepted = false
}

@main private enum DynamicDecimalVerification {
  static func main() async {
    var report = Report()
    report.round = Int(ProcessInfo.processInfo.environment["TEAQL_DYNAMIC_DECIMAL_ROUND"] ?? "") ?? 0
    guard [1, 2].contains(report.round), let database = ProcessInfo.processInfo.environment["TEAQL_DYNAMIC_DECIMAL_DB"] else { exit(2) }
    do { try await run(database, &report) } catch { report.error = String(describing: error) }
    report.passed = report.error == nil && report.rejections == 96 && !report.checks.isEmpty && report.checks.values.allSatisfy { $0 }
    do {
      let bytes = try JSONEncoder().encode(report)
      try bytes.write(to: URL(fileURLWithPath: database + ".round-\(report.round).json"))
      print("SWIFT_DYNAMIC_DECIMAL=" + String(decoding: bytes, as: UTF8.self))
    } catch { print("Report encoding failed"); exit(2) }
    if !report.passed { exit(1) }
  }

  private static func run(_ database: String, _ report: inout Report) async throws {
    let service = try SQLiteDataService(path: database)
    var runtime = TeaQLRuntime(); try runtime.install(GeneratedRuntimeModule.module)
    let setup = UserContext(runtime: runtime, queryExecutor: service, mutationExecutor: service,
      requestPolicy: RequestPolicy { $0 }, querySQLLogEnabled: false, mutationSQLLogEnabled: false)
    try await setup.ensureSchema(GeneratedRuntimeModule.module)
    try await setup.ensureSchema(GeneratedRuntimeModule.module)
    let observer = QueryObserver(service)
    let context = UserContext(runtime: runtime, queryExecutor: observer, mutationExecutor: service,
      requestPolicy: RequestPolicy { $0 }, querySQLLogEnabled: false, mutationSQLLogEnabled: false)
    let overprecision = "12345678901234567890123456789012345678901234567890123456789"
    let rounded = "12345678901234567890123456789012345678900000000000000000000"
    let vectors = [("small", "0.1"), ("wide", "12345678901234567890123456789012345678"),
      ("power", "1" + String(repeating: "0", count: 80)), ("rounded", rounded)]
    for (name, text) in vectors {
      let marker = "dynamic-decimal-" + name
      let expected = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
      var rows = try await Q.scalarTypeProbes().withRequiredStringIs(marker).limit(1)
        .comment("Find the retained exact monetary fixture").purpose("Repeat generated queries without resetting the database").executeForList(context)
      if rows.isEmpty {
        var row = try Q.scalarTypeProbes().comment("Prepare one exact Decimal counterexample").purpose("Verify generated monetary query admission").newEntity(context)
        row.updateTypePlatform(1); row.updateRequiredString(marker); row.updateRequiredBoolean(true)
        row.updateRequiredInteger(7); row.updateRequiredLong(1_234_567); row.updateRequiredDecimal(expected)
        row.updateRequiredFloat(1.25); row.updateRequiredDouble(2.5)
        row.updateRequiredDate(Date(timeIntervalSince1970: 1_792_454_400)); row.updateRequiredTime("09:30:15")
        row.updateRequiredDatetime(Date(timeIntervalSince1970: 1_792_488_600))
        let saved = try await row.auditAs("Seed exact monetary fixtures through generated Mutation APIs").save(context)
        rows = try await Q.scalarTypeProbes().withIdIs(saved.id).limit(1)
          .comment("Reload the audited Decimal seed").purpose("Check real SQLite hydration rather than a local setter").executeForList(context)
      }
      guard let row = rows.first else { throw TeaQLError.execution("Missing Decimal fixture") }
      report.rows[name] = row.id
      report.checks[name + ".stored"] = try E.scalarTypeProbe(row).requiredDecimal().eval() == expected && row.version == 1
      for field in ["required_decimal", "requiredDecimal"] {
        for (index, literal) in [text, "\"" + text + "\""].enumerated() {
          let original = Q.scalarTypeProbes().withIdIs(row.id).limit(1)
            .comment("Match the exact stored monetary value").purpose("Align native Q and dynamic Decimal predicates")
          let snapshot = original.toQuery()
          let result = try await original.filterByJson("{\"filter\":{\"\(field)\":\(literal)}}").executeForList(context)
          report.checks[name + "." + field + ".\(index)"] = result.count == 1 && result.first?.id == row.id
            && original.toQuery() == snapshot
        }
      }
    }
    for (index, text) in [overprecision, "-" + overprecision, "0." + overprecision].enumerated() {
      for (representation, literal) in [text, "\"" + text + "\""].enumerated() {
        for field in ["required_decimal", "requiredDecimal"] {
          for operation in ["$eq", "$ne", "$gt", "$gte", "$lt", "$lte", "$in", "$notIn"] {
            let operand = ["$in", "$notIn"].contains(operation) ? "[0.1,\(literal)]" : literal
            var warnings: [DynamicSearchWarning] = [], rejected = false
            await observer.reset()
            do {
              _ = try await Q.scalarTypeProbes().withIdIs(report.rows["rounded"]!).limit(1)
                .comment("Reject an unrepresentable monetary filter").purpose("Never match the rounded counterexample row")
                .filterByJson("{\"filter\":{\"\(field)\":{\"\(operation)\":\(operand)},\"removed\":\"SECRET-CANARY\"}}", warn: { warnings.append($0) })
                .executeForList(context)
            } catch is DynamicSearchError { rejected = true }
            let calls = await observer.countCalls()
            report.checks["reject.\(index).\(representation).\(field).\(operation)"] = rejected && calls == 0 && warnings.isEmpty
            if rejected { report.rejections += 1 }
          }
        }
      }
    }
  }
}
