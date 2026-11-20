// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "request-tree-order-service-swift-console",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "teaql-swift", path: "../../../..")
    ],
    targets: [
        .target(
            name: "GeneratedTeaQL",
            dependencies: [.product(name: "TeaQLCore", package: "teaql-swift")]
        ),
        .executableTarget(
            name: "StandardOrderVerification",
            dependencies: [
                "GeneratedTeaQL",
                .product(name: "TeaQLCore", package: "teaql-swift"),
                .product(name: "TeaQLSQLite", package: "teaql-swift"),
                .product(name: "TeaQLStandardTelemetry", package: "teaql-swift")
            ],
            path: "Sources/TeaQLConsole"
        )
    ],
    swiftLanguageModes: [.v6]
)
