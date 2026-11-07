import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite
import TeaQLTestSupport
#if os(Linux)
import Glibc
#else
import Darwin
#endif

private struct Counts: Codable, Sendable {
  var query = 0, mutate = 0, begin = 0, commit = 0, rollback = 0
  var noEntry: Bool { query == 0 && mutate == 0 && begin == 0 }
}
private struct Rejection: Codable {
  let operation: String, field: String, index: Int, rejected: Bool, errorType: String
  let counts: Counts
}
private struct Report: Encodable {
  var round = 0
  var finalID = ""
  var finalVersion: Int64 = 0
  var phase = ""
  let schema = "teaql.swift-generated-scalar-roundtrip/v1"
  let nativeScalarFields = 21
  let timeProfile = "string"
  let jsonProfile = "native Codable, not the external logical-wire contract"
  let allP0P1Complete = false
  var checks: [String: Bool] = [:]
  var errors: [String: String] = [:]
  var observations: [String: String] = [:]
  var rejections: [Rejection] = []
  var calibration = Counts()
  var saveClockReads = 0
  var passed = false
}
private func check<T: Equatable>(_ name: String, _ expected: T, _ report: inout Report,
  read: () throws -> T) {
  do { let actual = try read(); report.checks[report.phase + name] = actual == expected
    if actual != expected { report.observations[name] = "expected=\(expected) actual=\(actual)" }
  } catch { report.checks[report.phase + name] = false; report.errors[report.phase + name] = String(describing: type(of: error)) }
}
private final class Clock: @unchecked Sendable, BusinessClock {
  private let lock = NSLock()
  private var reads = 0
  let value = Date(timeIntervalSince1970: 1_792_488_600.125)
  func now() -> Date { lock.withLock { reads += 1; return value } }
  func reset() { lock.withLock { reads = 0 } }
  var count: Int { lock.withLock { reads } }
}
private actor ObservedProvider: QueryExecutor, GraphTransactionExecutor, InternalIDGenerator {
  // Reservation is infrastructure I/O, not a business query/mutation/audit.
  func nextID(for entity: String, context: UserContext) async throws -> Int64 {
    try await service.nextID(for: entity, context: context)
  }
  let service: SQLiteDataService
  private var calls = Counts()
  init(_ service: SQLiteDataService) { self.service = service }
  func reset() { calls = Counts() }
  func snapshot() -> Counts { calls }
  func execute(_ request: QueryRequest) async throws -> QueryResult { calls.query += 1; return try await service.execute(request) }
  func count(_ request: QueryRequest) async throws -> Int { calls.query += 1; return try await service.count(request) }
  func execute(_ request: MutationRequest) async throws -> MutationResult { calls.mutate += 1; return try await service.execute(request) }
  func beginGraphTransaction() async throws { calls.begin += 1; try await service.beginGraphTransaction() }
  func commitGraphTransaction() async throws { calls.commit += 1; try await service.commitGraphTransaction() }
  func rollbackGraphTransaction() async throws { calls.rollback += 1; try await service.rollbackGraphTransaction() }
}

private let exact = Decimal(string: "123456789012.3456789", locale: Locale(identifier: "en_US_POSIX"))!
private let largeLong: Int64 = 9_007_199_254_740_993
private let leapDay = ISO8601DateFormatter().date(from: "2024-02-29T00:00:00Z")!
private let ordinaryDay = ISO8601DateFormatter().date(from: "2026-10-23T00:00:00Z")!
private let offsetInstant = ISO8601DateFormatter().date(from: "2032-02-29T23:30:00+02:00")!
private let largeText = "Unicode 精确数值\nleft\0right " + String(repeating: "bounded large text 中文 ", count: 1_024)

