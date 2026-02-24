// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HomeKitBridge",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "homekit-mcp", targets: ["homekit-mcp"]),
        .executable(name: "homekit-cli", targets: ["homekit-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "homekit-mcp",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .executableTarget(
            name: "homekit-cli",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
