import TeaQLCore

/// Catalog changes for a modeled Blob field belong to the graph's SQLite owner.
/// The participant trusts only the provider's before/after row images, never a
/// client-supplied binding version or a mutation's claimed old value.
struct SQLiteBlobMutationParticipant: BlobMutationParticipant {
  let catalog: SQLiteBlobCatalog
  let authorization: any BlobBindingAuthorization

  init(catalog: SQLiteBlobCatalog, authorization: any BlobBindingAuthorization) {
    self.catalog = catalog
    self.authorization = authorization
  }

  func apply(context: UserContext, session: GraphMutationSession, mutation: Mutation,
                    previous: TeaQLRecord?, persisted: TeaQLRecord) async throws {
    guard let idProperty = mutation.entity.idProperty,
          let identifier = Self.entityID(persisted[idProperty.name]) else {
      throw TeaQLError.execution("BLOB_REFERENCE_INVALID")
    }
    let scope: String
    do { scope = try authorization.scope(for: context) }
    catch { throw TeaQLError.execution("BLOB_BIND_DENIED") }
    for property in mutation.entity.properties where property.type == .blobRef || property.blobSpec != nil {
      guard property.type == .blobRef, let spec = property.blobSpec,
            spec.entity == mutation.entity.name, spec.field == property.name,
            spec.nullable == property.nullable else {
        throw TeaQLError.execution("BLOB_CAPABILITY_MISSING")
      }
      let before = try previous.map {
        try Self.reference($0[property.name], nullable: property.nullable)
      } ?? nil
      let after = mutation.kind == .delete ? nil :
        try Self.reference(persisted[property.name], nullable: property.nullable)
      let target = BlobBindingTarget(entity: mutation.entity.name,
        entityID: identifier, field: property.name)
      let binding = try await context.withPhysicalSQL(session) { sql in
        let rows = try await sql.query("""
          SELECT b.key,b.version,c.status FROM teaql_blob_binding AS b
          LEFT JOIN teaql_blob_catalog AS c ON c.key = b.key AND c.scope = b.scope
          WHERE b.scope = ? AND b.entity = ? AND b.entity_id = ? AND b.field = ?
          """, parameters: [.string(scope), .string(target.entity),
            .string(target.entityID), .string(target.field)])
        guard rows.count <= 1 else { throw TeaQLError.execution("BLOB_CATALOG_FAILED") }
        return rows.first
      }
      let expectedVersion: Int64
      if previous == nil {
        guard mutation.kind == .create, binding == nil else {
          throw TeaQLError.execution("BLOB_BIND_DENIED")
        }
        expectedVersion = 0
      } else {
        guard mutation.kind != .create, let binding,
              let version = binding["version"]?.int64Value, version > 0,
              try Self.catalogReference(binding["key"]) == before,
              before == nil || binding["status"]?.stringValue == "available" else {
          throw TeaQLError.execution("BLOB_BIND_DENIED")
        }
        expectedVersion = version
      }
      let action: String = mutation.kind == .create ? "Create" :
        mutation.kind == .delete ? "Delete" : "Update"
      if previous != nil && before == after && mutation.kind != .delete {
        let allowed: Bool
        do { allowed = try await authorization.authorize(actor: context, target: target,
          previous: before, next: after, action: action) }
        catch { throw TeaQLError.execution("BLOB_BIND_DENIED") }
        guard allowed else { throw TeaQLError.execution("BLOB_BIND_DENIED") }
        continue
      }
      guard expectedVersion < Int64.max else { throw TeaQLError.execution("BLOB_BIND_DENIED") }
      _ = try await catalog.bind(context, session: session,
        change: BlobBindingChange(target: target, next: after,
          expectedVersion: expectedVersion, nextVersion: expectedVersion + 1,
          action: action), authorization: authorization)
    }
  }

  private static func entityID(_ value: TeaQLValue?) -> String? {
    guard let value else { return nil }
    if let integer = value.int64Value, integer > 0 { return String(integer) }
    if let text = value.stringValue, let integer = UInt64(text), integer > 0,
       String(integer) == text { return text }
    return nil
  }

  private static func reference(_ value: TeaQLValue?, nullable: Bool) throws -> BlobRef? {
    switch value {
    case .blobRef(let reference): return reference
    case .null where nullable: return nil
    case nil where nullable: return nil
    default: throw TeaQLError.execution("BLOB_REFERENCE_INVALID")
    }
  }

  private static func catalogReference(_ value: TeaQLValue?) throws -> BlobRef? {
    switch value {
    case .string(let key): return try BlobRef(sqlText: key)
    case .null: return nil
    default: throw TeaQLError.execution("BLOB_CATALOG_FAILED")
    }
  }
}