private func newProbe(_ context: UserContext, name: String) async throws -> ScalarTypeProbe {
  var row = try await Q.scalarTypeProbes().comment("prepare one bounded scalar fixture")
    .purpose("verify generated strong scalar APIs").newEntity(context)
  row.updateTypePlatform(1)
  row.updateRequiredString(name)
  row.updateLargeText(largeText)
  row.updateRequiredBoolean(false)
  row.updateRequiredInteger(2_147_483_647)
  row.updateRequiredLong(largeLong)
  row.updateRequiredDecimal(exact)
  row.updateRequiredFloat(1.25)
  row.updateRequiredDouble(-2.5)
  row.updateRequiredDate(leapDay)
  row.updateRequiredTime("00:00:00.125")
  row.updateRequiredDatetime(Date(timeIntervalSince1970: 1_792_488_600.125))
  return row
}
private func reload(_ context: UserContext, id: Int64) async throws -> ScalarTypeProbe {
  let rows = try await Q.scalarTypeProbes().withIdIs(id).limit(1)
    .comment("reload all fields of the saved scalar")
    .purpose("compare generated Q hydration and E values").executeForList(context)
  guard let row = rows.first else { throw TeaQLError.execution("Saved scalar missing") }
  return row
}
private func checkFields(_ row: ScalarTypeProbe, _ name: String, _ clock: Clock, _ report: inout Report,
  populated: Bool = false, requiredBoolean: Bool = false, requiredInteger: Int64 = 2_147_483_647, requiredDecimal: Decimal = exact) {
  let e = E.scalarTypeProbe(row)
  check("required_string", Optional(name), &report) { try e.requiredString().eval() }
  check("optional_string", populated ? "" : nil, &report) { try e.optionalString().eval() }
  check("large_text", Optional(largeText), &report) { try e.largeText().eval() }
  check("required_boolean", Optional(requiredBoolean), &report) { try e.requiredBoolean().eval() }
  check("optional_boolean", populated ? true : nil, &report) { try e.optionalBoolean().eval() }
  check("required_integer", Optional(requiredInteger), &report) { try e.requiredInteger().eval() }
  check("optional_integer", populated ? Int64(Int32.min) : nil, &report) { try e.optionalInteger().eval() }
  check("required_long", Optional(largeLong), &report) { try e.requiredLong().eval() }
  check("optional_long", populated ? Int64.min : nil, &report) { try e.optionalLong().eval() }
  check("required_decimal", Optional(requiredDecimal), &report) { try e.requiredDecimal().eval() }
  check("optional_decimal", populated ? Decimal(string: "-3.50")! : nil, &report) { try e.optionalDecimal().eval() }
  check("required_float", Optional(1.25), &report) { try e.requiredFloat().eval() }
  check("optional_float", populated ? -3.5 : nil, &report) { try e.optionalFloat().eval() }
  check("required_double", Optional(-2.5), &report) { try e.requiredDouble().eval() }
  check("optional_double", populated ? 0.125 : nil, &report) { try e.optionalDouble().eval() }
  check("required_date", Optional(leapDay), &report) { try e.requiredDate().eval() }
  check("optional_date", populated ? ordinaryDay : nil, &report) { try e.optionalDate().eval() }
  check("required_time", Optional("00:00:00.125"), &report) { try e.requiredTime().eval() }
  check("optional_time", populated ? "23:59:59.999" : nil, &report) { try e.optionalTime().eval() }
  check("required_datetime", Optional(clock.value), &report) { try e.requiredDatetime().eval() }
  check("optional_datetime", populated ? offsetInstant : nil, &report) { try e.optionalDatetime().eval() }
  check("foreign_key", Optional(Int64(1)), &report) { try e.typePlatformId().eval() }
  check("create_time", Optional(clock.value), &report) { try e.createTime().eval() }
  check("update_time", Optional(clock.value), &report) { try e.updateTime().eval() }
  for field in ["optionalString", "optionalBoolean", "optionalInteger", "optionalLong", "optionalDecimal", "optionalFloat", "optionalDouble", "optionalDate", "optionalTime", "optionalDatetime"] {
    report.checks[report.phase + "loaded." + field] = row.isLoaded(field)
  }
}
private func invalid(_ row: inout ScalarTypeProbe, field: String, value: Double) {
  switch field {
  case "required_float": row.updateRequiredFloat(value)
  case "optional_float": row.updateOptionalFloat(value)
  case "required_double": row.updateRequiredDouble(value)
  case "optional_double": row.updateOptionalDouble(value)
  default: preconditionFailure("Unknown test field")
  }
}

