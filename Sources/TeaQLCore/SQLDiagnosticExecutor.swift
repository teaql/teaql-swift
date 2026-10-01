// Package-only provider/context handoff. Neither queries nor mutations gain
// callbacks or non-Codable state, and applications still receive the original error.
package protocol SQLDiagnosticExecutor: QueryExecutor, MutationExecutor {
  func executeDiagnosed(_ request: QueryRequest) async throws -> QueryResult
  func executeDiagnosed(_ request: MutationRequest) async throws -> MutationResult
}

package extension SQLDiagnosticExecutor {
  func executeDiagnosed(_ query: SelectQuery) async throws -> QueryResult {
    try await executeDiagnosed(QueryRequest(query: query))
  }
  func executeDiagnosed(_ mutation: Mutation) async throws -> MutationResult {
    try await executeDiagnosed(MutationRequest(mutation: mutation))
  }
}

package struct SQLExecutionFailure: Error {
  package let cause: any Error
  package let diagnostics: [SQLFailureDiagnostic]
  package init(cause: any Error, metadata: SQLExecutionMetadata) {
    self.cause = cause
    self.diagnostics = [SQLFailureDiagnostic(metadata: metadata)]
  }
  package init(cause: any Error, diagnostics: [SQLFailureDiagnostic]) {
    self.cause = cause
    self.diagnostics = diagnostics
  }
}

// Call-local provenance only. Never attached to safe sink/buffer metadata.
package struct SQLFailureDiagnostic: Sendable {
  package let metadata: SQLExecutionMetadata
  package let intentSource: SQLExecutionMetadata?
  package init(metadata: SQLExecutionMetadata, intentSource: SQLExecutionMetadata? = nil) {
    self.metadata = metadata
    self.intentSource = intentSource
  }
}
