import Foundation
import OpenTelemetryApi
import TeaQLCore

public final class OpenTelemetryRuntimeTelemetry: RuntimeTelemetry, @unchecked Sendable {
  private let tracer: any Tracer
  private let metrics: any RuntimeMetricRecorder
  private let logger: (any Logger)?

  public init<M: Meter>(tracer: any Tracer, meter: M, logger: (any Logger)? = nil) {
    self.tracer = tracer
    self.metrics = MetricInstruments(meter: meter)
    self.logger = logger
  }

  public func withOperation<Result: Sendable>(
    _ operation: RuntimeOperation,
    completion: @Sendable (Result) -> [String: RuntimeTelemetryValue],
    _ body: () async throws -> Result
  ) async rethrows -> Result {
    let builder = tracer.spanBuilder(spanName: "teaql.\(operation.family)")
    for (key, value) in operation.attributes {
      set(value, key: key, on: builder)
    }
    let startedAt = ContinuousClock.now
    return try await builder.withActiveSpan { span in
      do {
        let result = try await body()
        for (key, value) in completion(result)
          where key == "teaql.result.cardinality" || key == "teaql.cache.result"
        {
          set(value, key: key, on: span)
        }
        span.status = .ok
        record(operation, outcome: "success", startedAt: startedAt)
        return result
      } catch {
        span.setAttribute(key: "teaql.error.type", value: String(reflecting: type(of: error)))
        span.status = .error(description: "TeaQL operation failed")
        record(operation, outcome: "failure", startedAt: startedAt)
        throw error
      }
    }
  }

  public func withSynchronousOperation<Result>(
    _ operation: RuntimeOperation,
    completion: (Result) -> [String: RuntimeTelemetryValue],
    _ body: () throws -> Result
  ) rethrows -> Result {
    let builder = tracer.spanBuilder(spanName: "teaql.\(operation.family)")
    for (key, value) in operation.attributes { set(value, key: key, on: builder) }
    let startedAt = ContinuousClock.now
    return try builder.withActiveSpan { span in
      do {
        let result = try body()
        setSafeCompletion(completion(result), on: span)
        span.status = .ok
        record(operation, outcome: "success", startedAt: startedAt)
        return result
      } catch {
        span.setAttribute(key: "teaql.error.type", value: String(reflecting: type(of: error)))
        span.status = .error(description: "TeaQL operation failed")
        record(operation, outcome: "failure", startedAt: startedAt)
        throw error
      }
    }
  }

  public func flush() async {}
  public func shutdown() async {}

  private func record(
    _ operation: RuntimeOperation, outcome: String,
    startedAt: ContinuousClock.Instant
  ) {
    let elapsed = startedAt.duration(to: .now)
    let milliseconds = Double(elapsed.components.seconds) * 1_000
      + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
    metrics.record(family: operation.family, outcome: outcome, milliseconds: milliseconds)
    logger?.logRecordBuilder()
      .setSeverity(.info)
      .setBody(.string("TeaQL runtime operation completed"))
      .setAttributes([
        "teaql.operation.family": .string(operation.family),
        "teaql.operation.name": .string(operation.name),
        "teaql.operation.outcome": .string(outcome),
        "teaql.operation.duration_ms": .double(milliseconds),
      ])
      .emit()
  }

  private func setSafeCompletion(
    _ completion: [String: RuntimeTelemetryValue], on span: any SpanBase
  ) {
    for (key, value) in completion
      where key == "teaql.result.cardinality" || key == "teaql.cache.result"
    {
      set(value, key: key, on: span)
    }
  }
}

private func set(_ value: RuntimeTelemetryValue, key: String, on builder: any SpanBuilder) {
  switch value {
  case .string(let value): builder.setAttribute(key: key, value: value)
  case .integer(let value): builder.setAttribute(key: key, value: Int(value))
  case .double(let value): builder.setAttribute(key: key, value: value)
  case .boolean(let value): builder.setAttribute(key: key, value: value)
  }
}

private func set(_ value: RuntimeTelemetryValue, key: String, on span: any SpanBase) {
  switch value {
  case .string(let value): span.setAttribute(key: key, value: .string(value))
  case .integer(let value): span.setAttribute(key: key, value: .int(Int(value)))
  case .double(let value): span.setAttribute(key: key, value: .double(value))
  case .boolean(let value): span.setAttribute(key: key, value: .bool(value))
  }
}

private protocol RuntimeMetricRecorder: Sendable {
  func record(family: String, outcome: String, milliseconds: Double)
}

private final class MetricInstruments<M: Meter>: RuntimeMetricRecorder, @unchecked Sendable {
  private let lock = NSLock()
  private var duration: M.AssociatedDoubleHistogramBuilder.AnyDoubleHistogram
  private var operations: M.AssociatedCounterBuilder.AnyLongCounter

  init(meter: M) {
    duration = meter.histogramBuilder(name: "teaql.runtime.operation.duration").build()
    operations = meter.counterBuilder(name: "teaql.runtime.operation.count").build()
  }

  func record(family: String, outcome: String, milliseconds: Double) {
    let attributes: [String: AttributeValue] = [
      "teaql.operation.family": .string(family),
      "teaql.operation.outcome": .string(outcome),
    ]
    lock.lock()
    defer { lock.unlock() }
    duration.record(value: milliseconds, attributes: attributes)
    operations.add(value: 1, attributes: attributes)
  }
}
