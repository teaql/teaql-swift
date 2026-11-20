import TeaQLCore

// Generated trusted metadata. Binding and execution remain in the runtime.
enum GeneratedSearchModels {
    static let models: [String: GeneratedSearchModel] = [
        "Platform": GeneratedSearchModel(
            model: SearchModel(fields: [
               "id": "integer",
               "name": "string",
               "base_url": "string",
               "baseUrl": "string",
               "create_time": "timestamp",
               "createTime": "timestamp",
               "update_time": "timestamp",
               "updateTime": "timestamp",
               "version": "integer",
            ], relations: [
                "schoolTypeList": "SchoolType",
                "schoolList": "School",
            ]),
            queryFields: [
               "id": "id",
               "name": "name",
               "base_url": "baseUrl",
               "baseUrl": "baseUrl",
               "create_time": "createTime",
               "createTime": "createTime",
               "update_time": "updateTime",
               "updateTime": "updateTime",
               "version": "version",
            ]),
        "SchoolType": GeneratedSearchModel(
            model: SearchModel(fields: [
               "platform": "integer",
               "id": "integer",
               "name": "string",
               "code": "string",
               "display_order": "decimal",
               "displayOrder": "decimal",
               "version": "integer",
            ], relations: [
               "platform": "Platform",
                "schoolList": "School",
            ]),
            queryFields: [
               "platform": "platform",
               "id": "id",
               "name": "name",
               "code": "code",
               "display_order": "displayOrder",
               "displayOrder": "displayOrder",
               "version": "version",
            ]),
        "School": GeneratedSearchModel(
            model: SearchModel(fields: [
               "id": "integer",
               "platform": "integer",
               "school_type": "integer",
               "schoolType": "integer",
               "name": "string",
               "address": "string",
               "established_date": "date",
               "establishedDate": "date",
               "student_capacity": "integer",
               "studentCapacity": "integer",
               "active": "boolean",
               "create_time": "timestamp",
               "createTime": "timestamp",
               "update_time": "timestamp",
               "updateTime": "timestamp",
               "version": "integer",
            ], relations: [
               "platform": "Platform",
               "school_type": "SchoolType",
               "schoolType": "SchoolType",
            ]),
            queryFields: [
               "id": "id",
               "platform": "platform",
               "school_type": "schoolType",
               "schoolType": "schoolType",
               "name": "name",
               "address": "address",
               "established_date": "establishedDate",
               "establishedDate": "establishedDate",
               "student_capacity": "studentCapacity",
               "studentCapacity": "studentCapacity",
               "active": "active",
               "create_time": "createTime",
               "createTime": "createTime",
               "update_time": "updateTime",
               "updateTime": "updateTime",
               "version": "version",
            ]),
    ]
}