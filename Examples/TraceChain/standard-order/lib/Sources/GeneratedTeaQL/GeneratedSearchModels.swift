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
                "orderStatusList": "OrderStatus",
                "customerList": "Customer",
            ]),
            queryFields: [
               "id": "id",
               "name": "name",
               "version": "version",
            ]),
        "OrderStatus": GeneratedSearchModel(
            model: SearchModel(fields: [
               "platform": "integer",
               "id": "integer",
               "name": "string",
               "code": "string",
               "color": "string",
               "display_order": "integer",
               "displayOrder": "integer",
               "version": "integer",
            ], relations: [
               "platform": "Platform",
                "customerOrderList": "CustomerOrder",
            ]),
            queryFields: [
               "platform": "platform",
               "id": "id",
               "name": "name",
               "code": "code",
               "color": "color",
               "display_order": "displayOrder",
               "displayOrder": "displayOrder",
               "version": "version",
            ]),
        "Customer": GeneratedSearchModel(
            model: SearchModel(fields: [
               "id": "integer",
               "platform": "integer",
               "name": "string",
               "version": "integer",
            ], relations: [
               "platform": "Platform",
                "customerOrderList": "CustomerOrder",
            ]),
            queryFields: [
               "id": "id",
               "platform": "platform",
               "name": "name",
               "version": "version",
            ]),
        "CustomerOrder": GeneratedSearchModel(
            model: SearchModel(fields: [
               "id": "integer",
               "customer": "integer",
               "status": "integer",
               "order_number": "string",
               "orderNumber": "string",
               "order_date": "date",
               "orderDate": "date",
               "total_amount": "decimal",
               "totalAmount": "decimal",
               "version": "integer",
            ], relations: [
               "customer": "Customer",
               "status": "OrderStatus",
                "orderItemList": "OrderItem",
            ]),
            queryFields: [
               "id": "id",
               "customer": "customer",
               "status": "status",
               "order_number": "orderNumber",
               "orderNumber": "orderNumber",
               "order_date": "orderDate",
               "orderDate": "orderDate",
               "total_amount": "totalAmount",
               "totalAmount": "totalAmount",
               "version": "version",
            ]),
        "OrderItem": GeneratedSearchModel(
            model: SearchModel(fields: [
               "id": "integer",
               "customer_order": "integer",
               "customerOrder": "integer",
               "product_name": "string",
               "productName": "string",
               "quantity": "integer",
               "unit_price": "decimal",
               "unitPrice": "decimal",
               "version": "integer",
            ], relations: [
               "customer_order": "CustomerOrder",
               "customerOrder": "CustomerOrder",
            ]),
            queryFields: [
               "id": "id",
               "customer_order": "customerOrder",
               "customerOrder": "customerOrder",
               "product_name": "productName",
               "productName": "productName",
               "quantity": "quantity",
               "unit_price": "unitPrice",
               "unitPrice": "unitPrice",
               "version": "version",
            ]),
    ]
}