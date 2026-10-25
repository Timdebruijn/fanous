// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import PackageDescription

let package = Package(
    name: "Fanous",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FanousCore", targets: ["FanousCore"]),
        .library(name: "FanousEngine", targets: ["FanousEngine"]),
        .executable(name: "fanousd", targets: ["fanousd"]),
        .executable(name: "FanousShell", targets: ["FanousShell"]),
        .executable(name: "fanous-bench", targets: ["fanous-bench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.16.2"),
    ],
    targets: [
        // Pure Swift, Foundation only. Enforced by scripts/core-purity.sh.
        .target(name: "FanousCore"),
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
            name: "FanousEngine",
            dependencies: [
                "FanousCore",
                "CHap",
                "Syphon",
                .product(name: "Logging", package: "swift-log"),
            ]),
        .executableTarget(
            name: "fanousd",
            dependencies: [
                "FanousEngine",
                "FanousCore",
                .product(name: "Logging", package: "swift-log"),
            ]),
        .executableTarget(name: "FanousShell", dependencies: ["FanousCore"]),
        .executableTarget(
            name: "fanous-bench",
            dependencies: [
                "FanousEngine",
                "FanousCore",
                .product(name: "Logging", package: "swift-log"),
            ]),
        .testTarget(name: "FanousCoreTests", dependencies: ["FanousCore"]),
        // Engine tests that need no display: lock-free hand-off, encoders. Golden images come in Phase 3.
        .testTarget(name: "FanousEngineTests", dependencies: ["FanousEngine", "FanousCore"]),
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx17
)
