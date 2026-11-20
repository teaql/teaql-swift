// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "order-attachment-service-swift-console",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "teaql-swift", path: "../../.."), .package(path: "../swift-lib-core"),
        .package(name: "TeaQLS3Provider", path: "../../../ObjectStorageS3"),
        .package(url: "https://github.com/soto-project/soto.git", exact: "7.17.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.1")
    ],
    targets: [
        .executableTarget(
            name: "TeaQLConsole",
            dependencies: [
                .product(name: "GeneratedTeaQL", package: "swift-lib-core"),
                .product(name: "TeaQLCore", package: "teaql-swift"),
                .product(name: "TeaQLSQLite", package: "teaql-swift"),
                .product(name: "TeaQLObjectStorageS3", package: "TeaQLS3Provider"),
                .product(name: "SotoS3", package: "soto"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .executableTarget(
            name: "S3LifecycleCalibration",
            dependencies: [
                .product(name: "TeaQLCore", package: "teaql-swift"),
                .product(name: "TeaQLObjectStorageS3", package: "TeaQLS3Provider"),
                .product(name: "SotoS3", package: "soto"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)