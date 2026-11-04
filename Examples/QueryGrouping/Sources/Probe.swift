import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

private func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw TeaQLError.execution(message) }
}

private struct Case: Encodable { let id: String; let value: TeaQLValue }
private struct Result: Encodable {
  let profile: String; let round: Int; let seeded: Int; let parentIds: [Int64]; let recordIds: [Int64]; let cases: [Case]
}

@main enum GroupingAliasProbe {
  static func main() async {
    do { try await run() }
    catch {
      FileHandle.standardError.write(Data(("SWIFT_GROUP_ALIAS_FAILURE=" + String(describing: error) + "\n").utf8))
      exit(1)
    }
  }
  private static func run() async throws {
    let args = CommandLine.arguments
    guard args.count == 4, let round = Int(args[3]), (1...2).contains(round), ["nonhuman", "human"].contains(args[2]) else {
      throw TeaQLError.execution("Usage: GroupingAliasProbe <database> <nonhuman|human> <1|2>")
    }
    let service = try SQLiteDataService(path: args[1])
    var runtime = TeaQLRuntime(); try runtime.install(GeneratedRuntimeModule.module)
    let context = UserContext(runtime: runtime, queryExecutor: service, mutationExecutor: service,
      requestPolicy: RequestPolicy { $0 }, querySQLLogEnabled: false, mutationSQLLogEnabled: false)
    try await context.ensureSchema(GeneratedRuntimeModule.module)
    try await context.ensureSchema(GeneratedRuntimeModule.module)
    let purpose = "verify generated grouping aliases and exact value domains"
    let roots = try await Q.queryPlatforms().limit(10).comment("inspect provisioned grouping root").purpose(purpose).executeForList(context)
    try require(roots.count == 1 && roots[0].id == 1, "generated root was not provisioned exactly once")
    let exact = Decimal(string: "12345678901234567890.123456789", locale: Locale(identifier: "en_US_POSIX"))!
    let instant = Date(timeIntervalSince1970: 1_787_995_800)
    var parents = try await Q.queryGroups().orderByIdAscending().limit(10).comment("find retained grouping parents").purpose(purpose).executeForList(context)
    let existing = try await Q.queryRecords().limit(10).comment("find retained grouping contributions").purpose(purpose).executeForList(context)
    var seeded = 0
    if existing.isEmpty {
      try require(round == 1 && parents.isEmpty, "do not silently repair or reseed an incomplete fixture")
      for name in ["Group A", "Group B"] {
        var parent = try Q.queryGroups().comment("prepare grouping parent").purpose(purpose).newEntity(context)
        parent.updateQueryPlatform(roots[0].id); parent.updateGroupName(name)
        _ = try await parent.auditAs("seed grouping parent through generated mutation").save(context)
        seeded += 1
      }
      parents = try await Q.queryGroups().orderByIdAscending().limit(10).comment("reload persisted grouping parents").purpose(purpose).executeForList(context)
      try require(parents.count == 2, "parent count changed")
      for index in 0..<4 {
        var record = try Q.queryRecords().comment("prepare exact grouping contribution").purpose(purpose).newEntity(context)
        record.updateQueryGroup(index == 3 ? nil : parents[index < 2 ? 0 : 1].id)
        record.updateRequiredText("row-\(index + 1)"); record.updateRequiredInteger(Int64(index + 1))
        record.updateRequiredLong(9_007_199_254_740_993); record.updateRequiredDecimal(exact)
        record.updateRequiredFloat(1.5); record.updateRequiredDouble(2.5)
        record.updateRequiredDate(Date(timeIntervalSince1970: 1_787_961_600))
        record.updateRequiredTime("09:30:00"); record.updateRequiredTimestamp(instant)
        record.updateActive(index != 0)
        _ = try await record.auditAs("seed exact contribution through generated mutation").save(context)
        seeded += 1
      }
    } else { try require(round == 2 && existing.count == 4 && parents.count == 2, "retained fixture was changed or unexpectedly reused") }
    let records = try await Q.queryRecords().selectSelfFields().orderByIdAscending().limit(10)
      .comment("inspect exact entity values before aggregate queries").purpose(purpose).executeForList(context)
    try require(records.count == 4, "four entity contributions required")
    for record in records {
      try require(try E.queryRecord(record).requiredLong().eval() == 9_007_199_254_740_993, "E long lost precision")
      try require(try E.queryRecord(record).requiredDecimal().eval() == exact, "E Decimal lost precision")
      try require(try E.queryRecord(record).requiredTimestamp().eval() == instant, "E instant changed")
      try require(try E.queryRecord(record).version().eval() == 1, "grouping changed an entity version")
    }
    func rows(_ query: QueryRecordRequest<RequestDraft>) async throws -> [TeaQLRecord] {
      Array(try await query.limit(10).comment("inspect generated named grouping results").purpose(purpose).executeForRows(context))
    }
    func values(_ rows: [TeaQLRecord]) -> TeaQLValue { .array(rows.map(TeaQLValue.object)) }
    var cases: [Case] = []
    let boolean = try await rows(Q.queryRecords().groupByActiveAs("bucket").countAs("hits").sumRequiredIntegerAs("total").orderByActiveAscending())
    for row in boolean { guard case .bool = row["bucket"], case .int = row["hits"], case .int = row["total"] else { throw TeaQLError.execution("group Boolean or numeric aggregate domain changed") } }
    cases.append(Case(id: "boolean-and-sum", value: values(boolean)))
    let shadow = try await rows(Q.queryRecords().groupByActiveAs("required_long").countAs("active").orderByActiveAscending())
    for row in shadow { guard case .bool = row["required_long"], case .int = row["active"] else { throw TeaQLError.execution("alias reused a model field type") } }
    cases.append(Case(id: "aliases-shadow-model-fields", value: values(shadow)))
    var timestamps = try await rows(Q.queryRecords().groupByRequiredTimestampAs("occurred").countAs("hits"))
    for i in timestamps.indices {
      guard case .timestamp(let milliseconds) = timestamps[i]["occurred"], milliseconds == 1_787_995_800_000 else {
        throw TeaQLError.execution("timestamp group lost its typed millisecond carrier")
      }
      timestamps[i]["occurred"] = .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000)))
    }
    cases.append(Case(id: "timestamp-decoding", value: values(timestamps)))
    var decimals = try await rows(Q.queryRecords().groupByRequiredDecimalAs("amount").countAs("hits"))
    for i in decimals.indices {
      guard case .decimal(let value) = decimals[i]["amount"], value == exact else { throw TeaQLError.execution("decimal group lost native exact type") }
      decimals[i]["amount"] = .string(NSDecimalNumber(decimal: value).stringValue)
    }
    cases.append(Case(id: "exact-decimal", value: values(decimals)))
    var longs = try await rows(Q.queryRecords().groupByRequiredLongAs("key").countAs("hits"))
    for i in longs.indices {
      guard case .int(let value) = longs[i]["key"], value == 9_007_199_254_740_993 else { throw TeaQLError.execution("long group lost precision") }
      longs[i]["key"] = .string(String(value))
    }
    cases.append(Case(id: "exact-long", value: values(longs)))
    cases.append(Case(id: "groups-without-aggregate", value: values(try await rows(Q.queryRecords().groupByActiveAs("bucket").orderByActiveAscending()))))
    cases.append(Case(id: "nullable-fk-group", value: values(try await rows(Q.queryRecords().groupByQueryGroupAs("owner").countAs("hits").orderByQueryGroupAscending()))))
    cases.append(Case(id: "multiple-group-aliases", value: values(try await rows(Q.queryRecords().groupByQueryGroupAs("owner").groupByActiveAs("bucket").countAs("hits").orderByQueryGroupAscending().orderByActiveAscending()))))
    var duplicateRejected = false
    do { _ = try await rows(Q.queryRecords().groupByActiveAs("same").countAs("same")) }
    catch TeaQLError.execution(let message) where message.hasPrefix("Duplicate aggregate result alias:") { duplicateRejected = true }
    try require(duplicateRejected, "duplicate output alias was accepted")
    cases.append(Case(id: "duplicate-alias-rejected", value: .bool(true)))
    cases.append(Case(id: "entity-E-and-version", value: .int(Int64(records.count))))
    let result = Result(profile: args[2], round: round, seeded: seeded, parentIds: parents.map(\.id), recordIds: records.map(\.id), cases: cases)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    print("SWIFT_GROUP_ALIAS_GENERATED=" + String(decoding: try encoder.encode(result), as: UTF8.self))
  }
}
