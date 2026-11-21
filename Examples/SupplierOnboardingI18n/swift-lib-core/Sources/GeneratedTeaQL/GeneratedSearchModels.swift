import TeaQLCore

// Generated trusted metadata. Binding and execution remain in the runtime.
enum GeneratedSearchModels {
    static let models: [String: GeneratedSearchModel] = [
        "Warehouse": GeneratedSearchModel(
            model: SearchModel(fields: [
               "id": "integer",
               "name": "string",
               "version": "integer",
            ], relations: [
                "supplierList": "Supplier",
            ]),
            queryFields: [
               "id": "id",
               "name": "name",
               "version": "version",
            ]),
        "Supplier": GeneratedSearchModel(
            model: SearchModel(fields: [
               "id": "integer",
               "warehouse": "integer",
               "name": "string",
               "minimum_order_quantity": "integer",
               "minimumOrderQuantity": "integer",
               "version": "integer",
            ], relations: [
               "warehouse": "Warehouse",
            ]),
            queryFields: [
               "id": "id",
               "warehouse": "warehouse",
               "name": "name",
               "minimum_order_quantity": "minimumOrderQuantity",
               "minimumOrderQuantity": "minimumOrderQuantity",
               "version": "version",
            ]),
    ]
}