// swift-tools-version: 6.0
import PackageDescription
let package=Package(name:"ContextDerivedExample",dependencies:[.package(name:"teaql-swift",path:"../../..")],targets:[.target(name:"GeneratedTeaQL",dependencies:[.product(name:"TeaQLCore",package:"teaql-swift")],path:"Sources/GeneratedTeaQL"),.executableTarget(name:"ContextDerivedExample",dependencies:["GeneratedTeaQL",.product(name:"TeaQLCore",package:"teaql-swift"),.product(name:"TeaQLSQLite",package:"teaql-swift")],path:"Sources/ContextDerivedExample")],swiftLanguageModes:[.v6])
