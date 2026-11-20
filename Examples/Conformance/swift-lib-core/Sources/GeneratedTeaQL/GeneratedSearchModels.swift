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
                "workItemList": "WorkItem",
            ]),
            queryFields: [
               "id": "id",
               "name": "name",
               "version": "version",
            ]),
        "WorkItem": GeneratedSearchModel(
            model: SearchModel(fields: [
               "id": "integer",
               "title": "string",
               "description": "string",
               "platform": "integer",
               "version": "integer",
            ], relations: [
               "platform": "Platform",
            ]),
            queryFields: [
               "id": "id",
               "title": "title",
               "description": "description",
               "platform": "platform",
               "version": "version",
            ]),
    ]
}