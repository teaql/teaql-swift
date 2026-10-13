import Foundation

/// Provider-neutral execution identity. It travels with the diagnostic value;
/// it is never reconstructed from a late active span or a request-local FIFO.
package struct SQLTelemetryCorrelation: Sendable {
  package let owner: UUID
  package let traceID: String
  package let spanID: String
  package init(owner: UUID, traceID: String, spanID: String) {
    self.owner = owner; self.traceID = traceID; self.spanID = spanID
  }
}

package protocol SQLTelemetryObservation: Sendable {
  var correlation: SQLTelemetryCorrelation { get }
  func finish(success: Bool)
}

package protocol SQLTelemetryObserver: Sendable {
  func beginSQL(operation: String, entity: String) -> (any SQLTelemetryObservation)?
}

package enum SQLTelemetryObservationContext {
  @TaskLocal package static var observer: (any SQLTelemetryObserver)?
}
