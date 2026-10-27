import Crypto
import Foundation
import TeaQLCore

public struct SubmittedDocumentCommand: Sendable, CustomStringConvertible {
  public let businessID: String
  public let documentToken: String
  public let commandID: String
  public let body: TeaQLValue
  public var description: String { "SubmittedDocumentCommand[redacted]" }

  public init(businessID: String, documentToken: String, commandID: String, body: TeaQLValue) {
    self.businessID = businessID; self.documentToken = documentToken
    self.commandID = commandID; self.body = body
  }
}

public struct DocumentCommandReceipt: Sendable, Equatable, CustomStringConvertible {
  public let previousRevision: Int64
  public let newRevision: Int64
  public let response: String
  public var description: String { "DocumentCommandReceipt[redacted]" }

  public init(previousRevision: Int64, newRevision: Int64, response: String) {
    self.previousRevision = previousRevision; self.newRevision = newRevision
    self.response = response
  }
}

/// Explicit SQLite schema and durable receipts on the graph's physical SQL owner.
public struct SQLiteDocumentCommandJournal: Sendable {
  public init() {}

  private func failure(_ code: String) -> ReferenceError { ReferenceError(code) }

  private func text(_ value: String, maximum: Int) -> Bool {
    !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
      value.utf8.count <= maximum && value.unicodeScalars.allSatisfy {
        !CharacterSet.controlCharacters.contains($0)
      }
  }

  private func validate(_ value: TeaQLValue, depth: Int, remaining: inout Int) throws {
    remaining -= 1
    guard remaining >= 0, depth <= 64 else { throw failure("DOCUMENT_COMMAND_INVALID") }
    switch value {
    case .null, .bool: break
    case .int(let item):
      guard (-9_007_199_254_740_991...9_007_199_254_740_991).contains(item) else {
        throw failure("DOCUMENT_COMMAND_INVALID")
      }
    case .uint(let item):
      guard item <= 9_007_199_254_740_991 else { throw failure("DOCUMENT_COMMAND_INVALID") }
    case .string(let item):
      guard item.utf8.count <= 256_000 else { throw failure("DOCUMENT_COMMAND_INVALID") }
    case .array(let children):
      for child in children { try validate(child, depth: depth + 1, remaining: &remaining) }
    case .object(let entries):
      for (key, child) in entries {
        guard text(key, maximum: 16_384), !["__proto__", "constructor", "prototype"].contains(key) else {
          throw failure("DOCUMENT_COMMAND_INVALID")
        }
        try validate(child, depth: depth + 1, remaining: &remaining)
      }
    default: throw failure("DOCUMENT_COMMAND_INVALID")
    }
  }

  private func encoded(_ value: TeaQLValue) throws -> Data {
    var remaining = 100_000
    guard case .object = value else { throw failure("DOCUMENT_COMMAND_INVALID") }
    try validate(value, depth: 0, remaining: &remaining)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(value)
    guard bytes.count <= 256_000 else { throw failure("DOCUMENT_COMMAND_INVALID") }
    return bytes
  }

  func validatedBody(_ value: TeaQLValue) throws -> TeaQLValue {
    try JSONDecoder().decode(TeaQLValue.self, from: encoded(value))
  }

