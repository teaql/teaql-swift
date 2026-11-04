// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "teaql-query-grouping-example",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "teaql-swift", path: "../..")],
    targets: [
        .target(
            name: "GeneratedTeaQL",
            dependencies: [.product(name: "TeaQLCore", package: "teaql-swift")],
            path: "Generated/Sources/GeneratedTeaQL"
        ),
        .executableTarget(
            name: "GroupingAliasProbe",
            dependencies: [
                "GeneratedTeaQL",
                .product(name: "TeaQLCore", package: "teaql-swift"),
                .product(name: "TeaQLSQLite", package: "teaql-swift"),
            ],
            path: "Sources"
        ),
    ],
    swiftLanguageModes: [.v6]
)
