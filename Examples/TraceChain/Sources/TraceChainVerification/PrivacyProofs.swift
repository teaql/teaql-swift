import Foundation
import GeneratedTeaQL
import TeaQLCore

func generatedLoadedPrivacy(_ context: UserContext, commands: CommandCapture, sql: SQLExecutionEvidenceStore,
                            audit: AuditCapture, base: Int64) async throws {
    await commands.clear(); await audit.clear()
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
        await sql.enableAll(); await audit.clear(); await commands.clear(commitBarrier: true)
        let reason = "page one replace \(old) with \(new)"
        _ = try await loaded.auditAs(reason).save(context)
        let facts = await sql.snapshot(), events = await audit.snapshot(), raw = await commands.snapshot()
        try require(facts.count == 4 && events.count == 2, "privacy proof requires real parent/child writes and reads")
        guard let rootID = try E.customerOrder(loaded).id().eval()
        else { throw TeaQLError.execution("loaded privacy root ID missing") }
        let rawExpected = [NodeExpectation(type: "CustomerOrder", id: rootID, reason: reason)]
        let safeReason = "page one replace [REDACTED] with [REDACTED]"
        let safeExpected = [NodeExpectation(type: "CustomerOrder", id: rootID, reason: safeReason)]
        try require(raw.count == 2, "privacy proof requires actual parent/child commands")
        for request in raw {
            try require(request.intent.comment == reason, "privacy command preserves original request intent")
            try checkChain(request.mutation.mutationLineage ?? [], rawExpected, boundary: "raw privacy command")
        }
        try require(raw.first { $0.mutation.entity.name == "OrderItem" }?.mutation.values["name"] == .string(new),
            "privacy must not rewrite command bindings")
        for fact in facts {
            try checkChain(fact.mutationLineage, safeExpected, boundary: "safe privacy SQL")
            try require(fact.auditReason == safeReason && fact.executionOutcome == "success", "safe SQL keeps root reason")
            try require(fact.tracePath.count == 4 && fact.tracePath.first?.name == "CustomerOrder"
                && fact.tracePath[2].kind == "provider" && fact.tracePath[2].name == "sqlite"
                && fact.tracePath.last?.kind == "sql", "safe SQL retains complete physical route")
            try require(!(fact.auditReason ?? "").contains(old) && !(fact.auditReason ?? "").contains(new),
                "old/new private sibling value leaked into SQL intent")
            try require(!fact.debugSQL.contains(old) && !fact.debugSQL.contains(new), "private binding leaked")
        }
        for event in events {
            try checkChain(event.mutationLineage ?? [], safeExpected, boundary: "safe privacy audit")
            try require(event.reason == safeReason, "safe audit keeps root reason")
            try require(!event.reason.contains(old) && !event.reason.contains(new), "private value leaked into audit")
        }
        func nodeFields(_ node: TraceNode) -> [String: Any] {
            ["kind": node.kind, "name": node.name, "id": node.entityID?.int64Value ?? 0,
             "reason": node.comment, "level": node.level]
        }
        let commandFields: [[String: Any]] = raw.map { request in
            ["entity": request.mutation.entity.name, "comment": request.intent.comment,
             "lineage": (request.mutation.mutationLineage ?? []).map(nodeFields)]
        }
        let sqlFields: [[String: Any]] = facts.map { fact in
            ["operation": fact.operation.rawValue, "comment": fact.comment ?? "",
             "purpose": fact.purpose ?? "", "auditReason": fact.auditReason ?? "",
             "outcome": fact.executionOutcome ?? "", "debugSQL": fact.debugSQL,
             "tracePath": fact.tracePath.map(nodeFields), "lineage": fact.mutationLineage.map(nodeFields)]
        }
        let auditFields: [[String: Any]] = events.map { event in
            ["entity": event.entity, "id": event.entityID?.int64Value ?? 0,
             "operation": event.operation.rawValue, "reason": event.reason,
             "lineage": (event.mutationLineage ?? []).map(nodeFields)]
        }
        let observed: [String: Any] = ["logging": context.querySQLLogEnabled, "rootID": rootID,
            "rawReason": reason, "safeReason": safeReason,
            "commands": commandFields, "sql": sqlFields, "audit": auditFields]
        let json = try JSONSerialization.data(withJSONObject: observed, options: [.sortedKeys])
        print("PRIVATE_LINEAGE_OBSERVED " + String(decoding: json, as: UTF8.self))
        print("PASS Swift complete private lineage: raw commands, safe SQL/readback and committed audit")
    }
    await sql.enableAll()
    _ = try await Q.customerOrders().withIdIs(root.id).limit(1)
        .comment("independent PRIVATEOLDITEM").purpose("verify invocation privacy isolation").executeForList(context)
    let independent = await sql.snapshot()
    try require(independent.first?.comment == "independent PRIVATEOLDITEM", "prior graph contaminated independent query")
    print("PASS generated loaded private old/new values across graph SQL/readback/audit and independent query")
}
