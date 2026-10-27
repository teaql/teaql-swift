// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "teaql-swift",
  platforms: [
    .macOS(.v14),
    .iOS(.v17),
  ],
  products: [
    .library(name: "TeaQLCore", targets: ["TeaQLCore"]),
    .library(name: "TeaQLSQL", targets: ["TeaQLSQL"]),
    .library(name: "TeaQLSQLite", targets: ["TeaQLSQLite"]),
    .library(name: "TeaQLBlobReference", targets: ["TeaQLBlobReference"]),
    .library(name: "TeaQLSecureDocumentReference", targets: ["TeaQLSecureDocumentReference"]),
    .library(name: "TeaQLFederal", targets: ["TeaQLFederal"]),
    .library(name: "TeaQLTestSupport", targets: ["TeaQLTestSupport"]),
    .library(name: "TeaQLOpenTelemetry", targets: ["TeaQLOpenTelemetry"]),
    .library(name: "TeaQLStandardTelemetry", targets: ["TeaQLStandardTelemetry"]),
    .executable(name: "teaql-order-management", targets: ["OrderManagement"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.1"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.3"),
    .package(url: "https://github.com/open-telemetry/opentelemetry-swift-core.git", from: "2.2.0"),
    .package(url: "https://github.com/open-telemetry/opentelemetry-swift.git", from: "2.2.0"),
  ],
  targets: [
    .systemLibrary(
      name: "CSQLite",
      providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite3"])]
    ),
    .target(name: "TeaQLCore", resources: [.process("Resources")]),
    .target(name: "TeaQLSQL", dependencies: ["TeaQLCore"]),
    .target(name: "TeaQLSQLite", dependencies: ["TeaQLCore", "TeaQLSQL", "CSQLite"]),
    .target(name: "CStbImage", publicHeadersPath: "include"),
    .target(name: "TeaQLBlobReference", dependencies: [
      "TeaQLCore", "CStbImage", .product(name: "Crypto", package: "swift-crypto"),
      .product(name: "NIOCore", package: "swift-nio"),
      .product(name: "NIOHTTP1", package: "swift-nio"),
      .product(name: "NIOPosix", package: "swift-nio"),
    ]),
    .target(name: "TeaQLSecureDocumentReference", dependencies: [
      "TeaQLCore", .product(name: "Crypto", package: "swift-crypto"),
    ]),
    .target(name: "TeaQLFederal", dependencies: ["TeaQLCore"]),
    .target(name: "TeaQLTestSupport", dependencies: ["TeaQLCore", "TeaQLSQLite"]),
    .target(
      name: "TeaQLOpenTelemetry",
      dependencies: [
        "TeaQLCore",
        .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
      ]
    ),
    .target(name: "TeaQLStandardTelemetry", dependencies: [
      "TeaQLCore",
      .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
      .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
      .product(name: "OpenTelemetryProtocolExporterHTTP", package: "opentelemetry-swift"),
    ]),
    .testTarget(name: "TeaQLStandardTelemetryTests", dependencies: [
      "TeaQLStandardTelemetry", "TeaQLCore", "TeaQLSQLite",
      .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
      .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
    ]),
    .executableTarget(
      name: "OrderManagement",
      dependencies: ["TeaQLCore", "TeaQLSQLite", "TeaQLFederal"],
      path: "Examples/OrderManagement",
      exclude: ["Generated/Package.swift", "Generated/README.md", "README.md"],
      sources: ["Sources", "Generated/Sources/GeneratedTeaQL"]
    ),
    .testTarget(name: "TeaQLCoreTests", dependencies: ["TeaQLCore"], resources: [.process("fixtures")]),
    .testTarget(name: "TeaQLSQLTests", dependencies: ["TeaQLSQL"]),
    .testTarget(name: "TeaQLSQLiteTests", dependencies: ["TeaQLSQLite", "TeaQLTestSupport"]),
    .testTarget(name: "TeaQLBlobReferenceTests", dependencies: [
      "TeaQLBlobReference", "TeaQLSQLite", .product(name: "Crypto", package: "swift-crypto"),
    ], resources: [.copy("fixtures")]),
    .testTarget(name: "TeaQLSecureDocumentReferenceTests", dependencies: [
      "TeaQLSecureDocumentReference", "TeaQLBlobReference", "TeaQLCore", "TeaQLSQLite",
      .product(name: "Crypto", package: "swift-crypto"),
    ]),
    .testTarget(name: "TeaQLFederalTests", dependencies: ["TeaQLFederal"]),
    .testTarget(
      name: "TeaQLOpenTelemetryTests",
      dependencies: [
        "TeaQLOpenTelemetry",
        .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
        .product(name: "InMemoryExporter", package: "opentelemetry-swift"),
        .product(name: "OpenTelemetryProtocolExporterHTTP", package: "opentelemetry-swift"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
