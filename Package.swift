// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CadMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CadMac", targets: ["CadMac"]),
        .executable(name: "cadmac-mcp", targets: ["CadMacMCP"]),
        .library(name: "CadCore", targets: ["CadCore"]),
    ],
    targets: [
        .target(name: "CadCore"),
        .executableTarget(name: "CadMac", dependencies: ["CadCore"]),
        .executableTarget(name: "CadMacMCP"),
        .testTarget(
            name: "CadCoreTests",
            dependencies: ["CadCore"],
            // Command Line Tools (no Xcode) don't always locate the swift-testing macro plugin.
            swiftSettings: [.unsafeFlags(["-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"])]
        ),
    ]
)
