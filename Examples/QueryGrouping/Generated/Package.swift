// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "complete-query-fixture-service-swift-lib-core",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "GeneratedTeaQL", targets: ["GeneratedTeaQL"])],
    dependencies: [
        .package(url: "https://github.com/teaql/teaql-swift.git", from: "0.3.1")
    ],
    targets: [
        .target(
            name: "GeneratedTeaQL",
            dependencies: [.product(name: "TeaQLCore", package: "teaql-swift")]
        )
    ],
    swiftLanguageModes: [.v6]
)