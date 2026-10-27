import TeaQLBlobReference
import TeaQLCore
import TeaQLSQLite
import Testing

private struct CatalogAuthorization: BlobBindingAuthorization {
  let tenant: String
  let allowed: Bool

  init(_ tenant: String, allowed: Bool = true) {
    self.tenant = tenant
    self.allowed = allowed
  }

  func scope(for actor: UserContext) throws -> String { tenant }
  func authorize(actor: UserContext, target: BlobBindingTarget, previous: BlobRef?,
                 next: BlobRef?, action: String) async throws -> Bool { allowed }
}

private func catalogFixture() async throws -> (UserContext, SQLiteDataService, EntityDescriptor) {
  let asset = EntityDescriptor(name: "Asset", table: "catalog_asset", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "name", type: .string),
  ])
  let service = try SQLiteDataService(path: ":memory:")
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 })
  try await context.ensureSchema(RuntimeModule(name: "catalog-test", entities: [asset]))
  let catalog = SQLiteBlobCatalog()
  try await context.executeGraphSave(comment: "install blob catalog") { graph, session in
    try await catalog.installSchema(graph, session: session)
    try await catalog.validateSchema(graph, session: session)
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("""
        INSERT INTO teaql_blob_catalog
        (key, scope, object_key, content_version, file_name, content_type, size_bytes, status)
        VALUES ('blob_abc', 'tenant-a', 'objects/abc', 'v1', 'report.pdf', 'application/pdf', 7, 'available')
        """, parameters: [])
    }
  }
  return (context, service, asset)
}

private func catalogCounts(_ context: UserContext) async throws -> (Int, Int) {
  try await context.executeGraphSave(comment: "inspect catalog") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      let assets = try await sql.query("SELECT id FROM catalog_asset", parameters: [])
      let bindings = try await sql.query("SELECT key FROM teaql_blob_binding", parameters: [])
      return (assets.count, bindings.count)
    }
  }
}

private func insertAsset(_ actor: UserContext, _ session: GraphMutationSession,
                         _ asset: EntityDescriptor, id: Int64) async throws {
  _ = try await actor.execute(Mutation(kind: .create, entity: asset,
    values: ["id": .int(id), "name": .string("document")], auditReason: session.intent.comment))
}

