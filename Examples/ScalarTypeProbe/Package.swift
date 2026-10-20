// swift-tools-version: 6.0
import Foundation
import PackageDescription

let runtimePath = ProcessInfo.processInfo.environment["TEAQL_SWIFT_RUNTIME_PATH"] ?? "../.."
let package = Package(
  name: "TeaQLScalarTypeProbe",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [.executable(name: "ScalarDecimalVerification", targets: ["ScalarDecimalVerification"])],
  dependencies: [.package(name: "teaql-swift", path: runtimePath)],
  targets: [
    .target(name: "GeneratedTeaQL",
      dependencies: [.product(name: "TeaQLCore", package: "teaql-swift")],
      path: "Generated/Sources/GeneratedTeaQL"),
    .executableTarget(name: "ScalarDecimalVerification", dependencies: [
      "GeneratedTeaQL",
      .product(name: "TeaQLCore", package: "teaql-swift"),
      .product(name: "TeaQLSQLite", package: "teaql-swift"),
      .product(name: "TeaQLTestSupport", package: "teaql-swift"),
    ]),
  ],
  swiftLanguageModes: [.v6]
)
