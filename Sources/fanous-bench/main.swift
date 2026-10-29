// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import Foundation
import FanousCore
import FanousEngine
import Logging

func usage() -> Never {
    print(
        """
        usage: fanous-bench media --dir DIR [--seconds N] [--only NAME] [--audio]   generate benchmark media (--audio: LPCM test tone track)
               fanous-bench spike FILE [--frames N]                       decode a file, report formats and timing
               fanous-bench run --media DIR [--codec prores422hq|hapq] [--res 1920x1080p60] [--max-layers N]
                                  [--window SECONDS] [--soak SECONDS] [--display N | --headless] [--out DIR]
                                  [--layers N (single step)] [--ring N (frames per layer ring)]
                                  [--dmx (parameters from Art-Net on 6454; reports DMX-to-photon)] [--displaylink]
                                  [--effects blur,edge (effect slots 1 and 2 on every layer)] [--dissolve SECONDS (permanent crossfades)]
                                  [--ingest FILE (transcode FILE to HAP Q in-process during the window)]
               fanous-bench dmx [--layers N] [--files N] [--hz 40] [--seconds N] [--host 127.0.0.1] [--seed N]   soak traffic: Art-Net at the standard patch
        """)
    exit(64)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }
arguments.removeFirst()

@MainActor func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
@MainActor func flag(_ name: String) -> Bool { arguments.contains(name) }

EngineLogging.bootstrap(fileURL: AppPaths.logs.appending(path: "fanous-bench.log"))
let logger = Logger(label: "bench")

switch command {
case "media":
    guard let dir = option("--dir") else { usage() }
    let seconds = Double(option("--seconds") ?? "3") ?? 3
    let only = option("--only")
    try MediaGenerator.generate(into: URL(fileURLWithPath: dir), seconds: seconds, only: only, audio: flag("--audio"), logger: logger)
case "spike":
    guard let file = arguments.first else { usage() }
    let frames = Int(option("--frames") ?? "120") ?? 120
    MovieSource.serialHAPDecode = flag("--serial-hap")
    try DecodeSpike.run(file: URL(fileURLWithPath: file), frames: frames, logger: logger)
case "run":
    guard let media = option("--media") else { usage() }
    try Benchmark.run(
        mediaDirectory: URL(fileURLWithPath: media), codec: option("--codec") ?? "prores422hq",
        resolution: option("--res") ?? "1920x1080p60", maxLayers: Int(option("--max-layers") ?? "16") ?? 16,
        window: Double(option("--window") ?? "60") ?? 60, soak: Double(option("--soak") ?? "0") ?? 0,
        display: option("--display").flatMap(Int.init), headless: flag("--headless"),
        outputDirectory: URL(fileURLWithPath: option("--out") ?? "docs/benchmarks"),
        onlyLayers: option("--layers").flatMap(Int.init), ringCapacity: option("--ring").flatMap(Int.init),
        dmx: flag("--dmx"), useDisplayLink: flag("--displaylink"),
        effects: (option("--effects") ?? "").split(separator: ",").compactMap { name in Effect.allCases.first { "\($0)" == name } },
        dissolve: Double(option("--dissolve") ?? "0") ?? 0, ingest: option("--ingest").map { URL(fileURLWithPath: $0) }, logger: logger)
case "dmx":
    DMXGenerator.run(
        layers: Int(option("--layers") ?? "4") ?? 4, files: Int(option("--files") ?? "4") ?? 4, hz: Double(option("--hz") ?? "40") ?? 40,
        seconds: Double(option("--seconds") ?? "3600") ?? 3600, host: option("--host") ?? "127.0.0.1", seed: UInt64(option("--seed") ?? "1") ?? 1)
default:
    usage()
}
