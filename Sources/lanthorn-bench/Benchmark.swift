// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AppKit
import Foundation
import LanthornCore
import LanthornEngine
import Logging

/// Ramps the layer count for one codec/resolution until a frame is missed or
/// late (DESIGN.md §18), then optionally soaks at the last good count.
enum Benchmark {
    struct Step: Codable {
        var layers: Int
        var frames: Int
        var missed: Int
        var late: Int
        var textureMisses: Int
        var cpuP50: Double, cpuP99: Double, cpuMax: Double
        var gpuP50: Double, gpuP99: Double, gpuMax: Double
        /// Growth of malloc blocks in use over the window (all threads); 0 = no steady-state growth.
        var mallocBlocksDelta: Int
        var mallocBytesDelta: Int
        var dmxToPhotonP50: Double
        var dmxToPhotonP99: Double
        var dmxSamples: Int
        var passed: Bool
    }

    struct Result: Codable {
        var chip: String
        var gpu: String
        var memoryGB: Int
        var os: String
        var media: String
        var codec: String
        var width: Int, height: Int, fps: Double
        var display: Int?
        var ringCapacity: Int
        var frameLatency: Int
        var windowSeconds: Double
        var steps: [Step]
        var maxLayers: Int
        var soakSeconds: Double
        var soakStep: Step?
        var date: String
    }

