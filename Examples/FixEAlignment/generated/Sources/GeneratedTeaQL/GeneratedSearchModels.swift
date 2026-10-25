import TeaQLCore

// Generated trusted metadata. Binding and execution remain in the runtime.
enum GeneratedSearchModels {
    static let models: [String: GeneratedSearchModel] = [
        "Tenant": GeneratedSearchModel(
            model: SearchModel(fields: [
               "id": "integer",
               "name": "string",
               "version": "integer",
            ], relations: [
                "purchaseOrderList": "PurchaseOrder",
                "orderItemList": "OrderItem",
            ]),
            queryFields: [
               "id": "id",
               "name": "name",
               "version": "version",
            ]),
        "PurchaseOrder": GeneratedSearchModel(
            model: SearchModel(fields: [
               "id": "integer",
               "tenant": "integer",
               "contact_phone": "string",
               "contactPhone": "string",
               "internal_note": "string",
               "internalNote": "string",
               "create_time": "timestamp",
               "createTime": "timestamp",
               "update_time": "timestamp",
               "updateTime": "timestamp",
               "version": "integer",
            ], relations: [
               "tenant": "Tenant",
                "orderItemList": "OrderItem",
            ]),
            queryFields: [
               "id": "id",
               "tenant": "tenant",
               "contact_phone": "contactPhone",
               "contactPhone": "contactPhone",
               "internal_note": "internalNote",
               "internalNote": "internalNote",
               "create_time": "createTime",
               "createTime": "createTime",
               "update_time": "updateTime",
               "updateTime": "updateTime",
               "version": "version",
            ]),
        "OrderItem": GeneratedSearchModel(
            model: SearchModel(fields: [
               "id": "integer",
               "purchase_order": "integer",
               "purchaseOrder": "integer",
               "tenant": "integer",
               "product_name": "string",
               "productName": "string",
               "unit_price": "decimal",
               "unitPrice": "decimal",
               "create_time": "timestamp",
               "createTime": "timestamp",
               "update_time": "timestamp",
               "updateTime": "timestamp",
               "version": "integer",
            ], relations: [
               "purchase_order": "PurchaseOrder",
               "purchaseOrder": "PurchaseOrder",
               "tenant": "Tenant",
            ]),
            queryFields: [
               "id": "id",
               "purchase_order": "purchaseOrder",
               "purchaseOrder": "purchaseOrder",
               "tenant": "tenant",
               "product_name": "productName",
               "productName": "productName",
               "unit_price": "unitPrice",
               "unitPrice": "unitPrice",
               "create_time": "createTime",
               "createTime": "createTime",
               "update_time": "updateTime",
               "updateTime": "updateTime",
               "version": "version",
            ]),
    ]
}