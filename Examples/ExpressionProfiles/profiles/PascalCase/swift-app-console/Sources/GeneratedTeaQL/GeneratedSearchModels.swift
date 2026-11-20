import TeaQLCore

// Generated trusted metadata. Binding and execution remain in the runtime.
enum GeneratedSearchModels {
    static let models: [String: GeneratedSearchModel] = [
        "DistributionCenter": GeneratedSearchModel(
            model: SearchModel(fields: [
               "id": "integer",
               "Id": "integer",
               "dock_name": "string",
               "dockName": "string",
               "DockName": "string",
               "version": "integer",
               "Version": "integer",
            ], relations: [
                "dispatchOrderList": "DispatchOrder",
            ]),
            queryFields: [
               "id": "id",
               "Id": "id",
               "dock_name": "dockName",
               "dockName": "dockName",
               "DockName": "dockName",
               "version": "version",
               "Version": "version",
            ]),
        "DispatchOrder": GeneratedSearchModel(
            model: SearchModel(fields: [
               "id": "integer",
               "Id": "integer",
               "distribution_center": "integer",
               "distributionCenter": "integer",
               "DistributionCenter": "integer",
               "order_reference": "string",
               "orderReference": "string",
               "OrderReference": "string",
               "handling_note": "string",
               "handlingNote": "string",
               "HandlingNote": "string",
               "version": "integer",
               "Version": "integer",
            ], relations: [
               "distribution_center": "DistributionCenter",
               "distributionCenter": "DistributionCenter",
               "DistributionCenter": "DistributionCenter",
            ]),
            queryFields: [
               "id": "id",
               "Id": "id",
               "distribution_center": "distributionCenter",
               "distributionCenter": "distributionCenter",
               "DistributionCenter": "distributionCenter",
               "order_reference": "orderReference",
               "orderReference": "orderReference",
               "OrderReference": "orderReference",
               "handling_note": "handlingNote",
               "handlingNote": "handlingNote",
               "HandlingNote": "handlingNote",
               "version": "version",
               "Version": "version",
            ]),
    ]
}