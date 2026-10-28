import CStbImage
import Crypto
import Foundation
import FoundationXML
import TeaQLCore

private let officePackageNamespace = "http://schemas.openxmlformats.org/package/2006/"
private let officeDocumentNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/"
private let officeWordNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
private let officeSpreadsheetNamespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

private final class OfficeXMLInspector: NSObject, XMLParserDelegate {
  let maximumElements: Int
  let visit: ((OfficeXMLInspector, String, String, [String: String], Int) -> Void)?
  var elements = 0
  var depth = 0
  var root = ""
  var invalid = false
  private var namespaces: [String: [String]] = [:]

  init(maximumElements: Int,
       visit: ((OfficeXMLInspector, String, String, [String: String], Int) -> Void)?) {
    self.maximumElements = maximumElements
    self.visit = visit
  }

  func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String,
              toURI namespaceURI: String) {
    namespaces[prefix, default: []].append(namespaceURI)
  }

  func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
    guard var values = namespaces[prefix] else { invalid = true; return }
    _ = values.popLast()
    namespaces[prefix] = values.isEmpty ? nil : values
  }

  func attribute(_ attributes: [String: String], local: String, namespace: String = "") -> String? {
    for (key, value) in attributes {
      let pieces = key.split(separator: ":", omittingEmptySubsequences: false)
      if namespace.isEmpty && pieces.count == 1 && key == local { return value }
      if pieces.count == 2 && pieces[1] == Substring(local) &&
        namespaces[String(pieces[0])]?.last == namespace { return value }
    }
    return nil
  }

  func parser(_ parser: XMLParser, didStartElement elementName: String,
              namespaceURI: String?, qualifiedName qName: String?,
              attributes: [String: String] = [:]) {
    depth += 1
    elements += 1
    if depth > 128 || elements > maximumElements { invalid = true; parser.abortParsing(); return }
    let namespace = namespaceURI ?? ""
    if depth == 1 { root = namespace + "|" + elementName }
    visit?(self, namespace, elementName, attributes, depth)
  }

  func parser(_ parser: XMLParser, didEndElement elementName: String,
              namespaceURI: String?, qualifiedName qName: String?) {
    depth -= 1
    if depth < 0 { invalid = true; parser.abortParsing() }
  }
}

