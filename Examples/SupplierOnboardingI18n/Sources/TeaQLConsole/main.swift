import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

struct Scenario: Decodable {
    struct Warehouse: Decodable { let id: Int64 }
    struct Registration: Decodable {
        let name: String?
        let minimumOrderQuantity: Int64

        enum CodingKeys: String, CodingKey {
            case name
            case minimumOrderQuantity = "minimum_order_quantity"
        }
    }
    struct Step: Decodable {
        let operation: String
        let context: String
        let locale: String?
        let path: String?
        let input: Registration?
        let scenarioID: String?

        enum CodingKeys: String, CodingKey {
            case operation, context, locale, path, input
            case scenarioID = "case"
        }
    }

    let database: String
    let warehouse: Warehouse
    let steps: [Step]
}

func emit(_ step: Scenario.Step, _ context: UserContext, type: String, details: [String: Any] = [:]) throws {
    var event = details
    event["type"] = type
    event["context"] = step.context
    event["effectiveLocale"] = context.locale.rawValue
    let data = try JSONSerialization.data(withJSONObject: event)
    print("TEAQL_I18N_SHOWCASE " + String(decoding: data, as: UTF8.self))
}

func verifyFailure(_ step: Scenario.Step, _ context: UserContext, warehouseID: Int64) async throws {
    guard let input = step.input, let id = step.scenarioID else {
        throw TeaQLError.execution("Missing supplier registration input")
    }
    var supplier = try Q.suppliers().comment("Prepare supplier registration")
        .purpose("Register a supplier for warehouse purchasing").newEntity(context)
    supplier.updateWarehouse(warehouseID)
    supplier.updateName(input.name)
    supplier.updateMinimumOrderQuantity(input.minimumOrderQuantity)
    do {
        _ = try await supplier.auditAs("Register the supplier for purchasing").save(context)
    } catch let error as CheckException {
        guard error.violations.count == 1, let violation = error.violations.first else { throw error }
        let wire = violation.wire()
        guard let message = wire.message else { throw error }
        let key: String
        var arguments: [String: Int] = [:]
        switch violation.ruleID.lowercased() {
        case "required": key = "checker.required"
        case "min":
            key = "checker.min"
            guard let lowerBound = wire.systemValue.flatMap(Int.init) else { throw error }
            arguments["minimum"] = lowerBound
        default: throw error
        }
        let nativeArguments = ["inputValue": wire.inputValue, "systemValue": wire.systemValue].compactMapValues { $0 }
        try emit(step, context, type: "validation", details: [
            "case": id, "messageKey": key, "nativeRule": violation.ruleID,
            "location": violation.location.modelPath, "arguments": arguments,
            "message": message, "nativeArguments": nativeArguments,
        ])
        return
    }
    throw TeaQLError.execution("Invalid supplier registration was stored: " + id)
}

func main() async throws {
    let plan = try JSONDecoder().decode(Scenario.self, from: FileHandle.standardInput.readDataToEndOfFile())
    let service = try SQLiteDataService(path: plan.database)
    var runtime = TeaQLRuntime()
    try runtime.install(GeneratedRuntimeModule.module)
    func createContext() -> UserContext {
        UserContext(runtime: runtime, queryExecutor: service, mutationExecutor: service,
                    requestPolicy: RequestPolicy { $0 })
    }
    let main = createContext()
    try await main.ensureSchema(GeneratedRuntimeModule.module)
    var contexts = ["main": main, "independent": createContext()]
    for step in plan.steps {
        guard var context = contexts[step.context] else { throw TeaQLError.execution("Unknown example context") }
        switch step.operation {
        case "select":
            guard let code = step.locale else { throw TeaQLError.execution("Missing requested locale") }
            do {
                try context.setLocaleCode(code)
                try emit(step, context, type: "locale", details: ["requestedLocale": code, "accepted": true])
            } catch let error as UnsupportedLocaleError {
                try emit(step, context, type: "locale", details: [
                    "requestedLocale": error.localeCode, "accepted": false,
                    "nativeError": String(describing: type(of: error)),
                ])
            }
        case "validate":
            try await verifyFailure(step, context, warehouseID: plan.warehouse.id)
        case "install-catalog":
            guard let path = step.path else { throw TeaQLError.execution("Missing catalog path") }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            context.installI18nCatalog(try I18nCatalog(data: data, fallback: .builtin))
            try emit(step, context, type: "catalog-installed")
        case "verify-unchanged":
            let rows = try await Q.suppliersWithMinimalFields().limit(1)
                .comment("Check the rejected registrations").purpose("Verify no invalid supplier was stored")
                .executeForList(context)
            try emit(step, context, type: "storage", details: ["supplierCount": rows.count])
        default: throw TeaQLError.execution("Unknown example operation: " + step.operation)
        }
        contexts[step.context] = context
    }
}

try await main()
