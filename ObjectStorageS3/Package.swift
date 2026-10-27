// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TeaQLObjectStorageS3",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [.library(name: "TeaQLObjectStorageS3", targets: ["TeaQLObjectStorageS3"])],
  dependencies: [
    .package(name: "TeaQLRuntime", path: ".."),
    .package(url: "https://github.com/soto-project/soto.git", exact: "7.17.0"),
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.36.2"),
  ],
  targets: [
    .target(name: "TeaQLObjectStorageS3", dependencies: [
      .product(name: "TeaQLCore", package: "TeaQLRuntime"),
      .product(name: "SotoS3", package: "soto"),
      .product(name: "AsyncHTTPClient", package: "async-http-client"),
    ]),
    .testTarget(name: "TeaQLObjectStorageS3Tests", dependencies: [
      "TeaQLObjectStorageS3",
      .product(name: "TeaQLCore", package: "TeaQLRuntime"),
      .product(name: "TeaQLSQLite", package: "TeaQLRuntime"),
      .product(name: "TeaQLBlobReference", package: "TeaQLRuntime"),
      .product(name: "SotoS3", package: "soto"),
    ]),
  ],
  swiftLanguageModes: [.v6]
)
