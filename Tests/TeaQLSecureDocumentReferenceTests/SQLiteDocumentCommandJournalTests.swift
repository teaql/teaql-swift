import Foundation
import TeaQLCore
import TeaQLSecureDocumentReference
import TeaQLSQLite
import Testing

private actor JournalMutationCount {
  var value = 0
  func increment() { value += 1 }
  func current() -> Int { value }
}

private func journalFixture() async throws -> UserContext {
  let database = try SQLiteDataService(path: ":memory:")
  let context = UserContext(queryExecutor: database, mutationExecutor: database,
    requestPolicy: RequestPolicy { $0 })
  try await context.executeGraphSave(comment: "install document fixture") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("""
        CREATE TABLE document_order(id INTEGER PRIMARY KEY,version INTEGER NOT NULL,quantity INTEGER NOT NULL)
        """, parameters: [])
      _ = try await sql.execute("""
        CREATE TABLE document_permission(subject TEXT PRIMARY KEY,can_edit INTEGER NOT NULL)
        """, parameters: [])
      _ = try await sql.execute("INSERT INTO document_order VALUES(10,1,1)", parameters: [])
      _ = try await sql.execute("INSERT INTO document_permission VALUES('alice',1)", parameters: [])
    }
  }
  return context
}

private func journalState(_ context: UserContext) async throws -> (Int64, Int64, Int) {
  try await context.executeGraphSave(comment: "inspect document command") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      let row = try await sql.query("SELECT version,quantity FROM document_order WHERE id=10", parameters: [])
      let receipts = try await sql.query("SELECT command_id FROM teaql_document_command_receipt", parameters: [])
      return (row[0]["version"]!.int64Value!, row[0]["quantity"]!.int64Value!, receipts.count)
    }
  }
}

@Test
func swiftSQLiteDocumentJournalCommitsAndReplaysWithCurrentAuthority() async throws {
  let context = try await journalFixture()
  let journal = SQLiteDocumentCommandJournal()
  try await journal.installSchema(context)
  try await journal.validateSchema(context)
  let principal = TrustedReferencePrincipal(authenticationRealm: "oidc", subject: "alice",
    domainRootType: "Merchant", domainRootID: 7)
  let mutations = JournalMutationCount()
  let command = SubmittedDocumentCommand(businessID: "ORD-10", documentToken: "tqd2.fixture",
    commandID: "command-1", body: .object(["quantity": .int(3), "note": .string("ok")]))

  func apply(_ submitted: SubmittedDocumentCommand, expectedVersion: Int64 = 1)
    async throws -> (DocumentCommandReceipt, Bool) {
    let scope = ReferenceDocumentScope(documentID: "edit-10", purpose: "edit-order",
      aggregateType: "Order", aggregateID: 10, aggregateRevision: expectedVersion)
    return try await context.executeGraphSave(comment: "accept protected document command") { graph, session in
      try await journal.applyInGraph(graph, session: session, scope: scope, command: submitted,
        authority: { _, _, sql in
          let rows = try await sql.query("SELECT can_edit FROM document_permission WHERE subject=?",
            parameters: [.string(principal.subject)])
          guard rows.count == 1, rows[0]["can_edit"]?.int64Value == 1 else {
            throw ReferenceError("revoked")
          }
          return principal
        }, mutate: { sql, frozen in
          await mutations.increment()
          guard frozen.body == .object(["quantity": .int(3), "note": .string("ok")]) else {
            throw ReferenceError("invalid quantity")
          }
          let changed = try await sql.execute("""
            UPDATE document_order SET quantity=?,version=version+1 WHERE id=? AND version=?
            """, parameters: [.int(3), .int(10), .int(expectedVersion)])
          guard changed == 1 else { throw ReferenceError("stale order") }
          return DocumentCommandReceipt(previousRevision: expectedVersion,
            newRevision: expectedVersion + 1, response: "tqd2.accepted")
        })
    }
  }

  let first = try await apply(command)
  #expect(!first.1 && first.0.newRevision == 2)
  #expect(try await journalState(context) == (2, 3, 1))
  #expect(!first.0.description.contains(first.0.response))
  let replay = try await apply(command)
  #expect(replay.1 && replay.0 == first.0)
  #expect(await mutations.current() == 1)
  do {
    _ = try await apply(SubmittedDocumentCommand(businessID: command.businessID,
      documentToken: command.documentToken, commandID: command.commandID,
      body: .object(["quantity": .int(4), "note": .string("ok")])))
    Issue.record("changed command replayed")
  } catch { #expect((error as? ReferenceError)?.code == "DOCUMENT_REPLAY_CONFLICT") }
  try await context.executeGraphSave(comment: "revoke document permission") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("UPDATE document_permission SET can_edit=0 WHERE subject='alice'", parameters: [])
    }
  }
  do { _ = try await apply(command); Issue.record("revoked command replayed") }
  catch { #expect((error as? ReferenceError)?.code == "DOCUMENT_AUTHORIZATION_REQUIRED") }
  try await context.executeGraphSave(comment: "restore document permission") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("UPDATE document_permission SET can_edit=1 WHERE subject='alice'", parameters: [])
      _ = try await sql.execute("""
        CREATE TRIGGER reject_document_receipt BEFORE INSERT ON teaql_document_command_receipt
        WHEN NEW.command_id='command-trigger' BEGIN SELECT RAISE(ABORT, 'receipt rejected'); END
        """, parameters: [])
    }
  }
  do {
    _ = try await apply(SubmittedDocumentCommand(businessID: command.businessID,
      documentToken: command.documentToken, commandID: "command-trigger", body: command.body),
      expectedVersion: 2)
    Issue.record("receipt failure committed business mutation")
  } catch { #expect((error as? ReferenceError)?.code == "DOCUMENT_CATALOG_FAILED") }
  #expect(try await journalState(context) == (2, 3, 1))
}

@Test
func swiftSQLiteDocumentJournalRejectsMissingReplayKey() async throws {
  let context = try await journalFixture()
  try await context.executeGraphSave(comment: "install invalid document receipt schema") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("""
        CREATE TABLE teaql_document_command_receipt (
          scope_hash TEXT NOT NULL,actor_hash TEXT NOT NULL,command_id TEXT NOT NULL,
          request_hash TEXT NOT NULL,previous_revision BIGINT NOT NULL,
          new_revision BIGINT NOT NULL,response TEXT NOT NULL)
        """, parameters: [])
    }
  }
  let journal = SQLiteDocumentCommandJournal()
  try await journal.installSchema(context)
  do { try await journal.validateSchema(context); Issue.record("missing replay key accepted") }
  catch { #expect((error as? ReferenceError)?.code == "DOCUMENT_SCHEMA_MISSING") }
}
