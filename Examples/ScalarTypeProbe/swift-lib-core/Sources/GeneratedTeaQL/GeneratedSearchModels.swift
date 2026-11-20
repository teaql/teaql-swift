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
                "freightQuoteList": "FreightQuote",
            ]),
            queryFields: [
               "id": "id",
               "name": "name",
               "version": "version",
            ]),
        "FreightQuote": GeneratedSearchModel(
            model: SearchModel(fields: [
               "id": "integer",
               "platform": "integer",
               "reference": "string",
               "amount": "decimal",
               "shipment_number": "integer",
               "shipmentNumber": "integer",
               "package_count": "integer",
               "packageCount": "integer",
               "delivery_date": "date",
               "deliveryDate": "date",
               "pickup_time": "unsupported",
               "pickupTime": "unsupported",
               "quoted_at": "timestamp",
               "quotedAt": "timestamp",
               "instructions": "string",
               "version": "integer",
            ], relations: [
               "platform": "Platform",
            ]),
            queryFields: [
               "id": "id",
               "platform": "platform",
               "reference": "reference",
               "amount": "amount",
               "shipment_number": "shipmentNumber",
               "shipmentNumber": "shipmentNumber",
               "package_count": "packageCount",
               "packageCount": "packageCount",
               "delivery_date": "deliveryDate",
               "deliveryDate": "deliveryDate",
               "pickup_time": "pickupTime",
               "pickupTime": "pickupTime",
               "quoted_at": "quotedAt",
               "quotedAt": "quotedAt",
               "instructions": "instructions",
               "version": "version",
            ]),
    ]
}