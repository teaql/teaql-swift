import Foundation

public enum TeaQLValue: Sendable, Hashable, Codable {
  case null
  case bool(Bool)
  case int(Int64)
  case uint(UInt64)
  case double(Double)
  case decimal(Decimal)
  case string(String)
  case date(Date)
  case data(Data)
  case array([TeaQLValue])
  case object([String: TeaQLValue])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .int(value)
    } else if let value = try? container.decode(UInt64.self) {
      self = .uint(value)
    } else if let value = try? container.decode(Decimal.self) {
      self = .decimal(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([TeaQLValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: TeaQLValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .uint(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .decimal(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .date(let value): try container.encode(value)
    case .data(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

public typealias TeaQLRecord = [String: TeaQLValue]

extension TeaQLValue {
  public var int64Value: Int64? {
    switch self {
    case .int(let value): value
    case .uint(let value) where value <= UInt64(Int64.max): Int64(value)
    default: nil
    }
  }

  public var stringValue: String? {
    if case .string(let value) = self { value } else { nil }
  }

  public var boolValue: Bool? {
    if case .bool(let value) = self { value } else { nil }
  }

  public var doubleValue: Double? {
    switch self {
    case .double(let value): value
    case .int(let value): Double(value)
    default: nil
    }
  }

  public var decimalValue: Decimal? {
    switch self {
    case .decimal(let value): value
    case .double(let value) where value.isFinite: Decimal(value)
    case .int(let value): Decimal(value)
    default: nil
    }
  }

  public var dateValue: Date? {
    if case .date(let value) = self { value } else { nil }
  }
}
