// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import Foundation
import LanthornCore
import LanthornEngine
import Logging

func usage() -> Never {
    print(
        """
        usage: lanthorn-bench media --dir DIR [--seconds N] [--only NAME] [--audio]   generate benchmark media (--audio: LPCM test tone track)
               lanthorn-bench spike FILE [--frames N]                       decode a file, report formats and timing
               lanthorn-bench run --media DIR [--codec prores422hq|hapq] [--res 1920x1080p60] [--max-layers N]
                                  [--window SECONDS] [--soak SECONDS] [--display N | --headless] [--out DIR]
                                  [--layers N (single step)] [--ring N (frames per layer ring)]
                                  [--dmx (parameters from Art-Net on 6454; reports DMX-to-photon)] [--displaylink]
                                  [--effects blur,edge (effect slots 1 and 2 on every layer)] [--dissolve SECONDS (permanent crossfades)]
               lanthorn-bench syphon [--app NAME] [--server NAME] [--seconds N] [--out FILE.png]   receive a Syphon server from another process
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

EngineLogging.bootstrap(fileURL: AppPaths.logs.appending(path: "lanthorn-bench.log"))
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
        dissolve: Double(option("--dissolve") ?? "0") ?? 0, logger: logger)
case "syphon":
    try SyphonProbe.run(
        app: option("--app") ?? "lanthornd", server: option("--server") ?? "Lanthorn – Canvas", seconds: Double(option("--seconds") ?? "3") ?? 3,
        output: option("--out").map { URL(fileURLWithPath: $0) })
default:
    usage()
}
