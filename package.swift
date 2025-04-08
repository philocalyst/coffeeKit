// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "powerKit",
    platforms: [.macOS(.v10_15)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "powerKit",
            targets: ["powerKit"])
    ],
    dependencies: [.package(url: "https://github.com/apple/swift-log.git", from: "1.5.0")],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "powerKit",  // Your target name
            dependencies: [
                // Add Logging to your target's dependencies
                .product(name: "Logging", package: "swift-log")
            ])

    ]
)
