import Foundation

/// Presentation values are detached value types. A Blob never enters generic JSON output.
public indirect enum ViewValue: Sendable, Equatable, Encodable {
  case null, bool(Bool), int(Int64), double(Double), string(String)
  case array([ViewValue]), object([String: ViewValue]), blob(BlobRef)

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .blob: throw TeaQLError.execution("BLOB_PRESENTATION_REQUIRED")
    }
  }
}

public enum ViewPathComponent: Sendable, Hashable {
  case field(String), index(Int)
}

public struct ViewOptions: Sendable {
  public enum Mode: Sendable { case ordinary, governed }
  public enum BusinessOutcome: Sendable { case readOnly, committed }
  public let mode: Mode
  public let businessOutcome: BusinessOutcome
  public let expiresAt: Date?
  public init(mode: Mode, businessOutcome: BusinessOutcome, expiresAt: Date? = nil) {
    self.mode = mode; self.businessOutcome = businessOutcome; self.expiresAt = expiresAt
  }
}

/// Trusted current authorization supplies canonical positions, not a JSON Key search.
public struct AuthorizedBlobSlot: Sendable {
  public let path: [ViewPathComponent]
  public let entity: String
  public let entityID: String
  public let field: String
  public let scope: String
  public let bindingVersion: Int64
  public let reference: BlobRef
  public init(path: [ViewPathComponent], entity: String, entityID: String, field: String,
              scope: String, bindingVersion: Int64, reference: BlobRef) {
    self.path = path; self.entity = entity; self.entityID = entityID; self.field = field
    self.scope = scope; self.bindingVersion = bindingVersion; self.reference = reference
  }
}

public struct AuthorizedResponseGraph: Sendable {
  public let presentation: ViewValue
  public let blobSlots: [AuthorizedBlobSlot]
  public init(presentation: ViewValue, blobSlots: [AuthorizedBlobSlot]) {
    self.presentation = presentation; self.blobSlots = blobSlots
  }
}

public protocol ResponseGraphAuthorizer: Sendable {
  func authorize(context: UserContext, result: any Sendable, options: ViewOptions)
    async throws -> AuthorizedResponseGraph
}

public struct PreparedSecureDocument: Sendable {
  public let graph: AuthorizedResponseGraph
  public let envelope: ViewValue
  public let expiresAt: Date
  public init(graph: AuthorizedResponseGraph, envelope: ViewValue, expiresAt: Date) {
    self.graph = graph; self.envelope = envelope; self.expiresAt = expiresAt
  }
}

public protocol SecureDocumentContributor: Sendable {
  func prepare(context: UserContext, graph: AuthorizedResponseGraph, options: ViewOptions)
    async throws -> PreparedSecureDocument
}

public struct ProjectedBlobURL: Sendable {
  public let url: String
  public let expiresAt: Date
  public init(url: String, expiresAt: Date) { self.url = url; self.expiresAt = expiresAt }
}

public protocol BlobResponseContributor: Sendable {
  func projectBatch(context: UserContext, graph: AuthorizedResponseGraph, expiresAt: Date?)
    async throws -> [ProjectedBlobURL]
}

public struct PreparedView: Sendable {
  public let presentation: ViewValue
  public let document: ViewValue?
  public let expiresAt: Date?
  public let cacheControl = "private, no-store"
}

public struct ViewPreparationError: Error, Sendable, CustomStringConvertible {
  public let code: String
  public let businessState: String
  public var retry: String { businessState == "committed" ? "read" : "prepare" }
  public var description: String { code }
  public init(_ code: String, businessState: String = "read_only") {
    self.code = code; self.businessState = businessState
  }
}

public extension UserContext {
  func withResponseGraphAuthorizer(_ value: any ResponseGraphAuthorizer) -> UserContext {
    var copy = self; copy.responseGraphAuthorizer = value; return copy
  }
  func withSecureDocumentContributor(_ value: any SecureDocumentContributor) -> UserContext {
    var copy = self; copy.secureDocumentContributor = value; return copy
  }
  func withBlobResponseContributor(_ value: any BlobResponseContributor) -> UserContext {
    var copy = self; copy.blobResponseContributor = value; return copy
  }
}

public struct ViewPreparationService: Sendable {
  private static let safeCodes: Set<String> = [
    "VIEW_OPTIONS_INVALID", "VIEW_AUTHORIZER_MISSING", "VIEW_GRAPH_INVALID",
    "DOCUMENT_CONFIGURATION", "DOCUMENT_PROJECTION_VIOLATION", "BLOB_CAPABILITY_MISSING", "BLOB_SIGN_FAILED",
    "BLOB_READ_DENIED", "BLOB_REFERENCE_EXPIRED", "BLOB_SCHEMA_MISSING", "BLOB_CATALOG_FAILED",
    "ROUND_TRIP_REFERENCE_INVALID", "ROUND_TRIP_REFERENCE_EXPIRED", "ROUND_TRIP_REFERENCE_SCOPE_MISMATCH",
    "ROUND_TRIP_REFERENCE_AUTHORIZATION_REQUIRED", "ROUND_TRIP_REFERENCE_CONFIGURATION_INVALID",
  ]

