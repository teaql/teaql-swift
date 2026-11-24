// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "trace-chain-service-swift-console",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "teaql-swift", path: "../../.."), .package(path: "../swift-lib-core")
    ],
    targets: [
        .executableTarget(
            name: "TraceChainVerification",
            dependencies: [
                .product(name: "GeneratedTeaQL", package: "swift-lib-core"),
                .product(name: "TeaQLCore", package: "teaql-swift"),
                .product(name: "TeaQLSQLite", package: "teaql-swift")
            ],
            path: "Sources/TeaQLConsole",
            // The generated workspace keeps main.swift; the original program uses @main.
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        .executableTarget(
            name: "StandardTelemetryVerification",
            dependencies: [
                .product(name: "GeneratedTeaQL", package: "swift-lib-core"),
                .product(name: "TeaQLCore", package: "teaql-swift"),
                .product(name: "TeaQLSQLite", package: "teaql-swift"),
                .product(name: "TeaQLStandardTelemetry", package: "teaql-swift")
            ]
        ),
        .executableTarget(
            name: "StandardGraphVerification",
            dependencies: [
                .product(name: "GeneratedTeaQL", package: "swift-lib-core"),
                .product(name: "TeaQLCore", package: "teaql-swift"),
                .product(name: "TeaQLSQLite", package: "teaql-swift"),
                .product(name: "TeaQLStandardTelemetry", package: "teaql-swift")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
