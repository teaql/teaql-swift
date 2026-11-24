import TeaQLCore

// Generated trusted metadata. Binding and execution remain in the runtime.
enum GeneratedSearchModels {
    static let models: [String: GeneratedSearchModel] = [
        "Platform": GeneratedSearchModel(
            model: SearchModel(fields: [
               "id": "integer",
               "name": "string",
               "version": "integer",
            ], relations: [
                "customerOrderList": "CustomerOrder",
            ]),
            queryFields: [
               "id": "id",
               "name": "name",
               "version": "version",
            ]),
        "CustomerOrder": GeneratedSearchModel(
            model: SearchModel(fields: [
               "id": "integer",
               "platform": "integer",
               "order_number": "string",
               "orderNumber": "string",
               "description": "string",
               "version": "integer",
            ], relations: [
               "platform": "Platform",
                "orderItemList": "OrderItem",
                "paymentList": "Payment",
                "shipmentList": "Shipment",
            ]),
            queryFields: [
               "id": "id",
               "platform": "platform",
               "order_number": "orderNumber",
               "orderNumber": "orderNumber",
               "description": "description",
               "version": "version",
            ]),
        "OrderItem": GeneratedSearchModel(
            model: SearchModel(fields: [
               "id": "integer",
               "customer_order": "integer",
               "customerOrder": "integer",
               "name": "string",
               "version": "integer",
            ], relations: [
               "customer_order": "CustomerOrder",
               "customerOrder": "CustomerOrder",
            ]),
            queryFields: [
               "id": "id",
               "customer_order": "customerOrder",
               "customerOrder": "customerOrder",
               "name": "name",
               "version": "version",
            ]),
        "Payment": GeneratedSearchModel(
            model: SearchModel(fields: [
               "id": "integer",
               "customer_order": "integer",
               "customerOrder": "integer",
               "reference_code": "string",
               "referenceCode": "string",
               "version": "integer",
            ], relations: [
               "customer_order": "CustomerOrder",
               "customerOrder": "CustomerOrder",
                "paymentAttemptList": "PaymentAttempt",
            ]),
            queryFields: [
               "id": "id",
               "customer_order": "customerOrder",
               "customerOrder": "customerOrder",
               "reference_code": "referenceCode",
               "referenceCode": "referenceCode",
               "version": "version",
            ]),
        "PaymentAttempt": GeneratedSearchModel(
            model: SearchModel(fields: [
               "id": "integer",
               "payment": "integer",
               "reference_code": "string",
               "referenceCode": "string",
               "version": "integer",
            ], relations: [
               "payment": "Payment",
            ]),
            queryFields: [
               "id": "id",
               "payment": "payment",
               "reference_code": "referenceCode",
               "referenceCode": "referenceCode",
               "version": "version",
            ]),
        "Shipment": GeneratedSearchModel(
            model: SearchModel(fields: [
               "id": "integer",
               "customer_order": "integer",
               "customerOrder": "integer",
               "reference_code": "string",
               "referenceCode": "string",
               "version": "integer",
            ], relations: [
               "customer_order": "CustomerOrder",
               "customerOrder": "CustomerOrder",
            ]),
            queryFields: [
               "id": "id",
               "customer_order": "customerOrder",
               "customerOrder": "customerOrder",
               "reference_code": "referenceCode",
               "referenceCode": "referenceCode",
               "version": "version",
            ]),
    ]
}