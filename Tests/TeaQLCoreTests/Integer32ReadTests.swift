import Foundation
import Testing
@_spi(Generated) @testable import TeaQLCore

@Suite("Modeled Integer pure read boundaries")
struct Integer32ReadTests {
  private let entity = EntityDescriptor(name: "WidthReadProbe", table: "width_read_probe", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "requiredInteger", modelName: "required_integer", column: "legacy_integer", type: .int, isInt32: true),
    PropertyDescriptor(name: "optionalInteger", modelName: "optional_integer", type: .int, nullable: true, isInt32: true),
    PropertyDescriptor(name: "requiredLong", modelName: "required_long", type: .int),
  ])

  @Test func integer32ReadAcceptsExactEndpointsAndDoesNotNarrowOtherProperties() throws {
    for value: Int64 in [-2_147_483_648, 0, 2_147_483_647] {
      let record: TeaQLRecord = ["requiredInteger": .int(value), "optionalInteger": .null,
        "id": .int(Int64.max), "version": .int(Int64.max - 1), "requiredLong": .int(Int64.min),
        "_derived": .uint(UInt64.max)]
      #expect(try ModeledInteger32.readRecord(record, entity: entity) == record)
    }
  }

  @Test func integer32ReadRejectsInvalidNativeModelAndColumnValuesWithoutPublishingInput() throws {
    for name in ["requiredInteger", "required_integer", "legacy_integer"] {
      for value: TeaQLValue in [.int(-2_147_483_649), .int(2_147_483_648), .uint(UInt64.max),
        .double(1.5), .string("PRIVATE-MALFORMED-INTEGER"), .bool(true), .timestamp(7)] {
        let record: TeaQLRecord = [name: value]
        do {
          _ = try ModeledInteger32.readRecord(record, entity: entity)
          Issue.record("An invalid loaded Integer was accepted")
        } catch let error as CheckException {
          #expect(error.violations.count == 1)
          #expect(error.violations[0].location.modelPath == "required_integer")
          #expect(error.violations[0].entityType == "WidthReadProbe")
          #expect(error.violations[0].inputValue == nil)
          #expect(!String(describing: error).contains("PRIVATE-MALFORMED-INTEGER"))
        }
        #expect(record[name] == value)
      }
    }
  }

  @Test func integer32ReadDistinguishesMissingOptionalNullAndRequiredNull() throws {
    let absent: TeaQLRecord = ["id": .int(1), "version": .int(7)]
    #expect(try ModeledInteger32.readRecord(absent, entity: entity) == absent)
    #expect(try ModeledInteger32.readRecord(["optionalInteger": .null], entity: entity) == ["optionalInteger": .null])
    do {
      _ = try ModeledInteger32.readRecord(["requiredInteger": .null], entity: entity)
      Issue.record("A loaded required null would become a fabricated zero")
    } catch let error as CheckException {
      #expect(error.violations[0].location.modelPath == "required_integer")
    }
  }

  @Test func integer32ReadNormalizesExactDecimalAndUnsignedWithoutMutatingTheRecord() throws {
    for value: TeaQLValue in [.decimal(Decimal(string: "42.000")!), .uint(42)] {
      let original: TeaQLRecord = ["requiredInteger": value]
      let loaded = try ModeledInteger32.readRecord(original, entity: entity)
      #expect(loaded["requiredInteger"] == .int(42))
      #expect(original["requiredInteger"] == value)
    }
    #expect(ModeledInteger32.exactValue(.decimal(Decimal(string: "3.5")!)) == nil)
    #expect(ModeledInteger32.exactValue(.decimal(.nan)) == nil)
  }

  @Test func integer32ReadAndExpressionChecksDoNotTreatTimestampOrFloatAsInteger() {
    for value: TeaQLValue in [.timestamp(42), .double(42), .string("42"), .bool(true)] {
      let error = ModeledInteger32.error(value, entity: entity, field: "required_integer")
      #expect(error?.violations.first?.ruleID == "invalid_type")
      #expect(error?.violations.first?.location.modelPath == "required_integer")
    }
    #expect(ModeledInteger32.error(.int(Int64.max), entity: entity, field: "required_long") == nil)
    #expect(ModeledInteger32.error(.null, entity: entity, field: "optional_integer") == nil)
  }

  @Test func integer32MetadataDecodeRejectsIncompatibleScalarAndIdentityDefinitions() throws {
    for suffix in ["\"type\":\"string\"", "\"type\":\"double\"", "\"type\":\"int\",\"isID\":true",
      "\"type\":\"int\",\"isVersion\":true", "\"type\":\"int\",\"isRelation\":true",
      "\"type\":\"int\",\"referencedEntity\":\"Other\""] {
      let data = Data(("{\"name\":\"number\",\"isInt32\":true," + suffix + "}").utf8)
      do {
        _ = try JSONDecoder().decode(PropertyDescriptor.self, from: data)
        Issue.record("Invalid 32-bit metadata was accepted")
      } catch is DecodingError { }
    }
  }

  @Test func integer32InvalidManualMetadataFailsBeforeModuleInstallation() throws {
    let good = EntityDescriptor(name: "Good", table: "good", properties: [])
    for property in [PropertyDescriptor(name: "id", type: .int, isID: true, isInt32: true),
      PropertyDescriptor(name: "text", type: .string, isInt32: true)] {
      var runtime = TeaQLRuntime()
      do {
        try runtime.install(RuntimeModule(name: "bad-width", entities: [good,
          EntityDescriptor(name: "Bad", table: "bad", properties: [property])]))
        Issue.record("Invalid metadata reached a runtime module")
      } catch let TeaQLError.execution(message) { #expect(message.hasPrefix("INVALID_INTEGER32_METADATA:")) }
      #expect(runtime.entities.isEmpty)
    }
  }
}
