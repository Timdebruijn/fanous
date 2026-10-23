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
        headless: Bool, outputDirectory: URL, logger: Logger
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
        let parameters = TripleBuffer { ParameterSnapshotSlot(maxLayers: 32) }
        parameters.write { slot in
            slot.sequence = 1
            for i in slot.layers.indices { slot.layers[i].intensity = 1 }
        }
        logger.info("benchmark", metadata: ["file": "\(file.lastPathComponent)", "display": "\(useDisplay.map(String.init) ?? "headless")", "window": "\(window)s", "maxLayers": "\(maxLayers)"])

        Task { @MainActor in
            var result = Result(
                chip: SystemInfo.chipName, gpu: context.deviceName, memoryGB: Int(SystemInfo.physicalMemoryBytes / 1_073_741_824),
                os: SystemInfo.osVersion, media: file.lastPathComponent, codec: codec, width: width, height: height, fps: fps,
                display: useDisplay, frameLatency: 1, windowSeconds: window, steps: [], maxLayers: 0, soakSeconds: soak, soakStep: nil,
                date: ISO8601DateFormatter().string(from: Date()))
            do {
                for count in 1...maxLayers {
                    let step = try await measure(layers: count, seconds: window, file: file, width: width, height: height, fps: fps, display: useDisplay, context: context, metrics: metrics, parameters: parameters, logger: logger)
                    result.steps.append(step)
                    print("layers \(count): \(step.passed ? "PASS" : "FAIL")  frames \(step.frames) missed \(step.missed) late \(step.late) textureMisses \(step.textureMisses)  cpu p99 \(String(format: "%.2f", step.cpuP99)) ms  gpu p99 \(String(format: "%.2f", step.gpuP99)) ms  malloc Δ \(step.mallocBlocksDelta) blocks")
                    if step.passed { result.maxLayers = count } else { break }
                }
                if soak > 0, result.maxLayers > 0 {
                    print("soak: \(result.maxLayers) layers for \(Int(soak)) s")
                    let step = try await measure(layers: result.maxLayers, seconds: soak, file: file, width: width, height: height, fps: fps, display: useDisplay, context: context, metrics: metrics, parameters: parameters, logger: logger)
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

    @MainActor
    static func measure(
        layers: Int, seconds: Double, file: URL, width: Int, height: Int, fps: Double, display: Int?, context: MetalContext,
        metrics: MetricsRing, parameters: TripleBuffer<ParameterSnapshotSlot>, logger: Logger
    ) async throws -> Step {
        var scene = SceneConfig()
        scene.canvasWidth = width
        scene.canvasHeight = height
        scene.fps = fps
        scene.display = display
        scene.layers = Array(repeating: file.path, count: layers)
        scene.ringCapacity = width > 2000 ? 4 : 6
        let service = try RenderService(scene: scene, context: context, parameters: parameters, metrics: metrics, logger: logger)
        try await service.start()
        try await Task.sleep(for: .seconds(2))  // warm-up is not measured
        let start = CACurrentMediaTime()
        let mallocBefore = mallocStatistics()
        try await Task.sleep(for: .seconds(seconds))
        let now = CACurrentMediaTime()
        let mallocAfter = mallocStatistics()
        let summary = metrics.summary(seconds: now - start, now: now)
        service.stop()
        try await Task.sleep(for: .milliseconds(300))
        return Step(
            layers: layers, frames: summary.frames, missed: summary.missed, late: summary.late, textureMisses: summary.textureMisses,
            cpuP50: summary.cpuP50, cpuP99: summary.cpuP99, cpuMax: summary.cpuMax, gpuP50: summary.gpuP50, gpuP99: summary.gpuP99,
            gpuMax: summary.gpuMax, mallocBlocksDelta: Int(mallocAfter.blocks_in_use) - Int(mallocBefore.blocks_in_use),
            mallocBytesDelta: Int(mallocAfter.size_in_use) - Int(mallocBefore.size_in_use),
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
        let base = "\(slug)-\(result.codec)-\(result.width)x\(result.height)p\(Int(result.fps))-\(result.display == nil ? "headless" : "display")-\(stamp)"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: directory.appending(path: base + ".json"))
        var md = "# Benchmark: \(result.chip), \(result.media)\n\n"
        md += "- Date: \(result.date)\n- Machine: \(result.chip), \(result.gpu), \(result.memoryGB) GB, \(result.os)\n"
        md += "- Canvas \(result.width)×\(result.height) @ \(result.fps) fps, output: \(result.display.map { "display \($0)" } ?? "headless"), frame latency \(result.frameLatency)\n"
        md += "- Window per step: \(result.windowSeconds) s (after 2 s warm-up); pass = 0 missed, 0 late, 0 texture misses\n\n"
        md += "**Max layers without drops: \(result.maxLayers)**\n\n"
        md += "| Layers | Frames | Missed | Late | Texture misses | CPU p50/p99/max ms | GPU p50/p99/max ms | malloc Δ blocks / KB | Result |\n|---|---|---|---|---|---|---|---|---|\n"
        for s in result.steps {
            md += String(format: "| %d | %d | %d | %d | %d | %.2f / %.2f / %.2f | %.2f / %.2f / %.2f | %d / %d | %@ |\n", s.layers, s.frames, s.missed, s.late, s.textureMisses, s.cpuP50, s.cpuP99, s.cpuMax, s.gpuP50, s.gpuP99, s.gpuMax, s.mallocBlocksDelta, s.mallocBytesDelta / 1024, s.passed ? "pass" : "fail")
        }
        if let soak = result.soakStep {
            md += String(format: "\nSoak at %d layers for %.0f s: %@ (missed %d, late %d, texture misses %d)\n", soak.layers, result.soakSeconds, soak.passed ? "pass" : "fail", soak.missed, soak.late, soak.textureMisses)
        }
        try md.write(to: directory.appending(path: base + ".md"), atomically: true, encoding: .utf8)
        print("wrote \(directory.appending(path: base + ".md").path)")
    }
}