private func datePredicates(_ context: UserContext, id: Int64, day: Date,
  optional: Bool, report: inout Report) async throws {
  let earlier = day.addingTimeInterval(-86_400), later = day.addingTimeInterval(86_400)
  let midday = day.addingTimeInterval(43_200)
  let cases: [(String, ScalarTypeProbeRequest, Int)] = optional ? [
    ("equal", Q.scalarTypeProbes().withOptionalDateIs(day), 1),
    ("not_equal", Q.scalarTypeProbes().withOptionalDateIsNot(earlier), 1),
    ("greater", Q.scalarTypeProbes().withOptionalDateGreaterThan(earlier), 1),
    ("greater_equal", Q.scalarTypeProbes().withOptionalDateGreaterThanOrEqualTo(day), 1),
    ("less", Q.scalarTypeProbes().withOptionalDateLessThan(later), 1),
    ("less_equal", Q.scalarTypeProbes().withOptionalDateLessThanOrEqualTo(day), 1),
    ("between", Q.scalarTypeProbes().withOptionalDateBetween(earlier, day), 1),
    ("in", Q.scalarTypeProbes().withOptionalDateIn([earlier, day]), 1),
    ("not_in", Q.scalarTypeProbes().withOptionalDateNotIn([earlier, later]), 1),
    ("same_utc_day", Q.scalarTypeProbes().withOptionalDateIs(midday), 1),
    ("wrong_day", Q.scalarTypeProbes().withOptionalDateIs(later), 0),
    ("strict_greater", Q.scalarTypeProbes().withOptionalDateGreaterThan(day), 0),
    ("strict_less", Q.scalarTypeProbes().withOptionalDateLessThan(day), 0),
    ("not_equal_self", Q.scalarTypeProbes().withOptionalDateIsNot(midday), 0),
    ("excluded_in", Q.scalarTypeProbes().withOptionalDateNotIn([day]), 0),
    ("empty_in", Q.scalarTypeProbes().withOptionalDateIn([]), 0),
    ("empty_not_in", Q.scalarTypeProbes().withOptionalDateNotIn([]), 1),
    ("known", Q.scalarTypeProbes().withOptionalDateIsKnown(), 1),
    ("unknown", Q.scalarTypeProbes().withOptionalDateIsUnknown(), 0),
  ] : [
    ("equal", Q.scalarTypeProbes().withRequiredDateIs(day), 1),
    ("not_equal", Q.scalarTypeProbes().withRequiredDateIsNot(earlier), 1),
    ("greater", Q.scalarTypeProbes().withRequiredDateGreaterThan(earlier), 1),
    ("greater_equal", Q.scalarTypeProbes().withRequiredDateGreaterThanOrEqualTo(day), 1),
    ("less", Q.scalarTypeProbes().withRequiredDateLessThan(later), 1),
    ("less_equal", Q.scalarTypeProbes().withRequiredDateLessThanOrEqualTo(day), 1),
    ("between", Q.scalarTypeProbes().withRequiredDateBetween(earlier, day), 1),
    ("in", Q.scalarTypeProbes().withRequiredDateIn([earlier, day]), 1),
    ("not_in", Q.scalarTypeProbes().withRequiredDateNotIn([earlier, later]), 1),
    ("same_utc_day", Q.scalarTypeProbes().withRequiredDateIs(midday), 1),
    ("wrong_day", Q.scalarTypeProbes().withRequiredDateIs(later), 0),
    ("strict_greater", Q.scalarTypeProbes().withRequiredDateGreaterThan(day), 0),
    ("strict_less", Q.scalarTypeProbes().withRequiredDateLessThan(day), 0),
    ("not_equal_self", Q.scalarTypeProbes().withRequiredDateIsNot(midday), 0),
    ("excluded_in", Q.scalarTypeProbes().withRequiredDateNotIn([day]), 0),
    ("empty_in", Q.scalarTypeProbes().withRequiredDateIn([]), 0),
    ("empty_not_in", Q.scalarTypeProbes().withRequiredDateNotIn([]), 1),
  ]
  let prefix = optional ? "optional_date." : "required_date."
  for (name, request, count) in cases {
    let query = request.withIdIs(id).limit(2).comment("Verify calendar date " + prefix + name)
      .purpose("Compare generated calendar predicates with persisted date-only storage")
    let original = query.toQuery()
    let rows = try await query.executeForList(context)
    report.checks[prefix + name] = rows.count == count && (count == 0 || rows.first?.id == id)
    report.checks[prefix + name + ".immutable"] = query.toQuery() == original
  }
  let counted = optional ? Q.scalarTypeProbes().withOptionalDateIs(day) : Q.scalarTypeProbes().withRequiredDateIs(day)
  let counts = try await counted.withIdIs(id).countAs("dateMatches").limit(1)
    .comment("Count exactly one matching calendar date").purpose("Keep generated aggregate and list predicates aligned").executeForRows(context)
  report.checks[prefix + "count"] = counts.count == 1 && counts.first?["dateMatches"]?.int64Value == 1
}