  public init() {}

  public func prepare<T: Sendable>(context: UserContext, result: T,
                                   options: ViewOptions) async throws -> PreparedView {
    do {
      if let expiry = options.expiresAt, expiry <= Date() {
        throw ViewPreparationError("VIEW_OPTIONS_INVALID")
      }
      guard let authorizer = context.responseGraphAuthorizer else {
        throw ViewPreparationError("VIEW_AUTHORIZER_MISSING")
      }
      var graph = try await authorizer.authorize(context: context, result: result, options: options)
      var document: ViewValue?
      var expiry = options.expiresAt
      if options.mode == .governed {
        guard let secure = context.secureDocumentContributor else {
          throw ViewPreparationError("DOCUMENT_CONFIGURATION")
        }
        let prepared = try await secure.prepare(context: context, graph: graph, options: options)
        guard prepared.expiresAt > Date() else {
          throw ViewPreparationError("DOCUMENT_CONFIGURATION")
        }
        graph = prepared.graph
        document = prepared.envelope
        expiry = minExpiry(expiry, prepared.expiresAt)
      }
      guard graph.blobSlots.count <= 10_000 else { throw ViewPreparationError("VIEW_GRAPH_INVALID") }
      var presentation = graph.presentation
      var paths = Set<[ViewPathComponent]>()
      for slot in graph.blobSlots {
        guard slot.path.count > 0, slot.path.count <= 64, paths.insert(slot.path).inserted,
              try presentation.value(at: slot.path) == .blob(slot.reference) else {
          throw ViewPreparationError("VIEW_GRAPH_INVALID")
        }
      }
      if !graph.blobSlots.isEmpty {
        guard let blob = context.blobResponseContributor else {
          throw ViewPreparationError("BLOB_CAPABILITY_MISSING")
        }
        let ceiling = expiry
        let urls = try await blob.projectBatch(context: context, graph: graph, expiresAt: ceiling)
        guard urls.count == graph.blobSlots.count else { throw ViewPreparationError("BLOB_SIGN_FAILED") }
        for (slot, issued) in zip(graph.blobSlots, urls) {
          guard let parsed = URLComponents(string: issued.url),
                parsed.scheme == "http" || parsed.scheme == "https",
                let host = parsed.host, !host.isEmpty,
                issued.expiresAt > Date(), ceiling == nil || issued.expiresAt <= ceiling! else {
            throw ViewPreparationError("BLOB_SIGN_FAILED")
          }
          presentation = try presentation.replacing(at: slot.path, with: .string(issued.url))
          expiry = minExpiry(expiry, issued.expiresAt)
        }
      }
      var budget = 100_000
      guard !presentation.containsBlob(depth: 0, budget: &budget) else {
        throw ViewPreparationError("BLOB_CAPABILITY_MISSING")
      }
      return PreparedView(presentation: presentation, document: document, expiresAt: expiry)
    } catch {
      let candidate = (error as? ViewPreparationError)?.code ?? ""
      let code = Self.safeCodes.contains(candidate) ? candidate : "VIEW_PREPARATION_FAILED"
      throw ViewPreparationError(code, businessState: options.businessOutcome == .committed
        ? "committed" : "read_only")
    }
  }

  private func minExpiry(_ left: Date?, _ right: Date) -> Date {
    left.map { min($0, right) } ?? right
  }
}

private extension ViewValue {
  func value(at path: [ViewPathComponent]) throws -> ViewValue {
    if path.isEmpty { return self }
    switch (self, path[0]) {
    case (.object(let object), .field(let name)):
      guard let child = object[name], !name.isEmpty else { throw ViewPreparationError("VIEW_GRAPH_INVALID") }
      return try child.value(at: Array(path.dropFirst()))
    case (.array(let array), .index(let index)) where index >= 0 && index < array.count:
      return try array[index].value(at: Array(path.dropFirst()))
    default: throw ViewPreparationError("VIEW_GRAPH_INVALID")
    }
  }

  func replacing(at path: [ViewPathComponent], with replacement: ViewValue) throws -> ViewValue {
    if path.isEmpty { return replacement }
    switch (self, path[0]) {
    case (.object(var object), .field(let name)):
      guard let child = object[name], !name.isEmpty else { throw ViewPreparationError("VIEW_GRAPH_INVALID") }
      object[name] = try child.replacing(at: Array(path.dropFirst()), with: replacement)
      return .object(object)
    case (.array(var array), .index(let index)) where index >= 0 && index < array.count:
      array[index] = try array[index].replacing(at: Array(path.dropFirst()), with: replacement)
      return .array(array)
    default: throw ViewPreparationError("VIEW_GRAPH_INVALID")
    }
  }

  func containsBlob(depth: Int, budget: inout Int) -> Bool {
    budget -= 1
    if budget < 0 || depth > 64 { return true }
    switch self {
    case .blob: return true
    case .array(let values):
      return values.contains { $0.containsBlob(depth: depth + 1, budget: &budget) }
    case .object(let values):
      return values.values.contains { $0.containsBlob(depth: depth + 1, budget: &budget) }
    default: return false
    }
  }
}
