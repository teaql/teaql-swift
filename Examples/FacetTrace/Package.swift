// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "teaql-swift-facet-trace-example",
    dependencies: [.package(name: "teaql-swift", path: "../..")],
    targets: [
        .target(name: "GeneratedTeaQL", dependencies: [
            .product(name: "TeaQLCore", package: "teaql-swift"),
        ], path: "Generated/Sources/GeneratedTeaQL"),
        .executableTarget(name: "FacetAcceptance", dependencies: [
            "GeneratedTeaQL",
            .product(name: "TeaQLCore", package: "teaql-swift"),
            .product(name: "TeaQLSQLite", package: "teaql-swift"),
        ], path: "Application"),
    ],
    swiftLanguageModes: [.v6]
)
