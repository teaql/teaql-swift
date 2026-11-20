// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "FixEAlignment", dependencies: [.package(name: "teaql-swift", path: "../../..")], targets: [
  .target(name: "GeneratedTeaQL", dependencies: [.product(name: "TeaQLCore", package: "teaql-swift")], path: "Sources/GeneratedTeaQL"),
  .executableTarget(name: "FixEAlignment", dependencies: ["GeneratedTeaQL", .product(name: "TeaQLCore", package: "teaql-swift"),
    .product(name: "TeaQLSQLite", package: "teaql-swift")], path: "Sources/FixEAlignment")
], swiftLanguageModes: [.v6])
