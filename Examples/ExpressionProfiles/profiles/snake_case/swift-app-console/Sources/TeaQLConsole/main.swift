import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

private let reference = "DOCK-042"
private let note = "Lift-gate pickup after 14:00"
private let dock = "North Receiving Terminal"

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw TeaQLError.execution(message) }
}

private func run() async throws {
    let args = CommandLine.arguments
    guard args.count == 4, ["first", "restart"].contains(args[3]) else {
        throw TeaQLError.execution("Supply DATABASE PROFILE {first|restart}")
    }
    let service = try SQLiteDataService(path: args[1])
    let module = GeneratedRuntimeModule.module
    var runtime = TeaQLRuntime()
    try runtime.install(module)
    let context = UserContext(runtime: runtime, queryExecutor: service, mutationExecutor: service,
        requestPolicy: RequestPolicy { $0 })
    try await context.ensureSchema(module)
    if args[3] == "first" {
        var order = try await Q.dispatchOrders().comment("Prepare the receiving order")
            .purpose("Set its loading instruction").newEntity(context)
        order.updateDistributionCenter(1)
        order.updateOrderReference(reference)
        order.updateHandlingNote(note)
        _ = try await order.auditAs("Register the dispatch at the receiving terminal").save(context)
    }
    let child = Q.dispatchOrders().withOrderReferenceIs(reference).limit(1).comment("Select the dispatch order")
    guard let root = try await Q.distributionCenters().withIdIs(1).selectDispatchOrderListWith(child).limit(1)
        .comment("Read the dispatch desk and its order").purpose("Check the complete loading instruction")
        .executeForList(context).first else {
        throw TeaQLError.execution("The dispatch desk is missing")
    }
    let desk = E.distributionCenter(root)
    let loadedDock = try desk.dockName().eval()
    let loadedReference = try desk.dispatchOrderList().first().orderReference().eval()
    let loadedNote = try desk.dispatchOrderList().first().handlingNote().eval()
    try require(loadedDock == dock && loadedReference == reference && loadedNote == note,
        "Loaded navigation returned a different dispatch order")
    let matches = try await Q.dispatchOrders().withOrderReferenceIs(reference).limit(2)
        .comment("Read back the dispatch record").purpose("Read the dispatch document with the generated field names")
        .executeForList(context)
    try require(matches.count == 1 && matches[0].id == 1 && matches[0].version == 1, "Wrong retained dispatch record")
    // The workspace receives the profile from its model file. Generated E
    // independently chooses the profile for diagnostics.
    guard let generatedFields = module.wireMetadata["DispatchOrder"],
        let profile = JsonFieldNamingProfile(rawValue: args[2]) else {
        throw TeaQLError.execution("The generated wire fields or model profile are missing")
    }
    let metadata = try WireEntityMetadata(entityType: generatedFields.entityType,
        canonicalFields: generatedFields.fields.keys.sorted(), profile: profile)
    guard let referenceKey = metadata.fields["order_reference"]?.wireName,
        let noteKey = metadata.fields["handling_note"]?.wireName else {
        throw TeaQLError.execution("The generated wire mapping is missing")
    }
    let document = [referenceKey: reference, noteKey: note]
    let decoded = try JSONDecoder().decode([String: String].self, from: JSONEncoder().encode(document))
    let normalized = try normalizeWireInput(decoded.mapValues { .string($0) }, metadata: metadata)
    try require(normalized.values == ["order_reference": .string(reference), "handling_note": .string(note)],
        "Wire naming changed the dispatch payload")

    guard let sparse = try await Q.distributionCentersWithMinimalFields().withIdIs(1).selectDockName().limit(1)
        .comment("Read the desk without its dispatch orders").purpose("Verify the modeled preload instruction")
        .executeForList(context).first else {
        throw TeaQLError.execution("The sparse dispatch desk is missing")
    }
    try require(try E.distributionCenter(sparse).dockName().eval() == dock, "The sparse projection lost its dock name")
    let diagnostic: NotLoadedDiagnostic
    let human: String
    do {
        _ = try E.distributionCenter(sparse).dispatchOrderList().first().orderReference().eval()
        throw TeaQLError.execution("A dispatch was returned without loading the list")
    } catch let missing as TeaQLCore.TeaQLNotLoadedError {
        diagnostic = missing.toWire()
        human = missing.description
    }
    let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnostic))
    let frame: [String: Any] = [
        "profile": args[2], "phase": args[3], "reference": reference, "handlingNote": note,
        "id": matches[0].id, "version": matches[0].version, "dock": dock,
        "document": document, "diagnostic": wire, "human": human,
    ]
    print("DISPATCH_DOCUMENT_PROFILE=" + String(decoding: try JSONSerialization.data(withJSONObject: frame), as: UTF8.self))
}

try await run()