@Test
func swiftCatalogBindingSharesNativeGraphCommitRollback() async throws {
  let (context, _, asset) = try await catalogFixture()
  let catalog = SQLiteBlobCatalog(), reference = try BlobRef("blob_abc")
  let allowed = CatalogAuthorization("tenant-a")
  let target = BlobBindingTarget(entity: "Asset", entityID: "1", field: "file")
  try await context.executeGraphSave(comment: "save asset") { actor, session in
    try await insertAsset(actor, session, asset, id: 1)
    let version = try await catalog.bind(actor, session: session,
      change: BlobBindingChange(target: target, next: reference,
        expectedVersion: 0, nextVersion: 1, action: "Create"), authorization: allowed)
    #expect(version == 1)
  }
  #expect(try await catalogCounts(context) == (1, 1))

  do {
    try await context.executeGraphSave(comment: "rollback asset") { actor, session in
      try await insertAsset(actor, session, asset, id: 2)
      _ = try await catalog.bind(actor, session: session,
        change: BlobBindingChange(target: BlobBindingTarget(entity: "Asset", entityID: "2", field: "file"),
          next: reference, expectedVersion: 0, nextVersion: 1, action: "Create"), authorization: allowed)
      throw TeaQLError.execution("abort graph")
    }
    Issue.record("graph should roll back")
  } catch { #expect(error as? TeaQLError == .execution("abort graph")) }
  #expect(try await catalogCounts(context) == (1, 1))

  do {
    try await context.executeGraphSave(comment: "revoked binding") { actor, session in
      try await insertAsset(actor, session, asset, id: 3)
      do {
        _ = try await catalog.bind(actor, session: session,
          change: BlobBindingChange(target: BlobBindingTarget(entity: "Asset", entityID: "3", field: "file"),
            next: reference, expectedVersion: 0, nextVersion: 1, action: "Create"),
          authorization: CatalogAuthorization("tenant-a", allowed: false))
      } catch { #expect(error as? TeaQLError == .execution("BLOB_BIND_DENIED")) }
    }
    Issue.record("caught denial should poison the graph")
  } catch { #expect(error as? TeaQLError == .execution("GRAPH_TRANSACTION_ROLLBACK_ONLY")) }
  #expect(try await catalogCounts(context) == (1, 1))
}

@Test
func swiftCatalogVersionScopeAndTombstoneAreAuthoritative() async throws {
  let (context, service, _) = try await catalogFixture()
  let catalog = SQLiteBlobCatalog(), reference = try BlobRef("blob_abc")
  let target = BlobBindingTarget(entity: "Asset", entityID: "1", field: "file")
  let allowed = CatalogAuthorization("tenant-a")
  try await context.executeGraphSave(comment: "bind") { actor, session in
    _ = try await catalog.bind(actor, session: session,
      change: BlobBindingChange(target: target, next: reference,
        expectedVersion: 0, nextVersion: 1, action: "Create"), authorization: allowed)
  }
  for (change, auth) in [
    (BlobBindingChange(target: target, next: reference,
      expectedVersion: 0, nextVersion: 2, action: "Update"), allowed),
    (BlobBindingChange(target: target, next: reference,
      expectedVersion: 1, nextVersion: 2, action: "Update"), CatalogAuthorization("tenant-b")),
    (BlobBindingChange(target: BlobBindingTarget(entity: "Asset", entityID: "01", field: "file"),
      next: reference, expectedVersion: 1, nextVersion: 2, action: "Update"), allowed),
  ] {
    do {
      try await context.executeGraphSave(comment: "reject binding") { actor, session in
        _ = try await catalog.bind(actor, session: session, change: change, authorization: auth)
      }
      Issue.record("invalid binding was accepted")
    } catch { #expect(error as? TeaQLError != nil) }
  }
  let other = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 })
  do {
    try await context.executeGraphSave(comment: "foreign actor") { actor, session in
      _ = try await catalog.bind(other, session: session,
        change: BlobBindingChange(target: target, next: reference,
          expectedVersion: 1, nextVersion: 2, action: "Update"), authorization: allowed)
    }
    Issue.record("foreign actor was accepted")
  } catch { #expect(error as? TeaQLError != nil) }
  try await context.executeGraphSave(comment: "clear and rebind") { actor, session in
    let cleared = try await catalog.bind(actor, session: session,
      change: BlobBindingChange(target: target, next: nil,
        expectedVersion: 1, nextVersion: 2, action: "Delete"), authorization: allowed)
    #expect(cleared == 2)
    let rebound = try await catalog.bind(actor, session: session,
      change: BlobBindingChange(target: target, next: reference,
        expectedVersion: 2, nextVersion: 3, action: "Update"), authorization: allowed)
    #expect(rebound == 3)
  }
  try await context.executeGraphSave(comment: "inspect binding") { actor, session in
    try await actor.withPhysicalSQL(session) { sql in
      let rows = try await sql.query("SELECT key,version FROM teaql_blob_binding", parameters: [])
      #expect(rows.count == 1)
      #expect(rows.first?["key"]?.stringValue == reference.key)
      #expect(rows.first?["version"]?.int64Value == 3)
    }
  }
}

@Test
func swiftCatalogRejectsLegacyNonnullableKeySchema() async throws {
  let (context, _, _) = try await catalogFixture()
  let catalog = SQLiteBlobCatalog()
  do {
    try await context.executeGraphSave(comment: "inspect legacy schema") { actor, session in
      try await actor.withPhysicalSQL(session) { sql in
        _ = try await sql.execute("DROP TABLE teaql_blob_binding", parameters: [])
        _ = try await sql.execute("""
          CREATE TABLE teaql_blob_binding
          (scope TEXT, entity TEXT, entity_id TEXT, field TEXT, key TEXT NOT NULL, version BIGINT NOT NULL)
          """, parameters: [])
      }
      try await catalog.validateSchema(actor, session: session)
    }
    Issue.record("legacy schema was accepted")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_SCHEMA_MISSING")) }
}