private func dynamicDatePredicates(_ context: UserContext, id: Int64, day: Date,
  optional: Bool, report: inout Report) async throws {
  func text(_ value: Date) -> String { String(ISO8601DateFormatter().string(from: value).prefix(10)) }
  let current = text(day), before = text(day.addingTimeInterval(-86_400)), after = text(day.addingTimeInterval(86_400))
  let fields = optional ? ["optional_date", "optionalDate"] : ["required_date", "requiredDate"]
  let predicates: [(String, String, Int)] = [
    ("equal", "{\"$eq\":\"\(current)\"}", 1), ("not_equal", "{\"$ne\":\"\(before)\"}", 1),
    ("greater", "{\"$gt\":\"\(before)\"}", 1), ("greater_equal", "{\"$gte\":\"\(current)\"}", 1),
    ("less", "{\"$lt\":\"\(after)\"}", 1), ("less_equal", "{\"$lte\":\"\(current)\"}", 1),
    ("in", "{\"$in\":[\"\(before)\",\"\(current)\"]}", 1), ("not_in", "{\"$notIn\":[\"\(before)\",\"\(after)\"]}", 1),
    ("wrong_day", "{\"$eq\":\"\(after)\"}", 0), ("not_equal_self", "{\"$ne\":\"\(current)\"}", 0),
    ("strict_greater", "{\"$gt\":\"\(current)\"}", 0), ("strict_less", "{\"$lt\":\"\(current)\"}", 0),
    ("missing_in", "{\"$in\":[\"\(before)\",\"\(after)\"]}", 0), ("excluded_in", "{\"$notIn\":[\"\(current)\"]}", 0),
    ("empty_in", "{\"$in\":[]}", 0), ("empty_not_in", "{\"$notIn\":[]}", 1),
    ("not_null", "{\"$ne\":null}", 1), ("is_null", "null", 0),
  ]
  for field in fields {
    for (label, predicate, expected) in predicates {
      let original = Q.scalarTypeProbes().withIdIs(id).limit(2)
        .comment("Load one bounded scalar through generated dynamic Date search")
        .purpose("Keep typed and JSON predicates aligned without weakening trusted scope")
      let snapshot = original.toQuery()
      let merged = try original.filterByJson("{\"filter\":{\"\(field)\":\(predicate)}}")
      let rows = try await merged.executeForList(context)
      let prefix = "dynamic_date." + field + "." + label
      report.checks[prefix] = rows.count == expected && (expected == 0 || rows.first?.id == id)
      report.checks[prefix + ".immutable"] = original.toQuery() == snapshot
    }
    let outsideScope = try await Q.scalarTypeProbes().withIdIs(id + 10_000).limit(1)
      .filterByJson("{\"filter\":{\"\(field)\":\"\(current)\"}}")
      .comment("Keep an impossible trusted identity predicate")
      .purpose("Prove dynamic filters cannot broaden the original request").executeForList(context)
    report.checks["dynamic_date." + field + ".scope"] = outsideScope.isEmpty
    var warnings: [DynamicSearchWarning] = []
    let tolerated = try await Q.scalarTypeProbes().withIdIs(id).limit(2)
      .filterByJson("{\"filter\":{\"\(field)\":\"\(current)\",\"removed_field\":\"SECRET-CANARY\"}}", warn: { warnings.append($0) })
      .comment("Ignore only the removed field, not its valid Date sibling")
      .purpose("Keep schema drift tolerant and Date filtering authoritative").executeForList(context)
    report.checks["dynamic_date." + field + ".unknown_sibling"] = tolerated.count == 1 && warnings.count == 1
      && warnings[0].code == "DYNAMIC_SEARCH_UNKNOWN_FIELD" && warnings[0].fieldPath == "removed_field"
    for (index, literal) in ["\"2026-02-30\"", "\"2024-2-29\"", "\"2024-02-29T00:00:00Z\"", "{\"$gt\":null}"].enumerated() {
      var rejected = false, lateWarnings: [DynamicSearchWarning] = []
      do { _ = try Q.scalarTypeProbes().filterByJson("{\"filter\":{\"\(field)\":\(literal),\"removed_field\":\"SECRET-CANARY\"}}", warn: { lateWarnings.append($0) }) }
      catch is DynamicSearchError { rejected = true }
      report.checks["dynamic_date." + field + ".invalid.\(index)"] = rejected && lateWarnings.isEmpty
    }
  }
}

