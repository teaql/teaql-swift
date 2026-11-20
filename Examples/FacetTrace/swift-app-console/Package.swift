// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "teaql-swift-facet-trace-example",
    dependencies: [.package(name: "teaql-swift", path: "../../..")],
    targets: [
        .target(name: "GeneratedTeaQL", dependencies: [
            .product(name: "TeaQLCore", package: "teaql-swift"),
        ], path: "Sources/GeneratedTeaQL"),
        .executableTarget(name: "TeaQLConsole", dependencies: [
            "GeneratedTeaQL",
            .product(name: "TeaQLCore", package: "teaql-swift"),
            .product(name: "TeaQLSQLite", package: "teaql-swift"),
        ], path: "Sources/TeaQLConsole"),
    ],
    swiftLanguageModes: [.v6]
)
