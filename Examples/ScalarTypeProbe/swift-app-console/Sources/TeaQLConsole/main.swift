import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

private struct QuoteFailure: Error { let reason: String }

private func require(_ condition: Bool, _ reason: String) throws {
    if !condition { throw QuoteFailure(reason: reason) }
}

private let locale = Locale(identifier: "en_US_POSIX")
private let preciseAmount = Decimal(string: "123456789012.3456789", locale: locale)!
private let totalAmount = Decimal(string: "123456789012.6456789", locale: locale)!
private let firstShipment: Int64 = 9_007_199_254_740_993
private let maximumCount = Int64(Int32.max)
private let deliveryDate = Date(timeIntervalSince1970: 1_793_404_800)
private let pickup = "09:30:15.123456"
private let quotedAt = Date(timeIntervalSince1970: 1_793_382_300.123)

private func readQuote(_ context: UserContext, _ reference: String) async throws -> FreightQuote {
    guard let quote = try await Q.freightQuotes().withReferenceIs(reference).limit(1)
        .comment("Read the selected freight quote").purpose("Verify the retained delivery commitment")
        .executeForList(context).first else {
        throw QuoteFailure(reason: "The freight quote is missing")
    }
    return quote
}

private func registerQuotes(_ context: UserContext) async throws {
    let seeds: [(reference: String, amount: String, count: Int64, instructions: String?)] = [
        ("SEA-001", "0.10", 2, nil),
        ("SEA-002", "0.20", 3, ""),
        ("SEA-003", "3.50", maximumCount, "Hold for inspection"),
    ]
    for (index, seed) in seeds.enumerated() {
        var quote = try await Q.freightQuotes().comment("Prepare a freight quote")
            .purpose("Price the shipment for its delivery window").newEntity(context)
        quote.updatePlatform(1)
        quote.updateReference(seed.reference)
        quote.updateAmount(Decimal(string: seed.amount, locale: locale))
        quote.updateShipmentNumber(firstShipment + Int64(index))
        quote.updatePackageCount(seed.count)
        quote.updateDeliveryDate(deliveryDate)
        quote.updatePickupTime(pickup)
        quote.updateQuotedAt(quotedAt)
        quote.updateInstructions(seed.instructions)
        _ = try await quote.auditAs("Register a freight quote").save(context)
    }
    var revised = try await readQuote(context, "SEA-003")
    try require(revised.amount == Decimal(string: "3.50", locale: locale), "The initial offshore rate changed")
    revised.updateAmount(preciseAmount)
    _ = try await revised.auditAs("Accept the revised offshore freight rate").save(context)
}

private func verifyWire(_ high: FreightQuote, _ context: UserContext) async throws {
    let payload = try JSONEncoder().encode(high)
    let restored = E.freightQuote(try JSONDecoder().decode(FreightQuote.self, from: payload))
    try require(try restored.amount().eval() == preciseAmount && restored.shipmentNumber().eval() == firstShipment + 2,
        "JSON changed the freight amount or shipment identity")
    try require(try restored.packageCount().eval() == maximumCount && restored.deliveryDate().eval() == deliveryDate
        && restored.pickupTime().eval() == pickup && restored.quotedAt().eval() == quotedAt,
        "JSON changed the package count, delivery date, wall clock or UTC timestamp")

    guard let sparse = try await Q.freightQuotesWithMinimalFields().withIdIs(high.id).selectReference().limit(1)
        .comment("Read only the quote reference").purpose("Keep unselected delivery instructions distinct")
        .executeForList(context).first else {
        throw QuoteFailure(reason: "The sparse freight quote is missing")
    }
    let wire = try JSONEncoder().encode(sparse)
    let fields = try JSONSerialization.jsonObject(with: wire) as? [String: Any]
    try require(fields != nil && fields?["instructions"] == nil, "Sparse JSON included unselected instructions")
    let decoded = try JSONDecoder().decode(FreightQuote.self, from: wire)
    do {
        _ = try E.freightQuote(decoded).instructions().eval()
        throw QuoteFailure(reason: "Unselected instructions became a value")
    } catch is TeaQLNotLoadedError { }
}

private func run() async throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 3, ["first", "restart"].contains(arguments[2]) else {
        throw QuoteFailure(reason: "Usage: TeaQLConsole DATABASE {first|restart}")
    }
    let phase = arguments[2]
    let service = try SQLiteDataService(path: arguments[1])
    var runtime = TeaQLRuntime()
    try runtime.install(GeneratedRuntimeModule.module)
    let context = UserContext(runtime: runtime, queryExecutor: service, mutationExecutor: service,
        requestPolicy: RequestPolicy { $0 })
    try await context.ensureSchema(GeneratedRuntimeModule.module)
    if phase == "first" { try await registerQuotes(context) }

    let rows = try await Q.freightQuotes().orderByAmountAscending().limit(4)
        .comment("Compare outstanding freight bids").purpose("Rank freight bids numerically").executeForList(context)
    try require(rows.map(\.reference) == ["SEA-001", "SEA-002", "SEA-003"], "Unexpected quote rank or count")
    try require(rows.map(\.amount) == [Decimal(string: "0.10", locale: locale),
        Decimal(string: "0.20", locale: locale), preciseAmount], "Persisted freight digits changed")
    try require(rows.map(\.shipmentNumber) == [firstShipment, firstShipment + 1, firstShipment + 2],
        "Persisted shipment numbers changed")
    try require(rows.map(\.instructions) == [nil, "", "Hold for inspection"], "Null and empty instructions were conflated")
    var high = rows[2]
    let matches = try await Q.freightQuotes().withAmountIs(preciseAmount).limit(1)
        .comment("Find the revised offshore freight rate").purpose("Match an exact Decimal amount").executeForList(context)
    try require(matches.map(\.id) == [high.id] && high.version == 2, "Exact amount selected a different freight quote")
    let summary = try await Q.freightQuotes().sumAmountAs("total").limit(1)
        .comment("Sum the outstanding freight bids").purpose("Keep exact base-ten precision").executeForRows(context)
    try require(summary.count == 1 && summary.first?["total"] == .decimal(totalAmount), "The freight total changed")
    try await verifyWire(high, context)

    high.updateAmount(nil)
    do {
        _ = try await high.auditAs("Reject a quote without its required amount").save(context)
        throw QuoteFailure(reason: "A missing freight amount was persisted")
    } catch let error as CheckException {
        try require(error.violations.contains { $0.ruleID == "required" && $0.location.modelPath == "amount" },
            "The missing amount was rejected at the wrong field")
    }
    let retained = try await readQuote(context, "SEA-003")
    try require(retained.version == 2 && retained.amount == preciseAmount, "Rejected quote changed persisted state")
    let frame: [String: Any] = [
        "phase": phase, "quotes": rows.count, "total": NSDecimalNumber(decimal: totalAmount).stringValue,
        "precise": NSDecimalNumber(decimal: retained.amount!).stringValue, "version": retained.version,
        "invalidAmountRejected": true, "sparseInstructionsNotLoaded": true,
    ]
    print("FREIGHT_QUOTE=" + String(decoding: try JSONSerialization.data(withJSONObject: frame, options: .sortedKeys), as: UTF8.self))
}

try await run()
