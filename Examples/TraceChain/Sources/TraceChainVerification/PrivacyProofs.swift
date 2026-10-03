import Foundation
import GeneratedTeaQL
import TeaQLCore

func generatedLoadedPrivacy(_ context: UserContext, sql: SQLExecutionEvidenceStore,
                            audit: AuditCapture, base: Int64) async throws {
    var root = try order(context, id: base + 9000, label: "PRIVACY-\(base)")
    var item = try Q.orderItems().comment("initialize private item")
        .purpose("verify loaded scalar privacy").newEntity(context)
    item.updateId(base + 9001); item.updateName("PRIVATEOLDITEM")
    root.orderItemList.append(item)
    _ = try await root.auditAs("seed privacy fixture").save(context)
    for (old, new) in [("PRIVATEOLDITEM", "PRIVATENEWITEM"), ("PRIVATENEWITEM", "PRIVATEFINALITEM")] {
        guard var loaded = try await Q.customerOrders().withIdIs(root.id)
            .selectOrderItemListWith(Q.orderItems().limit(2)).limit(1)
            .comment("load privacy graph").purpose("verify old scalar capture").executeForList(context).first
        else { throw TeaQLError.execution("privacy graph missing") }
        try require(loaded.orderItemList.count == 1, "expected one private child")
        try require(E.orderItem(loaded.orderItemList[0]).name().eval() == old, "wrong persisted private value")
        loaded.updateDescription("ordinary public description")
        loaded.orderItemList[0].updateName(new)
        await sql.enableAll(); await audit.clear()
        _ = try await loaded.auditAs("page one replace \(old) with \(new)").save(context)
        let facts = await sql.snapshot(), events = await audit.snapshot()
        try require(facts.count == 4 && events.count == 2, "privacy proof requires real parent/child writes and reads")
        for fact in facts {
            try require(!(fact.auditReason ?? "").contains(old) && !(fact.auditReason ?? "").contains(new),
                "old/new private sibling value leaked into SQL intent")
            try require(!fact.debugSQL.contains(old) && !fact.debugSQL.contains(new), "private binding leaked")
        }
        for event in events {
            try require(!event.reason.contains(old) && !event.reason.contains(new), "private value leaked into audit")
        }
    }
    await sql.enableAll()
    _ = try await Q.customerOrders().withIdIs(root.id).limit(1)
        .comment("independent PRIVATEOLDITEM").purpose("verify invocation privacy isolation").executeForList(context)
    let independent = await sql.snapshot()
    try require(independent.first?.comment == "independent PRIVATEOLDITEM", "prior graph contaminated independent query")
    print("PASS generated loaded private old/new values across graph SQL/readback/audit and independent query")
}
