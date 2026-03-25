// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PicoDocs",
    
    defaultLocalization: "en",
    
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
        .visionOS(.v2),
    ],
    
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "PicoDocs",
            targets: ["PicoDocs"]),
    ],
    dependencies: [
        .package(url: "https://github.com/CoreOffice/CoreXLSX", from: "0.14.2"),
        .package(url: "https://github.com/ronaldmannak/EPUBKit", branch: "main"),
        .package(url: "https://github.com/scinfu/SwiftSoup", from: "2.7.6"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "PicoDocs",
            dependencies: [
                .product(name: "CoreXLSX", package: "CoreXLSX"),
                .product(name: "EPUBKit", package: "EPUBKit"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            resources: [
                .process("Localizable.xcstrings"),
                .copy("Parsers/ParserTools/Readability/")
            ]
        ),
        .testTarget(
            name: "PicoDocsTests",
            dependencies: ["PicoDocs"],
            resources: [
                .copy("Resources")
            ]
        ),
    ]
)
