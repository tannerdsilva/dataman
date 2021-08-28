// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "dataman",
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
        .package(url:"https://github.com/tannerdsilva/TToolkit.git", .revision("cef8ab267d85d9ff980d96e1caa7ff168a5ff05a")),
        .package(url:"https://github.com/tannerdsilva/Commander.git", .branch("master")),
        .package(url:"https://github.com/tannerdsilva/RapidLMDB.git", .exact("0.9.29")),
        .package(url:"https://github.com/tannerdsilva/SwiftSlash.git", .exact("2.1.2")),
        .package(url:"https://github.com/krzyzanowskim/CryptoSwift.git", .upToNextMinor(from:"1.4.1")),
        .package(url:"https://github.com/crossroadlabs/Regex.git", .exact("1.2.0"))
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "dataman",
            dependencies: ["SwiftSlash", "RapidLMDB", "TToolkit", "Commander", "CryptoSwift", "Regex"]),
        .testTarget(
            name: "datamanTests",
            dependencies: ["dataman"]),
    ]
)