/// Passive, bounded DOCX/XLSX package and XML structure verifier.
public actor OfficeBlobContentVerifier: BlobContentVerifier {
  private let maximumInputBytes: Int64
  private let maximumDecodedBytes: Int64
  private let maximumParts: Int
  private let maximumElements: Int
  private let concurrentVerifications: Int
  private var active = 0

  public init(maximumInputBytes: Int64 = 32 * 1024 * 1024,
              maximumDecodedBytes: Int64 = 100 * 1024 * 1024,
              maximumParts: Int = 1000, maximumElements: Int = 200_000,
              concurrentVerifications: Int = 2) throws {
    guard (1...100 * 1024 * 1024).contains(maximumInputBytes),
      (1...100 * 1024 * 1024).contains(maximumDecodedBytes),
      (1...10_000).contains(maximumParts), (1...2_000_000).contains(maximumElements),
      (1...32).contains(concurrentVerifications) else {
      throw TeaQLError.execution("BLOB_POLICY_INVALID")
    }
    self.maximumInputBytes = maximumInputBytes
    self.maximumDecodedBytes = maximumDecodedBytes
    self.maximumParts = maximumParts
    self.maximumElements = maximumElements
    self.concurrentVerifications = concurrentVerifications
  }

  public func verify(reader: any ObjectByteReader, extension ext: String,
                     maximumBytes: Int64) async throws -> BlobVerifiedContent {
    let mime: String
    switch ext {
    case "docx": mime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    case "xlsx": mime = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    default: throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED")
    }
    guard maximumBytes > 0 else { throw TeaQLError.execution("BLOB_POLICY_INVALID") }
    guard active < concurrentVerifications else {
      throw TeaQLError.execution("BLOB_VERIFICATION_BUSY")
    }
    active += 1
    defer { active -= 1 }
    let bound = min(maximumBytes, maximumInputBytes)
    var data = Data()
    while true {
      let chunk: Data
      do { chunk = try await reader.read(upToCount: 64 * 1024) }
      catch { throw TeaQLError.execution("BLOB_STORE_FAILED") }
      if chunk.isEmpty { break }
      guard Int64(chunk.count) <= bound - Int64(data.count) else {
        throw TeaQLError.execution("BLOB_SIZE_EXCEEDED")
      }
      data.append(chunk)
    }
    let parts = try unpack([UInt8](data))
    try checkOffice(parts, extension: ext)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return BlobVerifiedContent(sizeBytes: Int64(data.count), sha256: digest, contentType: mime)
  }

  private func invalid() -> TeaQLError { .execution("BLOB_FORMAT_NOT_ALLOWED") }

  private func read16(_ data: [UInt8], _ index: Int) -> Int? {
    guard index >= 0, index <= data.count - 2 else { return nil }
    return Int(data[index]) | Int(data[index + 1]) << 8
  }

  private func read32(_ data: [UInt8], _ index: Int) -> Int? {
    guard index >= 0, index <= data.count - 4 else { return nil }
    return Int(data[index]) | Int(data[index + 1]) << 8 |
      Int(data[index + 2]) << 16 | Int(data[index + 3]) << 24
  }

  private func signature(_ data: [UInt8], _ index: Int, _ bytes: [UInt8]) -> Bool {
    index >= 0 && index <= data.count - bytes.count &&
      data[index..<(index + bytes.count)].elementsEqual(bytes)
  }

  private func validPartName(_ name: String) -> Bool {
    !name.isEmpty && name.utf8.count <= 1024 && !name.hasPrefix("/") &&
      !name.contains("\\") && !name.unicodeScalars.contains(where: {
        $0.value < 32 || $0.value == 127
      }) && name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
        !$0.isEmpty && $0 != "." && $0 != ".."
      }
  }

  private func unpack(_ bytes: [UInt8]) throws -> [String: Data] {
    guard bytes.count >= 22, signature(bytes, 0, [0x50, 0x4b, 3, 4]) else { throw invalid() }
    var end: Int?
    for index in stride(from: bytes.count - 22,
                        through: max(0, bytes.count - 22 - 65535), by: -1) {
      if signature(bytes, index, [0x50, 0x4b, 5, 6]),
        let comment = read16(bytes, index + 20), index + 22 + comment == bytes.count {
        end = index
        break
      }
    }
    guard let end, read16(bytes, end + 4) == 0, read16(bytes, end + 6) == 0,
      let count = read16(bytes, end + 10), (1...maximumParts).contains(count), count != 65535,
      read16(bytes, end + 8) == count,
      let centralSize = read32(bytes, end + 12), centralSize != 0xffffffff,
      let centralOffset = read32(bytes, end + 16), centralOffset != 0xffffffff,
      centralOffset + centralSize == end else { throw invalid() }
    var parts: [String: Data] = [:]
    var names = Set<String>()
    var offset = centralOffset
    var decoded = 0
    var firstLocal = centralOffset
    for _ in 0..<count {
      guard offset <= end - 46, signature(bytes, offset, [0x50, 0x4b, 1, 2]),
        let flags = read16(bytes, offset + 8), flags & ~0x0808 == 0,
        let method = read16(bytes, offset + 10), method == 0 || method == 8,
        let crc = read32(bytes, offset + 16),
        let compressed = read32(bytes, offset + 20), compressed != 0xffffffff,
        let expanded = read32(bytes, offset + 24), expanded != 0xffffffff,
        let nameLength = read16(bytes, offset + 28), nameLength > 0,
        let extraLength = read16(bytes, offset + 30),
        let commentLength = read16(bytes, offset + 32),
        read16(bytes, offset + 34) == 0,
        let local = read32(bytes, offset + 42), local != 0xffffffff,
        local < centralOffset, expanded <= Int(maximumDecodedBytes) - decoded else {
        throw invalid()
      }
      let next = offset + 46 + nameLength + extraLength + commentLength
      guard next <= end,
        let name = String(bytes: bytes[(offset + 46)..<(offset + 46 + nameLength)],
                          encoding: .utf8), validPartName(name), names.insert(name.lowercased()).inserted,
        local <= centralOffset - 30 - nameLength,
        signature(bytes, local, [0x50, 0x4b, 3, 4]),
        read16(bytes, local + 6) == flags, read16(bytes, local + 8) == method,
        read16(bytes, local + 26) == nameLength,
        bytes[(local + 30)..<(local + 30 + nameLength)]
          .elementsEqual(bytes[(offset + 46)..<(offset + 46 + nameLength)]),
        let localExtra = read16(bytes, local + 28) else { throw invalid() }
      let payload = local + 30 + nameLength + localExtra
      guard payload <= centralOffset, compressed <= centralOffset - payload else {
        throw invalid()
      }
      if flags & 8 == 0 {
        guard read32(bytes, local + 14) == crc,
          read32(bytes, local + 18) == compressed,
          read32(bytes, local + 22) == expanded else { throw invalid() }
      } else {
        let descriptor = payload + compressed
        let values = descriptor +
          (signature(bytes, descriptor, [0x50, 0x4b, 7, 8]) ? 4 : 0)
        guard values <= centralOffset - 12,
          read32(bytes, values) == crc,
          read32(bytes, values + 4) == compressed,
          read32(bytes, values + 8) == expanded else { throw invalid() }
      }
      let value: Data
      if method == 0 {
        guard compressed == expanded else { throw invalid() }
        value = Data(bytes[payload..<(payload + compressed)])
      } else {
        var output = [UInt8](repeating: 0, count: expanded + 1)
        let valid = bytes.withUnsafeBufferPointer { input in
          output.withUnsafeMutableBufferPointer { result in
            guard let start = input.baseAddress, let destination = result.baseAddress else {
              return false
            }
            return teaql_zip_inflate_raw(start.advanced(by: payload), Int32(compressed),
              destination, Int32(expanded)) == 1
          }
        }
        guard valid else { throw invalid() }
        value = Data(output.prefix(expanded))
      }
      let actualCRC = value.withUnsafeBytes { raw -> UInt32 in
        teaql_zip_crc32(raw.baseAddress?.assumingMemoryBound(to: UInt8.self), Int32(value.count))
      }
      guard actualCRC == UInt32(crc) else { throw invalid() }
      parts[name] = value
      decoded += value.count
      firstLocal = min(firstLocal, local)
      offset = next
    }
    guard offset == end, firstLocal == 0 else { throw invalid() }
    return parts
  }

  private func scanXML(_ data: Data, remaining: Int,
                       visit: ((OfficeXMLInspector, String, String, [String: String], Int) -> Void)? = nil)
    throws -> (String, Int) {
    let text: String?
    if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
      text = String(data: data, encoding: .utf16)
    } else {
      guard !data.contains(0) else { throw invalid() }
      text = String(data: data, encoding: .utf8)
    }
    guard let text,
      text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
      text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { throw invalid() }
    let inspector = OfficeXMLInspector(maximumElements: remaining, visit: visit)
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = true
    parser.shouldReportNamespacePrefixes = true
    parser.shouldResolveExternalEntities = false
    parser.externalEntityResolvingPolicy = .never
    parser.delegate = inspector
    guard parser.parse(), !inspector.invalid, inspector.depth == 0, !inspector.root.isEmpty else {
      throw invalid()
    }
    return (inspector.root, inspector.elements)
  }

  private func checkOffice(_ parts: [String: Data], extension ext: String) throws {
    var remaining = maximumElements
    for (name, value) in parts {
      if name.lowercased().hasSuffix(".xml") || name.lowercased().hasSuffix(".rels") {
        let (_, elements) = try scanXML(value, remaining: remaining)
        remaining -= elements
      }
    }
    let main = ext == "docx" ? "word/document.xml" : "xl/workbook.xml"
    let mainType = ext == "docx"
      ? "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
      : "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"
    guard let types = parts["[Content_Types].xml"], let relationships = parts["_rels/.rels"],
      let document = parts[main] else { throw invalid() }
    var typesMatch = false
    let (typesRoot, _) = try scanXML(types, remaining: maximumElements) {
      inspector, uri, local, attributes, depth in
      if depth == 2 && uri == officePackageNamespace + "content-types" && local == "Override" &&
        inspector.attribute(attributes, local: "PartName") == "/" + main &&
        inspector.attribute(attributes, local: "ContentType") == mainType { typesMatch = true }
    }
    guard typesRoot == officePackageNamespace + "content-types|Types", typesMatch else {
      throw invalid()
    }
    var relationshipMatch = false
    let (relationsRoot, _) = try scanXML(relationships, remaining: maximumElements) {
      inspector, uri, local, attributes, depth in
      if depth == 2 && uri == officePackageNamespace + "relationships" &&
        local == "Relationship" &&
        inspector.attribute(attributes, local: "Type") == officeDocumentNamespace +
          "relationships/officeDocument" &&
        inspector.attribute(attributes, local: "Target") == main &&
        inspector.attribute(attributes, local: "TargetMode") != "External" {
        relationshipMatch = true
      }
    }
    guard relationsRoot == officePackageNamespace + "relationships|Relationships",
      relationshipMatch else { throw invalid() }
    if ext == "docx" {
      var body = false
      let (root, _) = try scanXML(document, remaining: maximumElements) {
        _, uri, local, _, depth in
        if depth == 2 && uri == officeWordNamespace && local == "body" { body = true }
      }
      guard root == officeWordNamespace + "|document", body else { throw invalid() }
      return
    }
    var sheets = Set<String>()
    let (root, _) = try scanXML(document, remaining: maximumElements) {
      inspector, uri, local, attributes, depth in
      if depth == 3 && uri == officeSpreadsheetNamespace && local == "sheet",
        let id = inspector.attribute(attributes, local: "id",
          namespace: officeDocumentNamespace + "relationships"), !id.isEmpty {
        sheets.insert(id)
      }
    }
    guard root == officeSpreadsheetNamespace + "|workbook", !sheets.isEmpty,
      let workbookRels = parts["xl/_rels/workbook.xml.rels"] else { throw invalid() }
    var candidates: [(String, String)] = []
    let (workbookRoot, _) = try scanXML(workbookRels, remaining: maximumElements) {
      inspector, uri, local, attributes, depth in
      guard depth == 2 && uri == officePackageNamespace + "relationships" &&
        local == "Relationship",
        inspector.attribute(attributes, local: "Type") == officeDocumentNamespace +
          "relationships/worksheet",
        inspector.attribute(attributes, local: "TargetMode") != "External",
        let id = inspector.attribute(attributes, local: "Id"), sheets.contains(id),
        let target = inspector.attribute(attributes, local: "Target") else { return }
      candidates.append((id, target))
    }
    guard workbookRoot == officePackageNamespace + "relationships|Relationships" else {
      throw invalid()
    }
    var matched = Set<String>()
    for (id, target) in candidates {
      guard validPartName(target) else { continue }
      let resolved = "xl/" + target
      guard resolved.hasPrefix("xl/worksheets/"), let worksheet = parts[resolved],
        let (worksheetRoot, _) = try? scanXML(worksheet, remaining: maximumElements),
        worksheetRoot == officeSpreadsheetNamespace + "|worksheet" else { continue }
      matched.insert(id)
    }
    guard matched.count == sheets.count else { throw invalid() }
  }
}
