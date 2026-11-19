// swift-tools-version: 6.0

import PackageDescription

/// The command's name, in one place with the Makefile's `CLI_NAME`: the
/// binaries are `<name>` and `<name>-mcp`.
let cliName = "vedivox"

let package = Package(
    name: "VedivoxMCP",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "\(cliName)-mcp", targets: ["\(cliName)-mcp"]),
        .executable(name: cliName, targets: [cliName]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "VedivoxMCPLib",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources"
        ),
        .executableTarget(
            name: "\(cliName)-mcp",
            dependencies: ["VedivoxMCPLib"],
            path: "SourcesMCPMain"
        ),
        .target(
            name: "VedivoxCLIKit",
            dependencies: [
                "VedivoxMCPLib",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "SourcesCLI"
        ),
        .executableTarget(
            name: cliName,
            dependencies: ["VedivoxCLIKit"],
            path: "SourcesVedivoxMain"
        ),
        .testTarget(
            name: "VedivoxMCPTests",
            dependencies: [
                "VedivoxMCPLib",
                "VedivoxCLIKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests"
        ),
    ]
)
