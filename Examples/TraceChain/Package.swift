// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "teaql-swift-trace-chain-example",
    dependencies: [
        .package(name: "teaql-swift", path: "../.."),
        .package(name: "generated-trace-chain", path: "Generated"),
    ],
    targets: [
        .executableTarget(name: "TraceChainVerification", dependencies: [
            .product(name: "GeneratedTeaQL", package: "generated-trace-chain"),
            .product(name: "TeaQLCore", package: "teaql-swift"),
            .product(name: "TeaQLSQLite", package: "teaql-swift"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
