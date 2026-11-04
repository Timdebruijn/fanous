// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreGraphics
import CoreText
import CoreVideo
import FanousEngine
import Foundation
import Logging

/// Clips to judge playback smoothness by eye (`fanous-bench samples`): three looks in folder 254 and the built-in
/// Motion test's layout (0/113) as files in folder 255, at 24–60p and once as HAP Q, so the decode path and the
/// cadence of each rate on the canvas can be held against the generator. Every clip is a seamless 10 s loop, so a
/// hitch at the loop point is the engine's, not the file's. Motion is a fixed distance per second at every rate.
@MainActor
enum SampleMedia {
    struct Clip {
        let path: String
        let fps: Int
        var codec = MovieWriter.Codec.proRes422HQ
        let draw: @MainActor (CGContext, _ frame: Int, _ fps: Int) -> Void
    }

    static let (w, h, seconds) = (1920.0, 1080.0, 10)

    static let clips: [Clip] =
        [
            Clip(path: "254_Looks/001_Lantern glow 60p.mov", fps: 60, draw: glow),
            Clip(path: "254_Looks/002_Coloured glass 60p.mov", fps: 60, draw: glass),
            Clip(path: "254_Looks/003_Stars 60p.mov", fps: 60, draw: stars),
        ]
        + [24, 25, 30, 50, 60].enumerated().map { index, fps in
            Clip(path: "255_Motion test/00\(index + 1)_Motion \(fps)p.mov", fps: fps) { motion($0, frame: $1, fps: $2, label: "\(fps)p ProRes 422 HQ") }
        }
        + [Clip(path: "255_Motion test/006_Motion 60p HAP Q.mov", fps: 60, codec: .hap(.hapQ)) { motion($0, frame: $1, fps: $2, label: "60p HAP Q") }]

