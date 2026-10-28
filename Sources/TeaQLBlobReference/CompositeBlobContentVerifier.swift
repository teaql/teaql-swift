import Foundation
import TeaQLCore

/// One host-selected optional parser and the extensions it accepts.
public struct BlobVerifierRoute: Sendable {
  public let extensions: [String]
  public let verifier: any BlobContentVerifier
  public init(extensions: [String], verifier: any BlobContentVerifier) {
    self.extensions = extensions
    self.verifier = verifier
  }
}

/// Passive routes for the single trusted Blob upload verifier SPI.
public struct CompositeBlobContentVerifier: BlobContentVerifier, BlobVerifierReadiness {
  private let routes: [String: any BlobContentVerifier]
  private let readiness: [any BlobContentVerifier]

  public init(routes selected: [BlobVerifierRoute]) throws {
    guard (1...32).contains(selected.count) else {
      throw TeaQLError.execution("BLOB_POLICY_INVALID")
    }
    var routes: [String: any BlobContentVerifier] = [:]
    var readiness: [any BlobContentVerifier] = []
    for route in selected {
      guard (1...32).contains(route.extensions.count) else {
        throw TeaQLError.execution("BLOB_POLICY_INVALID")
      }
      for ext in route.extensions {
        guard (1...16).contains(ext.utf8.count),
          ext.utf8.allSatisfy({ ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) }),
          routes[ext] == nil, routes.count < 32 else {
          throw TeaQLError.execution("BLOB_POLICY_INVALID")
        }
        routes[ext] = route.verifier
      }
      readiness.append(route.verifier)
    }
    self.routes = routes
    self.readiness = readiness
  }

  public var supportedExtensions: [String] { routes.keys.sorted() }

  public func validateReady() async throws {
    for verifier in readiness {
      if let ready = verifier as? any BlobVerifierReadiness {
        try await ready.validateReady()
      }
    }
  }

  public func verify(reader: any ObjectByteReader, extension ext: String,
                     maximumBytes: Int64) async throws -> BlobVerifiedContent {
    guard let verifier = routes[ext] else {
      throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED")
    }
    return try await verifier.verify(reader: reader, extension: ext, maximumBytes: maximumBytes)
  }
}
