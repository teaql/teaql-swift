// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "runtime-example-conformance-service-swift-console",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .target(
            name: "GeneratedTeaQL",
            dependencies: [.product(name: "TeaQLCore", package: "teaql-swift")]
        ),
        .executableTarget(
            name: "TeaQLConsole",
            dependencies: [
                "GeneratedTeaQL",
                .product(name: "TeaQLCore", package: "teaql-swift"),
                .product(name: "TeaQLSQLite", package: "teaql-swift"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