    static func generate(into root: URL, logger: Logger) throws {
        // the distances per loop below are whole multiples of each pattern's period
        precondition(seconds * 1920 % Int(w) == 0 && seconds * 960 % 120 == 0 && seconds * 192 % Int(w) == 0, "a clip would not loop seamlessly")
        func refuse(_ reason: String) -> Never {
            print("fanous-bench samples: \(reason)")
            exit(1)
        }
        guard FileManager.default.fileExists(atPath: root.path) else { refuse("no library at \(root.path)") }
        // a folder of the user's with our number would leave one of the two invalid (duplicate folder number)
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter(\.hasDirectoryPath).map(\.lastPathComponent)
        for ours in Set(clips.map { String($0.path.prefix { $0 != "/" }) }) {
            if let theirs = folders.first(where: { $0 != ours && LibraryIndex.prefixNumber($0) == LibraryIndex.prefixNumber(ours) }) {
                refuse("folder number \(LibraryIndex.prefixNumber(ours)!) is taken by \(theirs)")
            }
        }
        for clip in clips {
            let url = root.appending(path: clip.path)
            let partial = url.deletingLastPathComponent().appending(path: "_" + url.lastPathComponent)  // the library ignores `_` names
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let started = Date()
            let writer = try MovieWriter(url: partial, width: Int(w), height: Int(h), fps: Int32(clip.fps), codec: clip.codec)
            try writeFrames(writer, count: seconds * clip.fps) { pixelBuffer, frame in
                let context = CGContext(
                    data: CVPixelBufferGetBaseAddress(pixelBuffer), width: Int(w), height: Int(h), bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                clip.draw(context, frame, clip.fps)
            }
            // rename(2) replaces an earlier run's file in one step: a layer playing it never finds the number missing
            guard rename(partial.path, url.path) == 0 else { refuse("\(clip.path): \(String(cString: strerror(errno)))") }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            logger.info("wrote \(clip.path)", metadata: ["MB": "\(size / 1_000_000)", "seconds": "\(Int(Date().timeIntervalSince(started)))"])
        }
    }

    // MARK: motion test

    /// Shaders.swift kind 113, top to bottom (CG's y runs up), at its speed on a 60 fps 1080p canvas: a bar crossing in
    /// 1 s, stripes scrolling 960 px/s (follow them with the eyes: judder shows as stutter; a 120 px period here, 135 there,
    /// as 135 does not divide a 10 s loop), one cell per frame lit (a long-exposure photo of a run must light every cell once).
    static func motion(_ c: CGContext, frame: Int, fps: Int, label: String) {
        let t = Double(frame) / Double(fps)
        fill(c, CGRect(x: 0, y: 0, width: w, height: h), gray: 0.06)
        let x = (t * 1920).truncatingRemainder(dividingBy: w)
        for dx in [0, -w] { fill(c, CGRect(x: x + dx, y: h * 0.70, width: h * 0.08, height: h * 0.22), gray: 1) }
        fill(c, CGRect(x: 0, y: h * 0.38, width: w, height: h * 0.24), gray: 0.15)
        let shift = (t * 960).truncatingRemainder(dividingBy: 120)
        for k in 0...16 { fill(c, CGRect(x: Double(k) * 120 - shift, y: h * 0.38, width: 60, height: h * 0.24), gray: 0.85) }
        let cell = w * 0.92 / Double(fps)
        for i in 0..<fps {
            c.setFillColor(i == frame % fps ? CGColor(red: 0.2, green: 1, blue: 0.5, alpha: 1) : CGColor(gray: 0.18, alpha: 1))
            c.fill(CGRect(x: w * 0.04 + Double(i) * cell + cell * 0.12, y: h * 0.12, width: cell * 0.88, height: h * 0.16))
        }
        text(c, "\(label)   frame \(String(format: "%3d", frame + 1)) of \(seconds * fps)", x: w * 0.04, y: h * 0.94, size: h * 0.035)
    }

    // MARK: looks

    /// Warm glows drifting right (one or two widths per loop) and bobbing, light breathing twice per loop.
    static func glow(_ c: CGContext, frame: Int, fps: Int) {
        let t = Double(frame) / Double(fps)
        c.setFillColor(CGColor(red: 0.03, green: 0.015, blue: 0.005, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.setBlendMode(.screen)
        for g in glows {
            let x = (g.x + t * 192 * g.speed).truncatingRemainder(dividingBy: w)
            let y = g.y + 60 * sin(2 * .pi * (t / Double(seconds) + g.phase))
            c.setAlpha(0.7 + 0.3 * sin(2 * .pi * (2 * t / Double(seconds) + g.phase)))
            for dx in [-w, 0, w] where abs(x + dx - w / 2) < w / 2 + g.radius {
                let centre = CGPoint(x: x + dx, y: y)
                c.drawRadialGradient(g.gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: g.radius, options: [])
            }
        }
        c.setAlpha(1)
        c.setBlendMode(.normal)
    }

    static let glows: [(x: Double, y: Double, radius: Double, speed: Double, phase: Double, gradient: CGGradient)] = {
        var random = DMXGenerator.SplitMix64(state: 1)
        let colours: [(Double, Double, Double)] = [(1, 0.55, 0.15), (1, 0.75, 0.3), (0.9, 0.3, 0.08), (0.8, 0.15, 0.1)]
        return (0..<9).map { i in
            let (r, g, b) = colours[i % colours.count]
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [CGColor(red: r, green: g, blue: b, alpha: 0.9), CGColor(red: r, green: g, blue: b, alpha: 0)] as CFArray, locations: [0, 1])!
            return (random.unit() * w, 150 + random.unit() * (h - 300), 180 + random.unit() * 300, Double(1 + i % 2), random.unit(), gradient)
        }
    }()

    /// Stained-glass panes in a strip one width wide that wraps, scrolling left one width per loop, lit from behind.
    static func glass(_ c: CGContext, frame: Int, fps: Int) {
        let t = Double(frame) / Double(fps)
        c.setFillColor(CGColor(red: 0.04, green: 0.03, blue: 0.02, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let shift = (t * 192).truncatingRemainder(dividingBy: w)
        for pane in panes {
            for dx in [-shift, w - shift] {
                let rect = pane.rect.offsetBy(dx: dx, dy: 0)
                guard rect.maxX > 0, rect.minX < w else { continue }
                c.saveGState()
                c.clip(to: rect)
                c.drawLinearGradient(pane.gradient, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
                c.restoreGState()
            }
        }
        let centre = CGPoint(x: w / 2, y: h / 2)
        c.setBlendMode(.screen)
        c.setAlpha(0.25 + 0.1 * sin(2 * .pi * 2 * t / Double(seconds)))
        c.drawRadialGradient(lamp, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: h * 0.6, options: [])
        c.setAlpha(1)
        c.setBlendMode(.normal)
        c.drawRadialGradient(vignette, startCenter: centre, startRadius: h * 0.3, endCenter: centre, endRadius: w * 0.6, options: [.drawsAfterEndLocation])
    }

    static let panes: [(rect: CGRect, gradient: CGGradient)] = {
        var random = DMXGenerator.SplitMix64(state: 2)
        let colours: [(Double, Double, Double)] = [
            (0.75, 0.12, 0.1), (0.95, 0.62, 0.12), (0.1, 0.55, 0.35), (0.12, 0.3, 0.75), (0.08, 0.55, 0.62), (0.45, 0.15, 0.55),
        ]
        var panes: [(CGRect, CGGradient)] = []
        // the last pane of a row or column takes the remainder, so none is narrower than `min`
        func span(_ left: Double, _ min: Double, _ range: Double) -> Double { left < 2 * min + range ? left : min + random.unit() * range }
        var x = 0.0
        while x < w {
            let width = span(w - x, 120, 200)
            var y = 0.0
            while y < h {
                let height = span(h - y, 140, 360)
                let (r, g, b) = colours[Int(random.next() % UInt64(colours.count))]
                let gradient = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [CGColor(red: r, green: g, blue: b, alpha: 1), CGColor(red: r * 0.4, green: g * 0.4, blue: b * 0.4, alpha: 1)] as CFArray,
                    locations: [0, 1])!
                panes.append((CGRect(x: x, y: y, width: width, height: height).insetBy(dx: 5, dy: 5), gradient))
                y += height
            }
            x += width
        }
        return panes
    }()

    static let lamp = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [CGColor(red: 1, green: 0.85, blue: 0.6, alpha: 1), CGColor(red: 1, green: 0.85, blue: 0.6, alpha: 0)] as CFArray, locations: [0, 1])!
    static let vignette = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.6)] as CFArray, locations: [0, 1])!

