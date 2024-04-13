// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CloudKitSyncMonitor",
    defaultLocalization: "en",
    // platforms is set so you can include this package in projects that target iOS 13/macOS 10.15/tvOS 13 without
    // getting errors, but the code in it is marked avaliable only for macOS 11 and iOS 14.
    // It compiles and the tests pass on tvOS 14, but I haven't used it in a tvOS app.
    platforms: [.macOS(.v10_15), .iOS(.v13), .watchOS(.v7), .tvOS(.v13)],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "CloudKitSyncMonitor",
            targets: ["CloudKitSyncMonitor"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "CloudKitSyncMonitor",
            dependencies: [],
            resources: [
                .process("Localizable.xcstrings")
            ]),
        .testTarget(
            name: "CloudKitSyncMonitorTests",
            dependencies: ["CloudKitSyncMonitor"]),
    ]
)
