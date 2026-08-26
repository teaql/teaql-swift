// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "teaql-order-management-example",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../.."),
        .package(path: "Generated"),
    ],
    targets: [
        .executableTarget(
            name: "teaql-order-management",
            dependencies: [
                .product(name: "TeaQLCore", package: "teaql-swift"),
                .product(name: "TeaQLSQLite", package: "teaql-swift"),
                .product(name: "GeneratedTeaQL", package: "Generated"),
            ],
            path: "Sources"
        )
    ],
    swiftLanguageModes: [.v6]
)