    static func run(
        mediaDirectory: URL, codec: String, resolution: String, maxLayers: Int, window: Double, soak: Double, display: Int?,
        headless: Bool, outputDirectory: URL, onlyLayers: Int? = nil, ringCapacity: Int? = nil, dmx: Bool = false,
        useDisplayLink: Bool = false, logger: Logger
    ) throws {
        let parts = resolution.replacingOccurrences(of: "p", with: "x").split(separator: "x").compactMap { Double($0) }
        guard parts.count == 3 else { throw RenderError.pipeline("resolution must look like 1920x1080p60") }
        let (width, height, fps) = (Int(parts[0]), Int(parts[1]), parts[2])
        let file = mediaDirectory.appending(path: "\(codec)_\(width)x\(height)p\(Int(fps)).mov")
        guard FileManager.default.fileExists(atPath: file.path) else { throw RenderError.pipeline("missing \(file.path); run `lanthorn-bench media` first") }
        let useDisplay = headless ? nil : (display ?? 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let context = try MetalContext()
        let metrics = MetricsRing()
        var dmxStore: DMXStore?
        var artnet: ArtNetReceiver?
        let parameters: TripleBuffer<ParameterSnapshotSlot>
        if dmx {
            let store = DMXStore(patch: Patch.standard(), logger: logger)
            store.start()
            let receiver = ArtNetReceiver(store: store, logger: logger, nodeName: "lanthorn-bench")
            try receiver.start()
            dmxStore = store
            artnet = receiver
            parameters = store.snapshots
            print("DMX mode: send Art-Net to udp/6454 (standard patch: layer n at universe (n-1)/8, address ((n-1)%8)*64+1)")
        } else {
            parameters = TripleBuffer { ParameterSnapshotSlot(maxLayers: 32) }
            parameters.write { slot in
                slot.sequence = 1
                for i in slot.layers.indices { slot.layers[i].intensity = 1 }
            }
        }
        _ = (dmxStore, artnet)  // kept alive for the run
        useDisplayLinkFlag = useDisplayLink
        logger.info("benchmark", metadata: ["file": "\(file.lastPathComponent)", "display": "\(useDisplay.map(String.init) ?? "headless")", "window": "\(window)s", "maxLayers": "\(maxLayers)"])

        Task { @MainActor in
            var result = Result(
                chip: SystemInfo.chipName, gpu: context.deviceName, memoryGB: Int(SystemInfo.physicalMemoryBytes / 1_073_741_824),
                os: SystemInfo.osVersion, media: file.lastPathComponent, codec: codec, width: width, height: height, fps: fps,
                display: useDisplay, ringCapacity: ringCapacity ?? (width > 2000 ? 8 : 6), frameLatency: 1, windowSeconds: window, steps: [], maxLayers: 0, soakSeconds: soak, soakStep: nil,
                date: ISO8601DateFormatter().string(from: Date()))
            do {
                let counts = onlyLayers.map { [$0] } ?? Array(1...maxLayers)
                for count in counts {
                    let step = try await measure(layers: count, seconds: window, file: file, width: width, height: height, fps: fps, display: useDisplay, ringCapacity: ringCapacity, context: context, metrics: metrics, parameters: parameters, logger: logger)
                    result.steps.append(step)
                    print("layers \(count): \(step.passed ? "PASS" : "FAIL")  frames \(step.frames) missed \(step.missed) late \(step.late) textureMisses \(step.textureMisses)  cpu p99 \(String(format: "%.2f", step.cpuP99)) ms  gpu p99 \(String(format: "%.2f", step.gpuP99)) ms  malloc Δ \(step.mallocBlocksDelta) blocks" + (step.dmxSamples > 0 ? String(format: "  dmx→photon p50 %.1f p99 %.1f ms (n=%d)", step.dmxToPhotonP50, step.dmxToPhotonP99, step.dmxSamples) : ""))
                    if step.passed { result.maxLayers = count } else { break }
                }
                if soak > 0, result.maxLayers > 0 {
                    print("soak: \(result.maxLayers) layers for \(Int(soak)) s")
                    let step = try await measure(layers: result.maxLayers, seconds: soak, file: file, width: width, height: height, fps: fps, display: useDisplay, ringCapacity: ringCapacity, context: context, metrics: metrics, parameters: parameters, logger: logger)
                    result.soakStep = step
                    print("soak: \(step.passed ? "PASS" : "FAIL")  missed \(step.missed) late \(step.late)")
                }
                try write(result, to: outputDirectory)
            } catch {
                logger.error("benchmark failed", metadata: ["error": "\(error)"])
                exit(1)
            }
            exit(0)
        }
        app.run()
    }

    nonisolated(unsafe) static var useDisplayLinkFlag = false

    @MainActor
    static func measure(
        layers: Int, seconds: Double, file: URL, width: Int, height: Int, fps: Double, display: Int?, ringCapacity: Int?,
        context: MetalContext, metrics: MetricsRing, parameters: TripleBuffer<ParameterSnapshotSlot>, logger: Logger
    ) async throws -> Step {
        var scene = SceneConfig()
        scene.canvasWidth = width
        scene.canvasHeight = height
        scene.fps = fps
        scene.display = display
        scene.useDisplayLink = useDisplayLinkFlag
        scene.layers = Array(repeating: file.path, count: layers)
        scene.ringCapacity = ringCapacity ?? (width > 2000 ? 8 : 6)
        let service = try RenderService(scene: scene, context: context, parameters: parameters, metrics: metrics, logger: logger)
        try await service.start()
        try await Task.sleep(for: .seconds(2))  // warm-up is not measured
        let start = CACurrentMediaTime()
        let mallocBefore = mallocStatistics()
        try await Task.sleep(for: .seconds(seconds))
        let now = CACurrentMediaTime()
        let mallocAfter = mallocStatistics()
        let summary = metrics.summary(seconds: now - start, now: now)
        let counters = service.counters
        if counters.gpuErrors > 0 || counters.encoderFailures > 0 || counters.outputFailures > 0 || counters.completed < counters.ticks - 2 {
            print("  diagnostics: ticks \(counters.ticks), completed \(counters.completed), gpu errors \(counters.gpuErrors) \(counters.lastError), encoder failures \(counters.encoderFailures)/\(counters.outputFailures)")
        }
        service.stop()
        try await Task.sleep(for: .milliseconds(300))
        return Step(
            layers: layers, frames: summary.frames, missed: summary.missed, late: summary.late, textureMisses: summary.textureMisses,
            cpuP50: summary.cpuP50, cpuP99: summary.cpuP99, cpuMax: summary.cpuMax, gpuP50: summary.gpuP50, gpuP99: summary.gpuP99,
            gpuMax: summary.gpuMax, mallocBlocksDelta: Int(mallocAfter.blocks_in_use) - Int(mallocBefore.blocks_in_use),
            mallocBytesDelta: Int(mallocAfter.size_in_use) - Int(mallocBefore.size_in_use),
            dmxToPhotonP50: summary.dmxP50, dmxToPhotonP99: summary.dmxP99, dmxSamples: summary.dmxSamples,
            passed: summary.missed == 0 && summary.late == 0 && summary.textureMisses == 0 && summary.frames > 0)
    }

    static func mallocStatistics() -> malloc_statistics_t {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return stats
    }

    static func write(_ result: Result, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let slug = result.chip.lowercased().replacingOccurrences(of: " ", with: "-")
        let stamp = String(result.date.prefix(10))
        let single = result.steps.count == 1 ? "-layers\(result.steps[0].layers)" : ""
        let base = "\(slug)-\(result.codec)-\(result.width)x\(result.height)p\(Int(result.fps))-\(result.display == nil ? "headless" : "display")\(single)-\(stamp)"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: directory.appending(path: base + ".json"))
        var md = "# Benchmark: \(result.chip), \(result.media)\n\n"
        md += "- Date: \(result.date)\n- Machine: \(result.chip), \(result.gpu), \(result.memoryGB) GB, \(result.os)\n"
        md += "- Canvas \(result.width)×\(result.height) @ \(result.fps) fps, output: \(result.display.map { "display \($0)" } ?? "headless"), frame latency \(result.frameLatency), ring \(result.ringCapacity) frames/layer\n"
        md += "- Window per step: \(result.windowSeconds) s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses\n\n"
        md += "**Max layers without drops: \(result.maxLayers)**\n\n"
        md += "| Layers | Frames | Missed | Late | Texture misses | CPU p50/p99/max ms | GPU p50/p99/max ms | malloc Δ blocks / KB | Result |\n|---|---|---|---|---|---|---|---|---|\n"
        for s in result.steps {
            md += String(format: "| %d | %d | %d | %d | %d | %.2f / %.2f / %.2f | %.2f / %.2f / %.2f | %d / %d | %@ |\n", s.layers, s.frames, s.missed, s.late, s.textureMisses, s.cpuP50, s.cpuP99, s.cpuMax, s.gpuP50, s.gpuP99, s.gpuMax, s.mallocBlocksDelta, s.mallocBytesDelta / 1024, s.passed ? "pass" : "fail")
        }
        if let dmx = result.steps.last, dmx.dmxSamples > 0 {
            md += String(format: "\nDMX→photon estimate (Art-Net receive → target presentation time): p50 %.1f ms, p99 %.1f ms over %d DMX frames\n", dmx.dmxToPhotonP50, dmx.dmxToPhotonP99, dmx.dmxSamples)
        }
        if let soak = result.soakStep {
            md += String(format: "\nSoak at %d layers for %.0f s: %@ (missed %d, late %d, texture misses %d)\n", soak.layers, result.soakSeconds, soak.passed ? "pass" : "fail", soak.missed, soak.late, soak.textureMisses)
        }
        try md.write(to: directory.appending(path: base + ".md"), atomically: true, encoding: .utf8)
        print("wrote \(directory.appending(path: base + ".md").path)")
    }
}
