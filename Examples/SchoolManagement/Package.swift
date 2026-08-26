// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "school-management-service-swift-lib-core",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "GeneratedTeaQL", targets: ["GeneratedTeaQL"])],
    dependencies: [
        // Local runtime verification comes before publication. Replace this
        // with the released package URL only for published-artifact verification.
        .package(path: "../..")
    ],
    targets: [
        .target(
            name: "GeneratedTeaQL",
            dependencies: [.product(name: "TeaQLCore", package: "teaql-swift")]
        ),
        .executableTarget(
            name: "SchoolBootstrapVerification",
            dependencies: ["GeneratedTeaQL", .product(name: "TeaQLCore", package: "teaql-swift"), .product(name: "TeaQLSQLite", package: "teaql-swift")]
        )
    ],
    swiftLanguageModes: [.v6]
)
