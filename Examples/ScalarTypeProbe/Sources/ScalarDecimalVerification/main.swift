import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite
import TeaQLTestSupport

private struct ProbeFailure: Error { let message: String }
private func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw ProbeFailure(message: message) }
}

@main enum ScalarDecimalVerification {
  static func main() async throws {
    let path = ProcessInfo.processInfo.environment["TEAQL_SCALAR_DB"]
      ?? FileManager.default.temporaryDirectory.appendingPathComponent("teaql-scalar-\(UUID().uuidString).sqlite").path
    let service = try SQLiteDataService(path: path)
    let audit = RecordingAuditSink()
    var runtime = TeaQLRuntime()
    try runtime.install(GeneratedRuntimeModule.module)
    let context = UserContext(runtime: runtime, queryExecutor: service, mutationExecutor: service,
      requestPolicy: RequestPolicy { $0 }, auditSink: audit)
    try await context.ensureSchema(GeneratedRuntimeModule.module)
    try await context.ensureSchema(GeneratedRuntimeModule.module)
    let roots = try await Q.typePlatforms().limit(10).comment("check scalar bootstrap")
      .purpose("verify repeated schema setup").executeForList(context)
    try require(roots.count == 1 && roots.first?.id == 1, "duplicate or missing seeded root")

    var invalid = try Q.scalarTypeProbes().comment("prepare missing required fields")
      .purpose("verify canonical checker rejection").newEntity(context)
    do {
      _ = try await invalid.auditAs("reject incomplete scalar fixture").save(context)
      throw ProbeFailure(message: "incomplete fixture was persisted")
    } catch let error as CheckException {
      try require(error.violations.contains { $0.ruleID == "required" && $0.location.modelPath == "required_string" },
        "canonical required_string checker path missing")
    }

    let precise = Decimal(string: "123456789012.3456789", locale: Locale(identifier: "en_US_POSIX"))!
    let existing = try await Q.scalarTypeProbes().withRequiredStringIs("exact-high").limit(1)
      .comment("find retained exact scalar").purpose("repeat on the same database").executeForList(context)
    let fresh = existing.isEmpty
    if fresh {
      for (name, amount) in [("numeric-two", Decimal(2)), ("numeric-ten", Decimal(10)), ("exact-high", precise)] {
        var entity = try newProbe(context, name: name, amount: amount)
        _ = try await entity.auditAs("seed through generated scalar mutation API").save(context)
      }
    }
    let rows = try await Q.scalarTypeProbes().selectSelfFields().orderByRequiredDecimalAscending().limit(10)
      .selectTypePlatformWith(Q.typePlatformsWithMinimalFields().selectName())
      .comment("load exact scalars in numeric order").purpose("verify generated Q and E").executeForList(context)
    try require(rows.count == 3 && rows.map(\.requiredDecimal) == [Decimal(2), Decimal(10), precise],
      "numeric ordering or row count mismatch")
    var high = rows[2]
    try require(try E.scalarTypeProbe(high).requiredDecimal().eval() == precise, "E Decimal lost digits")
    try require(try E.scalarTypeProbe(high).typePlatform().name().eval() == "Scalar Type Conformance",
      "forward E relationship mismatch")
    try require(try E.scalarTypeProbe(high).optionalString().eval() == "left\0中文-right",
      "ordinary UTF-8 text was truncated at NUL")
    try require(high.requiredTime == "09:30:15" && high.optionalTime == nil, "time/null scalar mismatch")
    let exactRows = try await Q.scalarTypeProbes().withRequiredDecimalIs(precise).limit(10)
      .comment("match the precise Decimal value").purpose("verify typed predicate binding").executeForList(context)
    try require(exactRows.count == 1 && exactRows.first?.id == high.id, "typed Decimal equality failed")
    let aggregateRows = try await Q.scalarTypeProbes().sumRequiredDecimalAs("_total")
      .minRequiredDecimalAs("_minimum").maxRequiredDecimalAs("_maximum").limit(1)
      .comment("summarize exact Decimal values").purpose("verify generated aggregate API").executeForRows(context)
    guard let aggregate = aggregateRows.first else { throw ProbeFailure(message: "aggregate row missing") }
    try require(aggregate["_total"] == .decimal(precise + 12)
      && aggregate["_minimum"] == .decimal(2) && aggregate["_maximum"] == .decimal(precise),
      "exact Decimal aggregate mismatch")
    let partial = try await Q.scalarTypeProbesWithMinimalFields().withIdIs(high.id).limit(1)
      .comment("load a bounded identity projection").purpose("verify E NotLoaded").executeForList(context)
    guard let projected = partial.first else { throw ProbeFailure(message: "partial row missing") }
    do {
      _ = try E.scalarTypeProbe(projected).requiredDecimal().eval()
      throw ProbeFailure(message: "unselected Decimal was treated as loaded")
    } catch is TeaQLNotLoadedError { }

    let previousVersion = high.version
    let nextOptional: Decimal? = high.optionalDecimal == nil ? Decimal(string: "0.10")! : nil
    high.updateOptionalDecimal(nextOptional)
    _ = try await high.auditAs("update a nullable Decimal without losing required precision").save(context)
    let reloaded = try await Q.scalarTypeProbes().withIdIs(high.id).limit(1)
      .comment("reload the audited scalar update").purpose("verify exact value and version").executeForList(context)
    guard let saved = reloaded.first else { throw ProbeFailure(message: "updated row missing") }
    try require(saved.requiredDecimal == precise && saved.optionalDecimal == nextOptional
      && saved.version == previousVersion + 1, "Decimal/null/version update mismatch")
    let changes = await audit.events().filter { $0.entity == "ScalarTypeProbe" }
      .flatMap { $0.mutationGovernance?.operations.flatMap(\.changedFields) ?? [] }
    try require(changes.contains("optional_decimal"), "canonical optional_decimal audit field missing")
    print("PASS Swift generated scalar Decimal fresh=\(fresh) rows=3 version=\(saved.version) exact=\(precise) Q=PASS E=PASS Checker=PASS Mutation=PASS")
  }

  private static func newProbe(_ context: UserContext, name: String, amount: Decimal) throws -> ScalarTypeProbe {
    var entity = try Q.scalarTypeProbes().comment("prepare one scalar fixture")
      .purpose("verify exact SQLite storage").newEntity(context)
    entity.updateTypePlatform(1)
    entity.updateRequiredString(name)
    entity.updateOptionalString("left\0中文-right")
    entity.updateRequiredBoolean(true)
    entity.updateRequiredInteger(7)
    entity.updateRequiredLong(1_234_567)
    entity.updateRequiredDecimal(amount)
    entity.updateRequiredFloat(1.25)
    entity.updateRequiredDouble(2.5)
    entity.updateRequiredDate(Date(timeIntervalSince1970: 1_792_454_400))
    entity.updateRequiredTime("09:30:15")
    entity.updateRequiredDatetime(Date(timeIntervalSince1970: 1_792_488_600))
    return entity
  }
}
