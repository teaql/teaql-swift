// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "teaql-swift-standard-order-example",
  dependencies: [.package(name: "teaql-swift", path: "../../..")],
  targets: [
    .target(name: "GeneratedTeaQL", dependencies: [.product(name: "TeaQLCore", package: "teaql-swift")],
      path: "lib/Sources/GeneratedTeaQL"),
    .executableTarget(name: "StandardOrderVerification", dependencies: ["GeneratedTeaQL",
      .product(name: "TeaQLCore", package: "teaql-swift"),
      .product(name: "TeaQLSQLite", package: "teaql-swift"),
      .product(name: "TeaQLStandardTelemetry", package: "teaql-swift")], path: "Application"),
  ], swiftLanguageModes: [.v6]
)
