// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "QBankKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "QBankKit", targets: ["QBankKit"])
    ],
    targets: [
        .target(
            name: "QBankKit",
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
        .testTarget(
            name: "QBankKitTests",
            dependencies: ["QBankKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
    ]
)