    /// Three layers of stars drifting left at one, two and three widths per loop: sharp points show judder plainly.
    static func stars(_ c: CGContext, frame: Int, fps: Int) {
        let t = Double(frame) / Double(fps)
        c.drawLinearGradient(night, start: CGPoint(x: 0, y: h), end: .zero, options: [])
        for star in starField {
            let radius = [1.2, 2.0, 3.2][star.layer]
            var x = (star.x - t * 192 * Double(star.layer + 1)).truncatingRemainder(dividingBy: w)
            if x < 0 { x += w }
            c.setFillColor(CGColor(red: 1, green: star.warmth, blue: 2 - star.warmth, alpha: [0.45, 0.7, 1][star.layer]))
            for dx in [-w, 0, w] where abs(x + dx - w / 2) < w / 2 + radius {
                c.fillEllipse(in: CGRect(x: x + dx - radius, y: star.y - radius, width: 2 * radius, height: 2 * radius))
            }
        }
    }

    static let starField: [(x: Double, y: Double, layer: Int, warmth: Double)] = {
        var random = DMXGenerator.SplitMix64(state: 3)
        return [360, 120, 40].enumerated().flatMap { layer, count in
            (0..<count).map { _ in (random.unit() * w, random.unit() * h, layer, 0.85 + random.unit() * 0.3) }
        }
    }()

    static let night = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [CGColor(red: 0.02, green: 0.03, blue: 0.09, alpha: 1), CGColor(red: 0, green: 0, blue: 0.01, alpha: 1)] as CFArray, locations: [0, 1])!

    // MARK: drawing

    static func fill(_ c: CGContext, _ rect: CGRect, gray: Double) {
        c.setFillColor(CGColor(gray: gray, alpha: 1))
        c.fill(rect)
    }

    static func text(_ c: CGContext, _ string: String, x: Double, y: Double, size: Double) {
        let font = CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)!
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: string,
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.9, alpha: 1),
                ]))
        c.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, c)
    }
}
