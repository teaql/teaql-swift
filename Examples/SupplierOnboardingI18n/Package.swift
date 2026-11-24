// swift-tools-version: 6.0
import Foundation
import PackageDescription

let teaqlSource = ProcessInfo.processInfo.environment["TEAQL_SWIFT_EXAMPLE_SOURCE_ROOT"] ?? "../.."
let package = Package(
    name: "supplier-onboarding-service-swift-console",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "teaql-swift", path: teaqlSource)],
    targets: [
        .target(
            name: "GeneratedTeaQL",
            dependencies: [.product(name: "TeaQLCore", package: "teaql-swift")],
            path: "swift-lib-core/Sources/GeneratedTeaQL"
        ),
        .executableTarget(
            name: "TeaQLConsole",
            dependencies: ["GeneratedTeaQL", .product(name: "TeaQLCore", package: "teaql-swift"),
                           .product(name: "TeaQLSQLite", package: "teaql-swift")]
        )
    ],
    swiftLanguageModes: [.v6]
)
