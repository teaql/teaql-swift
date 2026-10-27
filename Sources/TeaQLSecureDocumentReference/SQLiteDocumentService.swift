import Foundation
import TeaQLCore

public struct DocumentOpenRequest: Sendable {
  public let aggregateType: String
  public let businessID: String
  public let purpose: String
  public let lifetimeSeconds: Int64
  public init(aggregateType: String, businessID: String, purpose: String, lifetimeSeconds: Int64) {
    self.aggregateType = aggregateType; self.businessID = businessID
    self.purpose = purpose; self.lifetimeSeconds = lifetimeSeconds
  }
}

public struct DocumentAcceptRequest: Sendable {
  public let aggregateType: String
  public let purpose: String
  public let submitted: SubmittedDocumentCommand
  public init(aggregateType: String, purpose: String, submitted: SubmittedDocumentCommand) {
    self.aggregateType = aggregateType; self.purpose = purpose; self.submitted = submitted
  }
}

public struct ContextualDocument: Sendable, CustomStringConvertible {
  public let businessID: String
  public let documentToken: String
  public let body: TeaQLValue
  public var description: String { "ContextualDocument[redacted]" }
}

public struct AcceptedDocument: Sendable, CustomStringConvertible {
  public let document: ContextualDocument
  public let previousRevision: Int64
  public let newRevision: Int64
  public let replayed: Bool
  public var description: String { "AcceptedDocument[redacted]" }
}

public struct CurrentBoundDocument: Sendable {
  public let document: BoundDocumentSnapshot
  public let body: TeaQLValue
  public let lifetimeSeconds: Int64
  public init(document: BoundDocumentSnapshot, body: TeaQLValue, lifetimeSeconds: Int64) {
    self.document = document; self.body = body; self.lifetimeSeconds = lifetimeSeconds
  }
}

/// Application-owned current projection, SQL permission and allowed model mutation plan.
public protocol SQLiteContextBoundDocumentHost: Sendable {
  func principal(context: UserContext) async throws -> TrustedReferencePrincipal
  func authorize(context: UserContext, principal: TrustedReferencePrincipal,
                 scope: ReferenceDocumentScope, sql: any GraphPhysicalSQLLease) async throws
  func load(context: UserContext, businessID: String,
            sql: any GraphPhysicalSQLLease) async throws -> CurrentBoundDocument
  func apply(context: UserContext, issued: BoundDocumentSnapshot,
             submitted: SubmittedDocumentCommand, sql: any GraphPhysicalSQLLease) async throws
  func present(context: UserContext, document: ContextualDocument) async throws
}

/// SQLite tqd2 open and durable accept, bound to an application-owned graph context.
public struct SQLiteContextBoundDocumentService: Sendable {
  private struct EncodedDocument: Codable {
    let businessID: String
    let documentToken: String
    let body: TeaQLValue
  }

  private let actor: UserContext
  private let module: SecureDocumentReferenceModule
  private let journal: SQLiteDocumentCommandJournal
  private let host: any SQLiteContextBoundDocumentHost

  public init(actor: UserContext, module: SecureDocumentReferenceModule,
              journal: SQLiteDocumentCommandJournal, host: any SQLiteContextBoundDocumentHost) {
    self.actor = actor; self.module = module; self.journal = journal; self.host = host
  }

  private func failure(_ code: String) -> ReferenceError { ReferenceError(code) }

  private func validText(_ value: String) -> Bool {
    !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
      value.utf8.count <= 16_384 && value.unicodeScalars.allSatisfy {
        !CharacterSet.controlCharacters.contains($0)
      }
  }

  private func principal(_ context: UserContext) async throws -> TrustedReferencePrincipal {
    do {
      let value = try await host.principal(context: context)
      try ReferenceWire.principal(value)
      return value
    } catch { throw failure("DOCUMENT_AUTHORIZATION_REQUIRED") }
  }

  private func fingerprint(_ document: BoundDocumentSnapshot) throws -> [UInt8] {
    try DocumentWire.encodeBound(document, actor: Array(repeating: 0, count: 32),
      issued: 0, expires: 1)
  }

  private func validate(_ current: CurrentBoundDocument, businessID: String,
                        aggregateType: String, purpose: String) throws -> TeaQLValue {
    guard current.document.snapshot.businessID == businessID,
      current.document.snapshot.scope.aggregateType == aggregateType,
      current.document.snapshot.scope.purpose == purpose,
      current.lifetimeSeconds > 0 else { throw failure("DOCUMENT_PROJECTION_VIOLATION") }
    do {
      _ = try fingerprint(current.document)
      return try journal.validatedBody(current.body)
    } catch { throw failure("DOCUMENT_PROJECTION_VIOLATION") }
  }

