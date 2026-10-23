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
        .executable(name: "lanthorn-bench", targets: ["lanthorn-bench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.16.2"),
    ],
    targets: [
        // Pure Swift, Foundation only. Enforced by scripts/core-purity.sh.
        .target(name: "LanthornCore"),
        // Vendored C/C++ (ADR-0018): google/snappy 1.3.1 and the Vidvox HAP reference implementation.
        .target(
            name: "CSnappy",
            path: "Sources/CSnappy",
            exclude: ["LICENSE", "VENDORED.md"],
            cxxSettings: [.define("HAVE_SYS_UIO_H", to: "1"), .define("SNAPPY_HAVE_NEON", to: "1")]),
        .target(
            name: "CHap",
            dependencies: ["CSnappy"],
            path: "Sources/CHap",
            exclude: ["LICENSE", "VENDORED.md"]),
        // Vendored Syphon-Framework, Metal path only (ADR-0003, ADR-0018). Public headers in include/Syphon,
        // private ones next to the sources, hence the extra header search path for their quoted imports.
        .target(
            name: "Syphon",
            path: "Sources/Syphon",
            exclude: ["LICENSE", "VENDORED.md"],
            cSettings: [.headerSearchPath("include/Syphon")]),
        .target(
            name: "LanthornEngine",
            dependencies: [
                "LanthornCore",
                "CHap",
                "Syphon",
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
        .executableTarget(
            name: "lanthorn-bench",
            dependencies: [
                "LanthornEngine",
                "LanthornCore",
                .product(name: "Logging", package: "swift-log"),
            ]),
        .testTarget(name: "LanthornCoreTests", dependencies: ["LanthornCore"]),
        // Engine tests that need no display: lock-free hand-off, encoders. Golden images come in Phase 3.
        .testTarget(name: "LanthornEngineTests", dependencies: ["LanthornEngine", "LanthornCore"]),
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx17
)
