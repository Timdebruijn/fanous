// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import PackageDescription

let package = Package(
    name: "Lanthorn",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LanthornCore", targets: ["LanthornCore"]),
        .library(name: "LanthornEngine", targets: ["LanthornEngine"]),
        .executable(name: "lanthornd", targets: ["lanthornd"]),
        .executable(name: "LanthornShell", targets: ["LanthornShell"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.16.2"),
    ],
    targets: [
        // Pure Swift, Foundation only. Enforced by scripts/core-purity.sh.
        .target(name: "LanthornCore"),
        .target(
            name: "LanthornEngine",
            dependencies: [
                "LanthornCore",
                .product(name: "Logging", package: "swift-log"),
            ]),
        .executableTarget(
            name: "lanthornd",
            dependencies: [
                "LanthornEngine",
                "LanthornCore",
                .product(name: "Logging", package: "swift-log"),
            ]),
        .executableTarget(name: "LanthornShell", dependencies: ["LanthornCore"]),
        .testTarget(name: "LanthornCoreTests", dependencies: ["LanthornCore"]),
    ],
    swiftLanguageModes: [.v6]
)
