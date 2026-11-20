import TeaQLCore

// Generated trusted metadata. Binding and execution remain in the runtime.
enum GeneratedSearchModels {
    static let models: [String: GeneratedSearchModel] = [
        "CommercePlatform": GeneratedSearchModel(
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
               "order_number": "string",
               "orderNumber": "string",
               "commerce_platform": "integer",
               "commercePlatform": "integer",
               "version": "integer",
            ], relations: [
               "commerce_platform": "CommercePlatform",
               "commercePlatform": "CommercePlatform",
                "orderAttachmentList": "OrderAttachment",
            ]),
            queryFields: [
               "id": "id",
               "order_number": "orderNumber",
               "orderNumber": "orderNumber",
               "commerce_platform": "commercePlatform",
               "commercePlatform": "commercePlatform",
               "version": "version",
            ]),
        "OrderAttachment": GeneratedSearchModel(
            model: SearchModel(fields: [
               "id": "integer",
               "customer_order": "integer",
               "customerOrder": "integer",
               "file_name": "string",
               "fileName": "string",
               "content_type": "string",
               "contentType": "string",
               "content_length": "integer",
               "contentLength": "integer",
               "content_sha256": "string",
               "contentSha256": "string",
               "object_key": "string",
               "objectKey": "string",
               "version": "integer",
            ], relations: [
               "customer_order": "CustomerOrder",
               "customerOrder": "CustomerOrder",
            ]),
            queryFields: [
               "id": "id",
               "customer_order": "customerOrder",
               "customerOrder": "customerOrder",
               "file_name": "fileName",
               "fileName": "fileName",
               "content_type": "contentType",
               "contentType": "contentType",
               "content_length": "contentLength",
               "contentLength": "contentLength",
               "content_sha256": "contentSha256",
               "contentSha256": "contentSha256",
               "object_key": "objectKey",
               "objectKey": "objectKey",
               "version": "version",
            ]),
    ]
}