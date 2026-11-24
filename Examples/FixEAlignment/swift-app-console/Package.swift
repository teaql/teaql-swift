// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "FixEAlignment", dependencies: [.package(name: "teaql-swift", path: "../../.."), .package(path: "../swift-lib-core")], targets: [
  .executableTarget(name: "FixEAlignment", dependencies: [.product(name: "GeneratedTeaQL", package: "swift-lib-core"), .product(name: "TeaQLCore", package: "teaql-swift"),
    .product(name: "TeaQLSQLite", package: "teaql-swift")], path: "Sources/FixEAlignment")
], swiftLanguageModes: [.v6])
