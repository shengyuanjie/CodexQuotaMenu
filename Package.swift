// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexQuotaMenu",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexQuotaMenu", targets: ["CodexQuotaMenu"])
    ],
    targets: [
        .executableTarget(name: "CodexQuotaMenu"),
        .testTarget(name: "CodexQuotaMenuTests", dependencies: ["CodexQuotaMenu"])
    ]
)