@main private enum ScalarRoundtripVerification {
  static func main() async {
    let database = ProcessInfo.processInfo.environment["TEAQL_SWIFT_ROUNDTRIP_DB"]!
    var report = Report()
    report.round = Int(ProcessInfo.processInfo.environment["TEAQL_SWIFT_ROUNDTRIP_ROUND"] ?? "") ?? 0
    guard [1, 2].contains(report.round) else { print("Set explicit round 1 or 2"); exit(2) }
    do { try await run(database, &report) }
    catch { report.errors["unexpected"] = String(describing: error) }
    report.passed = report.errors.isEmpty && !report.checks.isEmpty && report.checks.values.allSatisfy { $0 }
      && report.rejections.count == 24 && report.rejections.allSatisfy { $0.rejected && $0.counts.noEntry }
    do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(report)
      try data.write(to: URL(fileURLWithPath: database + ".round-\(report.round).json"))
      let compact = try JSONEncoder().encode(report)
      print("SWIFT_SCALAR_ROUNDTRIP=" + String(decoding: compact, as: UTF8.self))
    } catch { print("FAIL report encoding: \(error)"); exit(2) }
    print("CORE_SWIFT_SCALARS fields=21 checks=\(report.checks.count) rejections=\(report.rejections.count) passed=\(report.passed)")
    if !report.passed { print("FAILED_CHECKS \(report.checks.filter { !$0.value }.keys.sorted()) errors=\(report.errors)"); exit(1) }
  }
  static func run(_ database: String, _ report: inout Report) async throws {
    let service = try SQLiteDataService(path: database), audit = RecordingAuditSink(), clock = Clock()
    var runtime = TeaQLRuntime(); try runtime.install(GeneratedRuntimeModule.module)
    let setupContext = UserContext(runtime: runtime, queryExecutor: service, mutationExecutor: service,
      requestPolicy: RequestPolicy { $0 }, auditSink: audit, querySQLLogEnabled: false, mutationSQLLogEnabled: false, businessClock: clock)
    try await setupContext.ensureSchema(GeneratedRuntimeModule.module)
    try await setupContext.ensureSchema(GeneratedRuntimeModule.module)
    let provider = ObservedProvider(service)
    let context = UserContext(runtime: runtime, queryExecutor: provider, mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 }, auditSink: audit, querySQLLogEnabled: false, mutationSQLLogEnabled: false, businessClock: clock)
    let name = "native-scalars-\(report.round)-\(UUID().uuidString)"
    let created = try await newProbe(context, name: name)
    clock.reset(); await provider.reset()
    let persisted = try await created.auditAs("persist the native scalar boundary fixture").save(context)
    report.saveClockReads = clock.count
    report.checks["one_save_clock"] = clock.count == 1
    let high = try await reload(context, id: persisted.id)
    report.phase = "seed."; checkFields(high, name, clock, &report); report.phase = ""
    report.calibration = await provider.snapshot()
    report.checks["calibrated_observer"] = report.calibration.query > 0 && report.calibration.mutate > 0 && report.calibration.begin > 0
    let queries: [(String, ScalarTypeProbeRequest)] = [
      ("string", Q.scalarTypeProbes().withRequiredStringIs(name)), ("text", Q.scalarTypeProbes().withLargeTextContaining("Unicode")),
      ("boolean", Q.scalarTypeProbes().whichAreNotRequiredBoolean()),
      ("integer", Q.scalarTypeProbes().withRequiredIntegerBetween(Int64(Int32.min), Int64(Int32.max))),
      ("long", Q.scalarTypeProbes().withRequiredLongIs(largeLong)), ("decimal", Q.scalarTypeProbes().withRequiredDecimalIs(exact)),
      ("float", Q.scalarTypeProbes().withRequiredFloatBetween(1, 2)), ("double", Q.scalarTypeProbes().withRequiredDoubleBetween(-3, -2)),
      ("date", Q.scalarTypeProbes().withRequiredDateIs(leapDay)), ("time", Q.scalarTypeProbes().withRequiredTimeIs("00:00:00.125")),
      ("datetime", Q.scalarTypeProbes().withRequiredDatetimeIs(clock.value)), ("null", Q.scalarTypeProbes().withOptionalStringIsUnknown()),
    ]
    for (key, query) in queries {
      let found = try await query.withIdIs(high.id).limit(2).comment("Verify typed scalar predicate " + key)
        .purpose("Match exactly one known persisted scalar").executeForList(context)
      report.checks["query." + key] = found.count == 1 && found.first?.id == high.id
    }
    try await datePredicates(context, id: high.id, day: leapDay, optional: false, report: &report)
    try await dynamicDatePredicates(context, id: high.id, day: leapDay, optional: false, report: &report)
    let nullDates = try await Q.scalarTypeProbes().withIdIs(high.id).withOptionalDateIn([leapDay]).limit(1)
      .comment("Do not equate a loaded null date with a calendar day").purpose("Preserve SQL null date semantics").executeForList(context)
    report.checks["optional_date.null_not_in_day"] = nullDates.isEmpty
    let nextUTC = ISO8601DateFormatter().date(from: "2024-02-29T23:30:00-02:00")!
    let nextUTCResult = try await Q.scalarTypeProbes().withIdIs(high.id).withRequiredDateIs(nextUTC).limit(1)
      .comment("Normalize a Date carrier to its UTC calendar day").purpose("Do not confuse offset text with the saved UTC day").executeForList(context)
    report.checks["required_date.offset_utc_boundary"] = nextUTCResult.isEmpty
    let instantCases: [(String, ScalarTypeProbeRequest, Int)] = [
      ("same", Q.scalarTypeProbes().withRequiredDatetimeIs(clock.value), 1),
      ("different_millisecond", Q.scalarTypeProbes().withRequiredDatetimeIs(clock.value.addingTimeInterval(1)), 0),
      ("in", Q.scalarTypeProbes().withRequiredDatetimeIn([clock.value]), 1),
      ("between", Q.scalarTypeProbes().withRequiredDatetimeBetween(clock.value, clock.value), 1),
    ]
    for (name, query, count) in instantCases {
      let rows = try await query.withIdIs(high.id).limit(2).comment("Verify instant predicate " + name)
        .purpose("Keep timestamp milliseconds distinct from calendar days").executeForList(context)
      report.checks["datetime_control." + name] = rows.count == count
    }
    for field in ["required_datetime", "requiredDatetime"] {
      for (value, expected) in [(Int64(1_792_488_600_125), 1), (Int64(1_792_488_600_126), 0)] {
        let rows = try await Q.scalarTypeProbes().withIdIs(high.id).limit(1)
          .filterByJson("{\"filter\":{\"\(field)\":\(value)}}")
          .comment("Keep dynamic instant equality at millisecond precision")
          .purpose("Do not reinterpret a DateTime as a calendar day").executeForList(context)
        report.checks["dynamic_datetime." + field + ".\(value)"] = rows.count == expected
      }
    }

    // TeaQLEntity is Codable. Use the native standard-library codec, not a
    // handwritten DTO or reflection over generated implementation fields.
    do {
      let bytes = try JSONEncoder().encode(high)
      try bytes.write(to: URL(fileURLWithPath: database + ".entity.json"))
      var decoded = try JSONDecoder().decode(ScalarTypeProbe.self, from: bytes)
      report.phase = "seed_json."; checkFields(decoded, name, clock, &report); report.phase = ""
      check("json_exact_long", Optional(largeLong), &report) { try E.scalarTypeProbe(decoded).requiredLong().eval() }
      check("json_exact_decimal", Optional(exact), &report) { try E.scalarTypeProbe(decoded).requiredDecimal().eval() }
      check("json_loaded_null", nil as String?, &report) { try E.scalarTypeProbe(decoded).optionalString().eval() }
      let keys = (try JSONSerialization.jsonObject(with: bytes) as! [String: Any]).keys
      report.checks["json_no_ledger"] = !keys.contains("teaqlEntityRoot") && !keys.contains("teaqlEntityKey")
      decoded.updateRequiredBoolean(true)
      decoded.updateRequiredDecimal(Decimal(string: "0.1")!)
      let jsonSaved = try await decoded.auditAs("save the fully loaded native JSON roundtrip").save(context)
      let jsonReloaded = try await reload(context, id: jsonSaved.id)
      let jsonBoolean = try E.scalarTypeProbe(jsonReloaded).requiredBoolean().eval()
      report.checks["json_decoded_save"] = jsonReloaded.version == high.version + 1
        && jsonBoolean == true
    } catch { report.checks["json_native_codec"] = false; report.errors["json_native_codec"] = String(describing: error) }
    let partialRows = try await Q.scalarTypeProbesWithMinimalFields().withIdIs(high.id).selectRequiredString().limit(1)
      .comment("load a partial scalar for projection JSON")
      .purpose("preserve missing versus loaded-null through the native codec").executeForList(context)
    guard let partial = partialRows.first else { throw TeaQLError.execution("Partial row missing") }
    await provider.reset()
    do {
      let decoded = try JSONDecoder().decode(ScalarTypeProbe.self, from: JSONEncoder().encode(partial))
      _ = try E.scalarTypeProbe(decoded).requiredLong().eval()
      report.checks["json_not_loaded"] = false
    } catch is TeaQLNotLoadedError { report.checks["json_not_loaded"] = true }
    catch { report.checks["json_not_loaded"] = false; report.errors["json_not_loaded"] = String(describing: error) }
    report.checks["expression_no_io"] = await provider.snapshot().noEntry

    for operation in ["create", "update"] {
      for field in ["required_float", "optional_float", "required_double", "optional_double"] {
        for (index, number) in [Double.nan, .infinity, -.infinity].enumerated() {
          var row = try await operation == "create" ? newProbe(context, name: "bad-\(field)-\(index)") : reload(context, id: high.id)
          invalid(&row, field: field, value: number)
          do {
            _ = try JSONEncoder().encode(row)
            report.checks["json_nonfinite_\(operation)_\(field)_\(index)"] = false
          } catch is EncodingError { report.checks["json_nonfinite_\(operation)_\(field)_\(index)"] = true }
          await provider.reset()
          var rejected = false, errorType = "none"
          do { _ = try await row.auditAs("reject nonfinite generated scalar before provider admission").save(context) }
          catch { rejected = error is CheckException; errorType = String(describing: type(of: error)) }
          report.rejections.append(Rejection(operation: operation, field: field, index: index, rejected: rejected,
            errorType: errorType, counts: await provider.snapshot()))
        }
      }
    }
    var updated = try await reload(context, id: high.id)
    let version = updated.version
    updated.updateOptionalString("")
    updated.updateOptionalDecimal(Decimal(string: "-3.50")!)
    updated.updateOptionalBoolean(true)
    updated.updateOptionalInteger(-2_147_483_648)
    updated.updateOptionalLong(Int64.min)
    updated.updateOptionalFloat(-3.5)
    updated.updateOptionalDouble(0.125)
    updated.updateOptionalDate(ordinaryDay)
    updated.updateOptionalTime("23:59:59.999")
    updated.updateOptionalDatetime(offsetInstant)
    _ = try await updated.auditAs("update loaded nullable fields after independent rejected roots").save(context)
    let saved = try await reload(context, id: high.id), e = E.scalarTypeProbe(saved)
    check("updated_decimal", Optional(Decimal(string: "-3.50")!), &report) { try e.optionalDecimal().eval() }
    check("updated_boolean", Optional(true), &report) { try e.optionalBoolean().eval() }
    check("updated_integer", Optional(Int64(-2_147_483_648)), &report) { try e.optionalInteger().eval() }
    check("updated_long", Optional(Int64.min), &report) { try e.optionalLong().eval() }
    check("updated_float", Optional(-3.5), &report) { try e.optionalFloat().eval() }
    check("updated_double", Optional(0.125), &report) { try e.optionalDouble().eval() }
    report.checks["updated_version"] = saved.version == version + 1
    report.phase = "populated."; checkFields(saved, name, clock, &report, populated: true, requiredBoolean: true, requiredDecimal: Decimal(string: "0.1")!); report.phase = ""
    try await datePredicates(context, id: saved.id, day: ordinaryDay, optional: true, report: &report)
    try await dynamicDatePredicates(context, id: saved.id, day: ordinaryDay, optional: true, report: &report)
    var cleared = try JSONDecoder().decode(ScalarTypeProbe.self, from: JSONEncoder().encode(saved))
    report.phase = "populated_json."; checkFields(cleared, name, clock, &report, populated: true, requiredBoolean: true, requiredDecimal: Decimal(string: "0.1")!); report.phase = ""
    cleared.updateOptionalString(nil); cleared.updateOptionalBoolean(nil); cleared.updateOptionalInteger(nil); cleared.updateOptionalLong(nil)
    cleared.updateOptionalDecimal(nil); cleared.updateOptionalFloat(nil); cleared.updateOptionalDouble(nil); cleared.updateOptionalDate(nil)
    cleared.updateOptionalTime(nil); cleared.updateOptionalDatetime(nil)
    cleared.updateRequiredInteger(0)
    let clearedSave = try await cleared.auditAs("Clear all nullable families through one audited mutation").save(context)
    let final = try await reload(context, id: clearedSave.id)
    for field in ["optional_date", "optionalDate"] {
      for (name, predicate, expected) in [("null", "null", 1), ("not_null", "{\"$ne\":null}", 0), ("in", "{\"$in\":[\"2026-10-23\"]}", 0)] {
        let rows = try await Q.scalarTypeProbes().withIdIs(final.id).limit(1)
          .filterByJson("{\"filter\":{\"\(field)\":\(predicate)}}")
          .comment("Query a nullable Date after it has been explicitly cleared")
          .purpose("Distinguish SQL null from a date value").executeForList(context)
        report.checks["dynamic_date.cleared." + field + "." + name] = rows.count == expected
      }
    }
    report.phase = "cleared."; checkFields(final, name, clock, &report, requiredBoolean: true, requiredInteger: 0, requiredDecimal: Decimal(string: "0.1")!); report.phase = ""
    let clearDecoded = try JSONDecoder().decode(ScalarTypeProbe.self, from: JSONEncoder().encode(final))
    report.phase = "cleared_json."; checkFields(clearDecoded, name, clock, &report, requiredBoolean: true, requiredInteger: 0, requiredDecimal: Decimal(string: "0.1")!); report.phase = ""
    report.checks["final_version"] = final.version == 4
    report.finalID = String(final.id); report.finalVersion = final.version
    let nullable = try await Q.scalarTypeProbesWithMinimalFields().withIdIs(final.id).selectOptionalString().limit(1)
      .comment("Select one loaded null without unrelated scalar fields").purpose("Verify projection Codable preserves missing versus null").executeForList(context)
    guard let selected = nullable.first else { throw TeaQLError.execution("Selected-null row missing") }
    let selectedBytes = try JSONEncoder().encode(selected), selectedObject = try JSONSerialization.jsonObject(with: selectedBytes) as! [String: Any]
    report.checks["json_selected_null_token"] = selectedObject["optionalString"] is NSNull && !selectedObject.keys.contains("requiredLong")
    var nullableProjection = try JSONDecoder().decode(ScalarTypeProbe.self, from: selectedBytes)
    await provider.reset(); let priorClock = clock.count, priorAudit = await audit.events().count
    check("json_selected_null", nil as String?, &report) { try E.scalarTypeProbe(nullableProjection).optionalString().eval() }
    do { _ = try E.scalarTypeProbe(nullableProjection).requiredLong().eval(); report.checks["json_selected_omitted"] = false }
    catch is TeaQLNotLoadedError { report.checks["json_selected_omitted"] = true }
    nullableProjection.updateOptionalString("must not persist")
    do { _ = try await nullableProjection.auditAs("Reject a modified incomplete scalar projection").save(context); report.checks["partial_save_rejected"] = false }
    catch let error as CheckException { report.checks["partial_save_rejected"] = error.violations.contains { $0.ruleID == "invalid_type" && $0.message?.contains("fully loaded") == true } }
    report.checks["partial_no_provider"] = await provider.snapshot().noEntry
    report.checks["partial_no_clock"] = clock.count == priorClock
    report.checks["partial_no_audit"] = await audit.events().count == priorAudit
  }
}
