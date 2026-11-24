import TeaQLCore

// Generated trusted metadata. Binding and execution remain in the runtime.
enum GeneratedSearchModels {
    static let models: [String: GeneratedSearchModel] = [
        "Catalog": GeneratedSearchModel(
            model: SearchModel(fields: [
               "id": "integer",
               "name": "string",
               "version": "integer",
            ], relations: [
                "entryList": "Entry",
            ]),
            queryFields: [
               "id": "id",
               "name": "name",
               "version": "version",
            ]),
        "Entry": GeneratedSearchModel(
            model: SearchModel(fields: [
               "id": "integer",
               "catalog": "integer",
               "name": "string",
               "create_time": "timestamp",
               "createTime": "timestamp",
               "update_time": "timestamp",
               "updateTime": "timestamp",
               "version": "integer",
            ], relations: [
               "catalog": "Catalog",
            ]),
            queryFields: [
               "id": "id",
               "catalog": "catalog",
               "name": "name",
               "create_time": "createTime",
               "createTime": "createTime",
               "update_time": "updateTime",
               "updateTime": "updateTime",
               "version": "version",
            ]),
    ]
}