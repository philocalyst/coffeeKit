// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "coffeeKit",
  platforms: [.macOS(.v10_15)],
  products: [
    .library(
      name: "coffeeKit",
      targets: ["coffeeKit"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    .package(url: "https://github.com/apple/swift-testing.git", from: "0.7.0"),
  ],
  targets: [
    .target(
      name: "coffeeKit",
      dependencies: [
        .product(name: "Logging", package: "swift-log")
      ]
    )
    // .testTarget(
    //     name: "coffeeKitTests",
    //     dependencies: [
    //         "coffeeKit",
    //         .product(name: "Testing", package: "swift-testing"),
    //     ]
    // ),
  ]
)