  public func open(_ request: DocumentOpenRequest) async throws -> ContextualDocument {
    guard validText(request.aggregateType), validText(request.businessID),
      validText(request.purpose), request.lifetimeSeconds > 0 else {
      throw failure("DOCUMENT_COMMAND_INVALID")
    }
    let initial = try await principal(actor)
    let result = try await actor.executeGraphSave(comment: "open protected document") { graph, session in
      try await graph.withPhysicalSQL(session) { sql in
        let current = try await host.load(context: graph, businessID: request.businessID, sql: sql)
        let body = try validate(current, businessID: request.businessID,
          aggregateType: request.aggregateType, purpose: request.purpose)
        guard try await principal(graph) == initial else { throw failure("DOCUMENT_AUTHORIZATION_REQUIRED") }
        do {
          try await host.authorize(context: graph, principal: initial,
            scope: current.document.snapshot.scope, sql: sql)
        } catch { throw failure("DOCUMENT_AUTHORIZATION_REQUIRED") }
        guard try await principal(graph) == initial else { throw failure("DOCUMENT_AUTHORIZATION_REQUIRED") }
        let token = try module.runtime.issueBoundDocumentSnapshot(initial, document: current.document,
          lifetimeSeconds: min(request.lifetimeSeconds, current.lifetimeSeconds))
        return ContextualDocument(businessID: request.businessID, documentToken: token, body: body)
      }
    }
    try await host.present(context: actor, document: result)
    return result
  }

  public func accept(_ request: DocumentAcceptRequest) async throws -> AcceptedDocument {
    guard validText(request.aggregateType), validText(request.purpose),
      validText(request.submitted.businessID), validText(request.submitted.commandID) else {
      throw failure("DOCUMENT_COMMAND_INVALID")
    }
    let initial = try await principal(actor)
    let issued = try module.runtime.consumeBoundDocumentSnapshot(initial,
      token: request.submitted.documentToken, aggregateType: request.aggregateType,
      purpose: request.purpose).document
    guard issued.snapshot.businessID == request.submitted.businessID else {
      throw failure("DOCUMENT_PROJECTION_VIOLATION")
    }
    let scope = issued.snapshot.scope
    let (receipt, replayed) = try await actor.executeGraphSave(
      comment: "accept protected document command") { graph, session in
      try await journal.applyInGraph(graph, session: session, scope: scope,
        command: request.submitted, authority: { current, expected, sql in
          let now = try await principal(current)
          guard now == initial, expected == scope else { throw failure("DOCUMENT_AUTHORIZATION_REQUIRED") }
          try await host.authorize(context: current, principal: now, scope: expected, sql: sql)
          return now
        }, mutate: { sql, frozen in
          let before = try await host.load(context: graph, businessID: frozen.businessID, sql: sql)
          _ = try validate(before, businessID: frozen.businessID,
            aggregateType: request.aggregateType, purpose: request.purpose)
          guard try fingerprint(before.document) == fingerprint(issued) else {
            throw failure("DOCUMENT_REVISION_CONFLICT")
          }
          try await host.apply(context: graph, issued: issued, submitted: frozen, sql: sql)
          let after = try await host.load(context: graph, businessID: frozen.businessID, sql: sql)
          let body = try validate(after, businessID: frozen.businessID,
            aggregateType: request.aggregateType, purpose: request.purpose)
          let next = after.document.snapshot.scope
          guard next.documentID == scope.documentID, next.aggregateID == scope.aggregateID,
            next.aggregateType == scope.aggregateType, next.purpose == scope.purpose,
            next.aggregateRevision >= scope.aggregateRevision else {
            throw failure("DOCUMENT_PROJECTION_VIOLATION")
          }
          do { try await host.authorize(context: graph, principal: initial, scope: next, sql: sql) }
          catch { throw failure("DOCUMENT_AUTHORIZATION_REQUIRED") }
          let token = try module.runtime.issueBoundDocumentSnapshot(initial,
            document: after.document, lifetimeSeconds: after.lifetimeSeconds)
          let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
          let response = try encoder.encode(EncodedDocument(businessID: frozen.businessID,
            documentToken: token, body: body))
          guard let text = String(data: response, encoding: .utf8) else {
            throw failure("DOCUMENT_PROJECTION_VIOLATION")
          }
          return DocumentCommandReceipt(previousRevision: scope.aggregateRevision,
            newRevision: next.aggregateRevision, response: text)
        })
    }
    do {
      let stored = try JSONDecoder().decode(EncodedDocument.self, from: Data(receipt.response.utf8))
      guard stored.businessID == request.submitted.businessID,
        try await principal(actor) == initial else { throw failure("DOCUMENT_AUTHORIZATION_REQUIRED") }
      let verified = try module.runtime.consumeBoundDocumentSnapshot(initial,
        token: stored.documentToken, aggregateType: request.aggregateType,
        purpose: request.purpose).document
      let next = verified.snapshot.scope
      guard verified.snapshot.businessID == stored.businessID,
        next.documentID == scope.documentID, next.aggregateID == scope.aggregateID,
        next.aggregateRevision == receipt.newRevision,
        receipt.previousRevision == scope.aggregateRevision else {
        throw failure("DOCUMENT_CATALOG_FAILED")
      }
      let document = ContextualDocument(businessID: stored.businessID,
        documentToken: stored.documentToken, body: try journal.validatedBody(stored.body))
      try await host.present(context: actor, document: document)
      return AcceptedDocument(document: document, previousRevision: receipt.previousRevision,
        newRevision: receipt.newRevision, replayed: replayed)
    } catch { throw GraphCommittedError(causes: [error]) }
  }
}
