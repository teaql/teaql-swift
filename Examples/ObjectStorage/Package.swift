// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "TeaQLObjectStorageExample",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(name: "TeaQLRuntime", path: "../.."),
    .package(name: "TeaQLS3Provider", path: "../../ObjectStorageS3"),
    .package(url: "https://github.com/soto-project/soto.git", exact: "7.17.0"),
  ],
  targets: [
    .executableTarget(name: "ObjectStorageExample", dependencies: [
      .product(name: "TeaQLCore", package: "TeaQLRuntime"),
      .product(name: "TeaQLObjectStorageS3", package: "TeaQLS3Provider"),
      .product(name: "SotoS3", package: "soto"),
    ], path: "Sources"),
  ],
  swiftLanguageModes: [.v6]
)
