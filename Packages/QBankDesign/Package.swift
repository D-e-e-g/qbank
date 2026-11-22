// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "QBankDesign",
    platforms: [
        .iOS(.v18),
        // macOS only so `swift test` runs on a Mac without a simulator.
        .macOS(.v15),
    ],
    products: [
        .library(name: "QBankDesign", targets: ["QBankDesign"]),
    ],
    targets: [
        .target(
            name: "QBankDesign",
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
        .testTarget(
            name: "QBankDesignTests",
            dependencies: ["QBankDesign"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
    ]
)
