// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dispatch-document-swift-console",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "teaql-swift", path: "../../.."), .package(path: "../swift-lib-core")
    ],
    targets: [
        .executableTarget(
            name: "TeaQLConsole",
            dependencies: [.product(name: "GeneratedTeaQL", package: "swift-lib-core"), .product(name: "TeaQLCore", package: "teaql-swift"), .product(name: "TeaQLSQLite", package: "teaql-swift")]
        )
    ],
    swiftLanguageModes: [.v6]
)