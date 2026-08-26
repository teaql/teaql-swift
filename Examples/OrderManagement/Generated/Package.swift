// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "polyglot-order-search-service-swift-lib-core",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "GeneratedTeaQL", targets: ["GeneratedTeaQL"])],
    dependencies: [
        .package(path: "../../..")
    ],
    targets: [
        .target(
            name: "GeneratedTeaQL",
            dependencies: [.product(name: "TeaQLCore", package: "teaql-swift")]
        )
    ],
    swiftLanguageModes: [.v6]
)
