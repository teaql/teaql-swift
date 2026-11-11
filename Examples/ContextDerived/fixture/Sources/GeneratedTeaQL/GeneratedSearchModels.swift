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
               "born_at": "timestamp",
               "bornAt": "timestamp",
               "touched_at": "timestamp",
               "touchedAt": "timestamp",
               "source_ip": "string",
               "sourceIp": "string",
               "last_ip": "string",
               "lastIp": "string",
               "opened_by": "string",
               "openedBy": "string",
               "changed_by": "string",
               "changedBy": "string",
               "guarded_token": "string",
               "guardedToken": "string",
               "version": "integer",
            ], relations: [
               "catalog": "Catalog",
            ]),
            queryFields: [
               "id": "id",
               "catalog": "catalog",
               "name": "name",
               "born_at": "bornAt",
               "bornAt": "bornAt",
               "touched_at": "touchedAt",
               "touchedAt": "touchedAt",
               "source_ip": "sourceIp",
               "sourceIp": "sourceIp",
               "last_ip": "lastIp",
               "lastIp": "lastIp",
               "opened_by": "openedBy",
               "openedBy": "openedBy",
               "changed_by": "changedBy",
               "changedBy": "changedBy",
               "guarded_token": "guardedToken",
               "guardedToken": "guardedToken",
               "version": "version",
            ]),
    ]
}