import TeaQLCore

// Generated trusted metadata. Binding and execution remain in the runtime.
enum GeneratedSearchModels {
    static let models: [String: GeneratedSearchModel] = [
        "DistributionCenter": GeneratedSearchModel(
            model: SearchModel(fields: [
               "id": "integer",
               "dock_name": "string",
               "dockName": "string",
               "version": "integer",
            ], relations: [
                "dispatchOrderList": "DispatchOrder",
            ]),
            queryFields: [
               "id": "id",
               "dock_name": "dockName",
               "dockName": "dockName",
               "version": "version",
            ]),
        "DispatchOrder": GeneratedSearchModel(
            model: SearchModel(fields: [
               "id": "integer",
               "distribution_center": "integer",
               "distributionCenter": "integer",
               "order_reference": "string",
               "orderReference": "string",
               "handling_note": "string",
               "handlingNote": "string",
               "version": "integer",
            ], relations: [
               "distribution_center": "DistributionCenter",
               "distributionCenter": "DistributionCenter",
            ]),
            queryFields: [
               "id": "id",
               "distribution_center": "distributionCenter",
               "distributionCenter": "distributionCenter",
               "order_reference": "orderReference",
               "orderReference": "orderReference",
               "handling_note": "handlingNote",
               "handlingNote": "handlingNote",
               "version": "version",
            ]),
    ]
}