  private func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func strings(_ values: [String]) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(values)
  }

  private func prepared(_ command: SubmittedDocumentCommand) throws -> (String, SubmittedDocumentCommand) {
    guard text(command.businessID, maximum: 16_384),
      text(command.documentToken, maximum: 256_000),
      text(command.commandID, maximum: 256) else { throw failure("DOCUMENT_COMMAND_INVALID") }
    let body = try encoded(command.body)
    let frozen = try JSONDecoder().decode(TeaQLValue.self, from: body)
    let total = try strings([command.businessID, command.documentToken,
      command.commandID, String(decoding: body, as: UTF8.self)])
    guard total.count <= 256_000 else { throw failure("DOCUMENT_COMMAND_INVALID") }
    return (hash(total), SubmittedDocumentCommand(businessID: command.businessID,
      documentToken: command.documentToken, commandID: command.commandID, body: frozen))
  }

  private func scopeHash(_ scope: ReferenceDocumentScope) throws -> String {
    try ReferenceWire.scope(scope)
    return hash(try strings([scope.documentID, scope.purpose, scope.aggregateType,
      String(scope.aggregateID)]))
  }

  private func actorHash(_ principal: TrustedReferencePrincipal) throws -> String {
    try ReferenceWire.principal(principal)
    return hash(try strings([principal.authenticationRealm, principal.subject,
      principal.domainRootType, String(principal.domainRootID)]))
  }

  private func checked(_ receipt: DocumentCommandReceipt) throws -> DocumentCommandReceipt {
    guard receipt.previousRevision >= 0, receipt.newRevision >= receipt.previousRevision,
      text(receipt.response, maximum: 256_000) else { throw failure("DOCUMENT_COMMAND_INVALID") }
    return receipt
  }

  public func installSchema(_ actor: UserContext) async throws {
    try await actor.executeGraphSave(comment: "install document command receipts") { graph, session in
      try await graph.withPhysicalSQL(session) { sql in
        _ = try await sql.execute("""
          CREATE TABLE IF NOT EXISTS teaql_document_command_receipt (
            scope_hash TEXT NOT NULL, actor_hash TEXT NOT NULL,
            command_id TEXT NOT NULL, request_hash TEXT NOT NULL,
            previous_revision BIGINT NOT NULL, new_revision BIGINT NOT NULL,
            response TEXT NOT NULL,
            PRIMARY KEY (scope_hash,actor_hash,command_id))
          """, parameters: [])
      }
    }
  }

  public func validateSchema(_ actor: UserContext) async throws {
    try await actor.executeGraphSave(comment: "validate document command receipts") { graph, session in
      try await graph.withPhysicalSQL(session) { sql in
        let rows = try await sql.query("PRAGMA table_info(teaql_document_command_receipt)", parameters: [])
        let names = ["scope_hash", "actor_hash", "command_id", "request_hash",
          "previous_revision", "new_revision", "response"]
        guard rows.count == names.count else { throw failure("DOCUMENT_SCHEMA_MISSING") }
        for (index, name) in names.enumerated() {
          guard rows[index]["name"]?.stringValue == name,
            rows[index]["notnull"]?.int64Value == 1,
            rows[index]["pk"]?.int64Value == Int64(index < 3 ? index + 1 : 0)
          else { throw failure("DOCUMENT_SCHEMA_MISSING") }
        }
      }
    }
  }

  public func applyInGraph(
    _ graph: UserContext, session: GraphMutationSession,
    scope: ReferenceDocumentScope, command: SubmittedDocumentCommand,
    authority: @escaping @Sendable (UserContext, ReferenceDocumentScope, any GraphPhysicalSQLLease)
      async throws -> TrustedReferencePrincipal,
    mutate: @escaping @Sendable (any GraphPhysicalSQLLease, SubmittedDocumentCommand)
      async throws -> DocumentCommandReceipt
  ) async throws -> (DocumentCommandReceipt, Bool) {
    let scopeKey = try scopeHash(scope)
    let (requestHash, frozen) = try prepared(command)
    return try await graph.withPhysicalSQL(session) { sql in
      func currentActor() async throws -> String {
        do { return try actorHash(await authority(graph, scope, sql)) }
        catch { throw failure("DOCUMENT_AUTHORIZATION_REQUIRED") }
      }
      let actorKey = try await currentActor()
      let identity: [TeaQLValue] = [.string(scopeKey), .string(actorKey), .string(command.commandID)]
      let rows: [TeaQLRecord]
      do {
        rows = try await sql.query("""
          SELECT request_hash,previous_revision,new_revision,response
          FROM teaql_document_command_receipt
          WHERE scope_hash=? AND actor_hash=? AND command_id=?
          """, parameters: identity)
      } catch { throw failure("DOCUMENT_CATALOG_FAILED") }
      guard rows.count <= 1 else { throw failure("DOCUMENT_CATALOG_FAILED") }
      if let row = rows.first {
        guard row["request_hash"]?.stringValue == requestHash else {
          throw failure("DOCUMENT_REPLAY_CONFLICT")
        }
        guard let previous = row["previous_revision"]?.int64Value,
          let next = row["new_revision"]?.int64Value,
          let response = row["response"]?.stringValue,
          let receipt = try? checked(DocumentCommandReceipt(previousRevision: previous,
            newRevision: next, response: response)) else { throw failure("DOCUMENT_CATALOG_FAILED") }
        guard try await currentActor() == actorKey else { throw failure("DOCUMENT_AUTHORIZATION_REQUIRED") }
        return (receipt, true)
      }
      let receipt = try checked(await mutate(sql, frozen))
      guard try prepared(frozen).0 == requestHash,
        try prepared(command).0 == requestHash else { throw failure("DOCUMENT_COMMAND_INVALID") }
      guard try await currentActor() == actorKey else { throw failure("DOCUMENT_AUTHORIZATION_REQUIRED") }
      do {
        let affected = try await sql.execute("""
          INSERT INTO teaql_document_command_receipt
          (scope_hash,actor_hash,command_id,request_hash,previous_revision,new_revision,response)
          VALUES (?,?,?,?,?,?,?)
          """, parameters: identity + [.string(requestHash), .int(receipt.previousRevision),
            .int(receipt.newRevision), .string(receipt.response)])
        guard affected == 1 else { throw failure("DOCUMENT_CATALOG_FAILED") }
      } catch { throw failure("DOCUMENT_CATALOG_FAILED") }
      return (receipt, false)
    }
  }
}
