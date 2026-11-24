// swift-tools-version: 6.0
import PackageDescription
let package=Package(name:"ContextDerivedExample",dependencies:[.package(name:"teaql-swift",path:"../../.."), .package(path: "../swift-lib-core")],targets:[.executableTarget(name:"ContextDerivedExample",dependencies:[.product(name: "GeneratedTeaQL", package: "swift-lib-core"),.product(name:"TeaQLCore",package:"teaql-swift"),.product(name:"TeaQLSQLite",package:"teaql-swift")],path:"Sources/ContextDerivedExample")],swiftLanguageModes:[.v6])
