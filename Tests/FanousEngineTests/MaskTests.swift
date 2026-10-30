// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreGraphics
import Foundation
import FanousCore
import ImageIO
import Logging
import Metal
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import FanousEngine

/// Masks v2 (DESIGN.md §9.10 item 5): older projects, the rasteriser, image masks and the render.
struct MaskTests {
    static let release: Bool = {
        #if DEBUG
            false
        #else
            true
        #endif
    }()

    /// Before M2.7, the oracle for "no visible change": under a 2 px feather the compile took CoreGraphics' anti-aliased
    /// even-odd fill of the polygon at every pixel, from 2 px the exact signed distance to it (`MaskMath.raster`) at the
    /// centres of a grid of min(4, feather / 2) px cells, which the shader sampled linearly.
    static func oldRaster(_ path: [MapPoint], feather: Double, width: Int, height: Int) -> (width: Int, height: Int, bytes: [UInt8]) {
        let polygon = path.map { (x: $0.x * Double(width), y: $0.y * Double(height)) }
        guard feather >= 2 else {
            var bytes = [UInt8](repeating: 0, count: width * height)
            bytes.withUnsafeMutableBytes { raw in
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)!
                context.setFillColor(gray: 1, alpha: 1)
                context.translateBy(x: 0, y: CGFloat(height))
                context.scaleBy(x: 1, y: -1)
                for (i, p) in polygon.enumerated() {
                    if i == 0 { context.move(to: CGPoint(x: p.x, y: p.y)) } else { context.addLine(to: CGPoint(x: p.x, y: p.y)) }
                }
                context.closePath()
                context.fillPath(using: .evenOdd)
            }
            return (width, height, bytes)
        }
        let step = min(4, Int(feather / 2))
        let (cols, rows) = ((width + step - 1) / step, (height + step - 1) / step)
        var bytes = [UInt8](repeating: 0, count: cols * rows)
        for i in bytes.indices {
            let (x, y) = ((Double(i % cols) + 0.5) * Double(width) / Double(cols), (Double(i / cols) + 0.5) * Double(height) / Double(rows))
            var inside = false, best = Double.infinity
            for j in polygon.indices {
                let (a, b) = (polygon[j], polygon[(j + polygon.count - 1) % polygon.count])
                if (a.y > y) != (b.y > y), x < a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x) { inside.toggle() }
                let (dx, dy) = (b.x - a.x, b.y - a.y)
                let t = min(1, max(0, ((x - a.x) * dx + (y - a.y) * dy) / (dx * dx + dy * dy)))
                best = min(best, hypot(a.x + t * dx - x, a.y + t * dy - y))
            }
            bytes[i] = UInt8((min(1, max(0, 0.5 + (inside ? best : -best) / feather)) * 255).rounded())
        }
        return (cols, rows, bytes)
    }

    static func area(_ raster: [UInt8]) -> Double { raster.reduce(0) { $0 + Double($1) } / 255 }

    static func square(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [MaskPoint] {
        [MaskPoint(x0, y0), MaskPoint(x1, y0), MaskPoint(x1, y1), MaskPoint(x0, y1)]
    }

    /// A greyscale PNG (DeviceGray, so drawing it back is the identity) of `values`, row-major from the top-left.
    static func writeGrey(_ values: [UInt8], width: Int, height: Int, to url: URL) throws {
        let provider = try #require(CGDataProvider(data: Data(values) as CFData))
        let image = try #require(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    // MARK: Older projects

    /// The polygon and feather of the golden image `output-mask-feather`, as a slice of a project saved before M2.7 had it.
    static let oldSlice = #"{"canvas":1,"dest":[{"x":0,"y":0},{"x":1,"y":0},{"x":1,"y":1},{"x":0,"y":1}],"id":1,"mask":{"feather":24,"path":[{"x":0.5,"y":0.05},{"x":0.95,"y":0.5},{"x":0.5,"y":0.95},{"x":0.05,"y":0.5}]},"opacity":1,"source":{"h":1,"w":1,"x":0,"y":0}}"#
    static let oldWarp = #"{"cornerPin":[{"x":0,"y":0},{"x":1,"y":0},{"x":1,"y":1},{"x":0,"y":1}]}"#
    /// An output as M2.6 saved it: the masked slice, preset 2 with it and preset 3 with `mask: null` (a hand edit).
    static let oldOutput = """
        {"blend":{"bottom":{"gamma":2.2,"overlap":0,"power":2},"left":{"gamma":2.2,"overlap":0,"power":2},"lift":0,"liftFeather":0,\
        "right":{"gamma":2.2,"overlap":0,"power":2},"top":{"gamma":2.2,"overlap":0,"power":2}},"color":{"black":0,"gain":[1,1,1]},"id":1,\
        "intensity":1,"name":"Output 1","slices":[\(oldSlice)],"testPattern":0,"warp":\(oldWarp),"presets":[\
        {"number":2,"name":"Masked","warp":\(oldWarp),"slices":[\(oldSlice)]},\
        {"number":3,"name":"Plain","warp":\(oldWarp),"slices":[\(oldSlice.replacingOccurrences(of: #""mask":{"feather":24,"path":[{"x":0.5,"y":0.05},{"x":0.95,"y":0.5},{"x":0.5,"y":0.95},{"x":0.05,"y":0.5}]}"#, with: #""mask":null"#))]}]}
        """

    static func oldProject() throws -> JSONValue {
        var project = ProjectDocument.initial(patch: .standard(layers: 1, outputs: 1), layerCount: 1, libraryRoot: "/tmp/lib", policy: .dmx)
        try project.set(.array([try JSONDecoder().decode(JSONValue.self, from: Data(oldOutput.utf8))]), at: "/outputs")
        return project
    }

    /// An older project's `mask` becomes `masks` in the document on load, in the edited slices and in every stored preset's
    /// (a null one goes); it renders as before (the golden image of that mask), and preset 2 on Output ch 6 still shows the
    /// mask, which `decodeIfPresent` would have dropped without the conversion.
    @Test func anOlderProjectLoadsRendersAsBeforeAndItsPresetKeepsTheMask() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "fanous-masks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try ProjectDocument.save(try Self.oldProject(), to: url)
        let loaded = try #require(ProjectDocument.load(from: url))
        let output = try #require(loaded["outputs"]?[0])
        let converted: JSONValue = [["mode": "add", "feather": 24, "path": [["x": 0.5, "y": 0.05], ["x": 0.95, "y": 0.5], ["x": 0.5, "y": 0.95], ["x": 0.05, "y": 0.5]]]]
        #expect(output["slices"]?[0]?["masks"] == converted && output["slices"]?[0]?["mask"] == nil)
        #expect(output["presets"]?[0]?["slices"]?[0]?["masks"] == converted && output["presets"]?[0]?["slices"]?[0]?["mask"] == nil)
        #expect(output["presets"]?[1]?["slices"]?[0]?["masks"] == nil && output["presets"]?[1]?["slices"]?[0]?["mask"] == nil, "a null mask goes")
        let config = try #require(ProjectDocument.outputs(from: loaded).first)
        #expect(config.slices[0].masks.count == 1 && config.preset(2)?.slices[0].masks == config.slices[0].masks && config.preset(3)?.slices[0].masks == [])

        let context = try MetalContext()
        let still = try GoldenTests.pattern(device: context.device, variant: 0)
        let plan = try OutputCompiler(device: context.device).compile(config, index: 1, drawable: (OutputPassTests.width, OutputPassTests.height))
        func image(_ preset: UInt8) throws -> [UInt8] {
            OutputPassTests.rgba(
                fromBGRA: try OutputPassTests.render(
                    plan, still: still, drawable: (OutputPassTests.width, OutputPassTests.height), context: context, outputs: [OutputParameters()]) { $0.presets[0] = preset })
        }
        let golden = try #require(GoldenTests.readPNG(OutputPassTests.golden.appending(path: "output-mask-feather.png")))
        let edited = try image(0), masked = try image(2)
        #expect(GoldenTests.compare(edited, golden, name: "edited") == nil, "\(GoldenTests.compare(edited, golden, name: "edited") ?? "")")
        #expect(GoldenTests.compare(masked, golden, name: "preset 2") == nil, "\(GoldenTests.compare(masked, golden, name: "preset 2") ?? "")")
        let plain = OutputPassTests.rgba(
            fromBGRA: try OutputPassTests.render(
                try OutputCompiler(device: context.device).compile(OutputConfig(id: 1), index: 1, drawable: (OutputPassTests.width, OutputPassTests.height)), still: still,
                drawable: (OutputPassTests.width, OutputPassTests.height), context: context))
        #expect(try image(3) == plain, "preset 3 had no mask")
    }

    /// A version revert loads its file like a project (`ProjectDocument.load`), so an older version's mask comes back as
    /// `masks` too.
    @Test func aRevertConvertsTheMask() throws {
        let f = ProjectVersionsTests.make()
        defer { try? FileManager.default.removeItem(at: f.base) }
        f.store.correct(try #require(try Self.oldProject()["outputs"]), at: "/outputs")
        let saved = try #require(try f.store.execute("project.snapshot", args: ["name": "Old masks"], role: .programmer).get().value)
        f.store.correct([], at: "/outputs")
        _ = try f.store.execute("project.revert", args: ["id": try #require(saved["id"])], role: .programmer).get()
        let output = try #require(f.store.project["outputs"]?[0])
        #expect(output["slices"]?[0]?["masks"]?.array?.count == 1 && output["slices"]?[0]?["mask"] == nil)
        #expect(output["presets"]?[0]?["slices"]?[0]?["masks"]?.array?.count == 1 && output["presets"]?[0]?["slices"]?[0]?["mask"] == nil)
    }

    /// `output.set` takes `masks` and validates them; a page loaded before masks v2 still sends `mask`, which is refused
    /// (decoding would drop it silently), also inside a whole slice list.
    @Test func outputSetValidatesMasksAndRefusesTheOldKey() throws {
        let (store, _) = try PresetCommandsTests.makeStore(outputs: 1)
        func set(_ path: String, _ value: JSONValue) -> Result<CommandResult, CommandError> {
            store.execute("output.set", args: ["id": 1, "path": .string(path), "value": value], role: .programmer)
        }
        let triangle: JSONValue = [["x": 0.1, "y": 0.1], ["x": 0.9, "y": 0.1], ["x": 0.5, "y": 0.9, "in": ["x": 0.1, "y": 0]]]
        _ = try set("/slices/0/masks", [["mode": "add", "feather": 4, "path": triangle], ["mode": "subtract", "feather": 0, "image": ["folder": 2, "file": 3]]]).get()
        let masks = PresetCommandsTests.output(store, 1).slices[0].masks
        #expect(masks.count == 2 && masks[0].path?[2].in == MapPoint(0.1, 0) && masks[1].image == MaskImage(folder: 2, file: 3))
        _ = try set("/slices/0/masks/0/path/0", ["x": 0.2, "y": 0.1]).get()
        let kept = PresetCommandsTests.output(store, 1).slices[0].masks
        #expect(kept[0].path?[0] == MaskPoint(0.2, 0.1) && kept[0].path?[2] == masks[0].path?[2])

        let old = "a slice's mask is masks now (masks v2): reload the page"
        #expect(set("/slices/0/mask", ["path": triangle, "feather": 0]) == .failure(.invalidArgs(old)))
        let slice: JSONValue = ["id": 2, "canvas": 1, "source": ["x": 0, "y": 0, "w": 1, "h": 1], "dest": [["x": 0, "y": 0], ["x": 1, "y": 0], ["x": 1, "y": 1], ["x": 0, "y": 1]], "mask": nil, "opacity": 1]
        #expect(set("/slices", [slice]) == .failure(.invalidArgs(old)), "a slice list from the old page")
        #expect(set("/slices/0/masks/0/path", [["x": 0, "y": 0], ["x": 1, "y": 1]]) == .failure(.invalidArgs("slice 1: a mask path needs at least 3 points")))
        #expect(set("/slices/0/masks/1/path", triangle) == .failure(.invalidArgs("slice 1: a mask has either a path or an image")))
        #expect(set("/slices/0/masks/1/image/folder", 0) == .failure(.invalidArgs("slice 1: a mask image needs a library folder and file, 1–255")))
        #expect(set("/slices/0/masks/0/mode", "invert") == .failure(.invalidArgs("/slices/0/masks/0/mode does not fit the output model")))
        #expect(PresetCommandsTests.output(store, 1).slices[0].masks == kept, "nothing refused landed")
    }

    // MARK: Rasteriser

    /// The visible area: the union of the add masks (two overlapping squares cover their union, not the sum), minus the
    /// union of the subtract masks (a hole); everything without an add mask.
    @Test func addsUniteAndSubtractsCutHoles() {
        let w = 64  // edges on whole pixels (binary fractions): the anti-aliased fill is exact
        func raster(_ masks: [MaskShape]) -> [UInt8] { OutputCompiler.maskRaster(masks, width: w, height: w) { _ in nil }.bytes }
        let a = MaskShape(path: Self.square(0.125, 0.125, 0.625, 0.625)), b = MaskShape(path: Self.square(0.375, 0.375, 0.875, 0.875))
        #expect(Self.area(raster([a])) == 1024 && Self.area(raster([a, b])) == 1024 + 1024 - 256, "the union")
        let hole = MaskShape(mode: .subtract, path: Self.square(0.25, 0.25, 0.375, 0.375))
        let holed = raster([a, b, hole])
        #expect(Self.area(holed) == 1792 - 64 && holed[20 * w + 20] == 0 && holed[10 * w + 10] == 255 && holed[50 * w + 50] == 255)
        #expect(Self.area(raster([b, hole, a])) == 1792 - 64, "in any order")
        #expect(Self.area(raster([hole])) == 4096 - 64, "no add mask: everything, minus the hole")
        #expect(raster([]) == [UInt8](repeating: 255, count: w * w))
        // a feathered subtract multiplies: max(adds) × (1 − max(subtracts)), its 8 px ramp centred on x = 16.5, rasterised
        // on its own 4 px grid and resampled to the hard mask's every pixel
        let soft = raster([a, MaskShape(mode: .subtract, feather: 8, path: Self.square(16.5 / 64, 0.125, 0.875, 0.625))])
        let row = (8...24).map { soft[20 * w + $0] }
        #expect(row.first == 255 && row.last == 0 && row == row.sorted(by: >) && abs(Int(soft[20 * w + 16]) - 128) <= 3, "\(row)")
    }

    /// The nonzero rule: a freehand loop that crosses itself (a five-pointed star in one stroke) keeps its middle; the
    /// even-odd rule would punch it out.
    @Test func aSelfCrossingLoopIsFilledByTheNonzeroRule() {
        let star = (0..<5).map { i -> MaskPoint in
            let a = -Double.pi / 2 + Double(i * 2) * 2 * .pi / 5
            return MaskPoint(0.5 + 0.45 * cos(a), 0.5 + 0.45 * sin(a))
        }
        for feather in [0.0, 3] {  // the anti-aliased fill and the feather's, both at every pixel
            let raster = OutputCompiler.maskRaster([MaskShape(feather: feather, path: star)], width: 100, height: 100) { _ in nil }.bytes
            #expect(raster[50 * 100 + 50] == 255, "the middle, feather \(feather)")
            #expect(raster[2 * 100 + 50] == 0 && raster[50 * 100 + 2] == 0)
        }
    }

    /// A Bézier edge: four points with κ ≈ 0.5523 handles fill a circle, π r² within 0.5 % (the flattening's chords are
    /// within a quarter pixel), where the four points alone would fill a square of 2 r².
    @Test func aCircleOfFourCurvedPointsCoversPiRSquared() {
        let (c, r) = (0.5, 0.3), k = 4.0 / 3 * (2.0.squareRoot() - 1) * r
        let circle = [
            MaskPoint(c + r, c, in: MapPoint(0, -k), out: MapPoint(0, k)), MaskPoint(c, c + r, in: MapPoint(k, 0), out: MapPoint(-k, 0)),
            MaskPoint(c - r, c, in: MapPoint(0, k), out: MapPoint(0, -k)), MaskPoint(c, c - r, in: MapPoint(-k, 0), out: MapPoint(k, 0)),
        ]
        let exact = Double.pi * 120 * 120
        for feather in [0.0, 6] {
            let raster = OutputCompiler.maskRaster([MaskShape(feather: feather, path: circle)], width: 400, height: 400) { _ in nil }
            let area = Self.area(raster.bytes) * 400 * 400 / Double(raster.width * raster.height)  // a feather's grid is coarser
            #expect(abs(area - exact) / exact < 0.005, "feather \(feather): \(area) of \(exact) (the ramp is centred on the edge)")
        }
    }

    /// No visible change for existing shows: an old single polygon gives the old raster on the old grid, an edge under 2 px
    /// byte for byte (anti-aliased) and a feathered one within one code value.
    @Test func anOldPolygonGivesTheOldRaster() {
        let polygon = [MapPoint(0.1, 0.12), MapPoint(0.83, 0.07), MapPoint(0.91, 0.66), MapPoint(0.47, 0.93), MapPoint(0.06, 0.58)]
        let (w, h) = (320, 180)
        for feather in [0.0, 1, 2, 6, 24, 32] {
            let new = OutputCompiler.maskRaster([MaskShape(feather: feather, path: polygon.map { MaskPoint($0.x, $0.y) })], width: w, height: h) { _ in nil }
            let old = Self.oldRaster(polygon, feather: feather, width: w, height: h)
            let worst = zip(new.bytes, old.bytes).map { abs(Int($0) - Int($1)) }.max() ?? 0
            #expect(new.width == old.width && new.height == old.height && worst <= (feather < 2 ? 0 : 1), "feather \(feather): \(new.width) × \(new.height), \(worst)")
        }
    }

    /// The budget of §9.10 item 5: a freehand outline of 2,000 segments at 3840 × 2160 within 20 ms of CPU at any feather
    /// (the whole raster: outline, fill and feather), also beside a hard mask, where the feather's own grid is resampled to
    /// every pixel; four hard masks combine in place. A release-build number: `scripts/test.sh -c release --filter
    /// MaskTests`; skipped in debug.
    @Test(.enabled(if: MaskTests.release)) func twoThousandSegmentsAt4KWithin20msAtAnyFeather() {
        let freehand = (0..<2000).map { i -> MaskPoint in
            let a = Double(i) / 2000 * 2 * .pi, wobble = 1 + 0.05 * sin(a * 37)
            return MaskPoint(0.5 + 0.4 * wobble * cos(a), 0.5 + 0.45 * wobble * sin(a))
        }
        func median(_ masks: [MaskShape]) -> Double {
            var times: [Double] = []
            for _ in 0..<5 {
                let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                let raster = OutputCompiler.maskRaster(masks, width: 3840, height: 2160) { _ in nil }
                times.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e6)
                #expect(raster.bytes.count == raster.width * raster.height)
            }
            return times.sorted()[times.count / 2]
        }
        var report: [String] = []
        for feather in [2.0, 3, 8, 32, 33, 200, 1000, 4000] {
            let ms = median([MaskShape(feather: feather, path: freehand)])
            report.append(String(format: "feather %4.0f: %5.1f ms", feather, ms))
            #expect(ms <= 20, "feather \(feather): \(ms) ms")
        }
        let hard = MaskShape(path: Self.square(0.05, 0.05, 0.95, 0.95))
        for feather in [8.0, 200, 4000] {
            let ms = median([hard, MaskShape(mode: .subtract, feather: feather, path: freehand)])
            report.append(String(format: "beside a hard mask, feather %4.0f: %5.1f ms", feather, ms))
            #expect(ms <= 20, "beside a hard mask, feather \(feather): \(ms) ms")
        }
        let (one, four) = (median([hard]), median(Array(repeating: hard, count: 4)))
        report.append(String(format: "one hard mask %.1f ms, four %.1f ms", one, four))
        #expect(four <= 20)
        print("mask raster, 2,000 segments, 3840 × 2160, median CPU of 5:\n  " + report.joined(separator: "\n  "))
    }

    /// An image mask's file is decoded once per file and size (E7 of the M2.7 review): a 4K picture beside a path mask the
    /// operator drags; each drag step rasterises the masks again but finds the picture in the cache. Release only, as above.
    @Test(.enabled(if: MaskTests.release)) func aDragBesideA4KImageMaskDoesNotDecodeItAgain() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "fanous-mask-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let (w, h) = (3840, 2160)
        try Self.writeGrey((0..<(w * h)).map { UInt8(($0 % w) * 255 / w) ^ UInt8(($0 / w) & 0x3f) }, width: w, height: h, to: url)
        let device = try MetalContext().device
        func cpu(_ body: () throws -> Void) rethrows -> Double {
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            try body()
            return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e6
        }
        var config = OutputConfig(id: 1)
        config.slices[0].masks = [MaskShape(mode: .subtract, image: MaskImage(folder: 1, file: 1)), MaskShape(path: Self.square(0.1, 0.1, 0.9, 0.9))]
        let compiler = OutputCompiler(device: device, media: { _ in url })
        var plan = try compiler.compile(config, index: 1, drawable: (w, h))
        let first = try cpu { plan = try OutputCompiler(device: device, media: { _ in url }).compile(config, index: 1, drawable: (w, h)) }
        var steps: [Double] = []
        for i in 1...5 {
            config.slices[0].masks[1].path?[2] = MaskPoint(0.9 - Double(i) / 100, 0.9)
            steps.append(try cpu { plan = try compiler.compile(config, index: 1, drawable: (w, h)) })
        }
        let step = steps.sorted()[2]
        print(String(format: "4K image mask beside a path mask: first compile %.1f ms CPU, a drag step %.1f ms (median of 5)", first, step))
        #expect(step < first)
        withExtendedLifetime(plan) {}
    }

    // MARK: Image masks

    /// An image mask is the file's luminance stretched over the output, with its mode; the feather does not apply. A missing
    /// or unreadable file covers nothing: an add mask adds no area (alone it leaves the slice black), a subtract mask cuts
    /// no hole.
    @Test func anImageMaskIsItsLuminanceAndAMissingOneCoversNothing() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "fanous-mask-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        // four bands of 0, 100, 200 and 255, 4 px each (CoreGraphics stretches an image of a few pixels oddly)
        try Self.writeGrey((0..<(16 * 8)).map { [0, 100, 200, 255][$0 % 16 / 4] }, width: 16, height: 8, to: url)
        let picture = try #require(StillSource.image(url))
        let image = MaskImage(folder: 1, file: 1)
        func raster(_ masks: [MaskShape], file: CGImage?) -> [UInt8] {
            OutputCompiler.maskRaster(masks, width: 64, height: 16) { _ in file.map { OutputCompiler.draw($0, width: 64, height: 16) } }.bytes
        }
        let added = raster([MaskShape(feather: 30, image: image)], file: picture)
        for (x, value) in [(8, 0), (24, 100), (40, 200), (56, 255)] { #expect(abs(Int(added[8 * 64 + x]) - value) <= 2, "x \(x): \(added[8 * 64 + x])") }
        let cut = raster([MaskShape(mode: .subtract, image: image)], file: picture)
        #expect(abs(Int(cut[8 * 64 + 24]) - 155) <= 2 && cut[8 * 64 + 56] == 0, "a subtract mask keeps 1 − luminance")

        #expect(raster([MaskShape(image: image)], file: nil).allSatisfy { $0 == 0 }, "a missing add mask alone: black")
        #expect(raster([MaskShape(mode: .subtract, image: image)], file: nil).allSatisfy { $0 == 255 }, "a missing subtract mask: no hole")
        let square = MaskShape(path: Self.square(0.25, 0.25, 0.75, 0.75))
        #expect(raster([square, MaskShape(image: image)], file: nil) == raster([square], file: nil), "a missing add mask adds nothing")
        #expect(raster([square, MaskShape(mode: .subtract, image: image)], file: nil) == raster([square], file: nil))
        let unreadable = FileManager.default.temporaryDirectory.appending(path: "fanous-mask-\(UUID().uuidString).png")
        try Data("not a picture".utf8).write(to: unreadable)
        defer { try? FileManager.default.removeItem(at: unreadable) }
        #expect(StillSource.image(unreadable) == nil)
    }

    /// The compile cache keys an image mask by its file as it is now: the same file hits, a changed one (the library's
    /// change compiles again) gives a new raster with the new picture, also for the slice plan that holds it. The picture
    /// is decoded once per file: an edit of another mask of the slice finds it in the cache.
    @Test func aChangedFileIsRasterisedAgain() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "fanous-mask-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeGrey([UInt8](repeating: 255, count: 64), width: 8, height: 8, to: url)
        let device = try MetalContext().device
        let file = Mutex<URL?>(url)
        let compiler = OutputCompiler(device: device, media: { _ in file.withLock { $0 } })
        var config = OutputConfig(id: 1)
        config.slices[0].masks = [MaskShape(image: MaskImage(folder: 4, file: 2)), MaskShape(mode: .subtract, path: Self.square(0, 0, 0.25, 0.25))]
        func bytes(_ texture: MTLTexture?) throws -> [UInt8] {
            let texture = try #require(texture)
            var out = [UInt8](repeating: 0, count: texture.width * texture.height)
            texture.getBytes(&out, bytesPerRow: texture.width, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            return out
        }
        let first = try compiler.compile(config, index: 1, drawable: (32, 16))
        #expect(try bytes(first.slices[0].mask)[8 * 32 + 16] == 255 && bytes(first.slices[0].mask)[0] == 0)
        #expect(try compiler.compile(config, index: 1, drawable: (32, 16)).slices[0] === first.slices[0], "the same file: a hit")
        var dragged = config
        dragged.slices[0].masks[1].path?[2] = MaskPoint(0.3, 0.3)
        let drag = try compiler.compile(dragged, index: 1, drawable: (32, 16))
        #expect(drag.slices[0].mask !== first.slices[0].mask && drag.slices[0].images.first === first.slices[0].images.first, "not decoded again")

        try Self.writeGrey([UInt8](repeating: 0, count: 64), width: 8, height: 8, to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
        let changed = try compiler.compile(config, index: 1, drawable: (32, 16))
        #expect(changed.slices[0] !== first.slices[0] && changed.slices[0].mask !== first.slices[0].mask && changed.slices[0].images.first !== first.slices[0].images.first)
        #expect(try bytes(changed.slices[0].mask).allSatisfy { $0 == 0 })
        file.withLock { $0 = nil }  // removed from the library
        #expect(try bytes(compiler.compile(config, index: 1, drawable: (32, 16)).slices[0].mask).allSatisfy { $0 == 0 }, "covers nothing")
        withExtendedLifetime((first, drag)) {}
    }

    /// A file saved over is probed again, and the library has no playable file at its number for that moment: an image
    /// mask still reads it (`LibraryIndex.still`, by the scan), so a door cut out by a subtract mask does not close while
    /// the probe runs. A movie at that number is no image mask.
    @Test func anImageMaskKeepsItsFileWhileTheLibraryProbesIt() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "fanous-masklib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let (root, cache) = (base.appending(path: "root"), base.appending(path: "cache"))
        try FileManager.default.createDirectory(at: root.appending(path: "003_Masks"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let file = root.appending(path: "003_Masks/005_door.png")
        try Self.writeGrey([UInt8](repeating: 255, count: 64), width: 8, height: 8, to: file)
        try Data("not a movie".utf8).write(to: root.appending(path: "003_Masks/006_clip.mov"))
        let library = LibraryIndex(root: root, cacheDirectory: cache, logger: Logger(label: "test"))
        library.start()
        defer { library.stop() }
        let key = MediaKey(folder: 3, file: 5)
        #expect(await waitUntil { library.resolve(key) != nil })
        #expect(library.still(key)?.lastPathComponent == "005_door.png" && library.still(MediaKey(folder: 3, file: 6)) == nil, "a movie is no image mask")
        #expect(library.item(MediaKey(folder: 3, file: 6))?.kind == .movie && library.item(MediaKey(folder: 3, file: 7)) == nil)

        let compiler = OutputCompiler(device: try MetalContext().device, media: { library.still(MediaKey(folder: $0.folder, file: $0.file)) })
        var config = OutputConfig(id: 1)
        config.slices[0].masks = [MaskShape(mode: .subtract, image: MaskImage(folder: 3, file: 5))]
        func centre(_ plan: OutputPlan) throws -> UInt8 {
            let texture = try #require(plan.slices[0].mask)
            var out = [UInt8](repeating: 0, count: texture.width * texture.height)
            texture.getBytes(&out, bytesPerRow: texture.width, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            return out[8 * 16 + 8]
        }
        let before = try compiler.compile(config, index: 1, drawable: (16, 16))
        #expect(try centre(before) == 0, "the door is cut out")
        // saved again as a darker picture, and scanned as FSEvents makes the library do: probing again
        try Self.writeGrey([UInt8](repeating: 200, count: 64), width: 8, height: 8, to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: file.path)
        library.rescan()
        let probing = library.resolve(key) == nil
        let during = try compiler.compile(config, index: 1, drawable: (16, 16))
        #expect(try abs(Int(centre(during)) - 55) <= 2, "the new picture at once\(probing ? ", while probing" : "")")
        withExtendedLifetime(before) {}
    }

    /// A project from before M2.7 whose mask has a negative feather (the old number field kept one, the old raster drew a
    /// hard edge) keeps its mask with no feather, and the output takes other edits.
    @Test func anOldNegativeFeatherIsNone() throws {
        let old = Self.oldOutput.replacingOccurrences(of: #""feather":24"#, with: #""feather":-3"#)
        var project = ProjectDocument.initial(patch: .standard(layers: 1, outputs: 1), layerCount: 1, libraryRoot: "/tmp/lib", policy: .dmx)
        try project.set(.array([try JSONDecoder().decode(JSONValue.self, from: Data(old.utf8))]), at: "/outputs")
        let url = FileManager.default.temporaryDirectory.appending(path: "fanous-masks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try ProjectDocument.save(project, to: url)
        let loaded = try #require(ProjectDocument.load(from: url))
        let config = try #require(ProjectDocument.outputs(from: loaded).first)
        #expect(config.slices[0].masks.map(\.feather) == [0] && config.preset(2)?.slices[0].masks.map(\.feather) == [0])
        #expect(try OutputCompiler(device: MetalContext().device).compile(config, index: 1, drawable: (32, 18)).slices[0].mask != nil)

        let (store, _) = try PresetCommandsTests.makeStore(outputs: 1)
        store.correct(try #require(loaded["outputs"]), at: "/outputs")
        _ = try store.execute("output.set", args: ["id": 1, "path": "/intensity", "value": 0.5], role: .programmer).get()
        _ = try store.execute("output.set", args: ["id": 1, "path": "/slices/0/masks/0/feather", "value": -2], role: .programmer).get()
        #expect(PresetCommandsTests.output(store, 1).intensity == 0.5 && PresetCommandsTests.output(store, 1).slices[0].masks[0].feather == 0)
    }

    /// Readiness warns (never blocks) for every image mask whose file the library lacks, in the edited mapping and in
    /// stored presets.
    @Test func readinessWarnsAboutAMissingImageMask() throws {
        var o = OutputConfig(id: 2)
        o.slices[0].masks = [MaskShape(path: Self.square(0, 0, 1, 1)), MaskShape(mode: .subtract, image: MaskImage(folder: 3, file: 5))]
        o.storePreset(4, name: nil)
        o.slices[0].masks = []
        let found = Engine.imageMasks(in: [OutputConfig(id: 1), o])
        #expect(found.map(\.place) == ["Output 2 preset 4 slice 1"] && found.map(\.image) == [MaskImage(folder: 3, file: 5)])

        var context = ReadinessContext()
        context.maskImagesMissing = ["Output 2 preset 4 slice 1: folder 3 file 5"]
        let item = try #require(Readiness.check(context, acknowledged: []).first { $0.id == "maskimages" })
        #expect(item.state == .warn && !item.blocks && item.detail.contains("Output 2 preset 4 slice 1: folder 3 file 5"))
        #expect(Readiness.check(ReadinessContext(), acknowledged: []).first { $0.id == "maskimages" }?.state == .ok)
    }

    // MARK: Render

    /// The output pass is unchanged: a slice with an add mask and a subtract mask shows its content inside the add mask and
    /// black in the hole and outside.
    @Test func aSubtractMaskShowsAHoleOnTheOutput() throws {
        let context = try MetalContext()
        let still = try OutputPassTests.flat(context.device, value: 200)
        var o = OutputConfig(id: 1)
        o.slices[0].masks = [MaskShape(path: Self.square(0.1, 0.1, 0.9, 0.9)), MaskShape(mode: .subtract, path: Self.square(0.4, 0.4, 0.6, 0.6))]
        let plan = try OutputCompiler(device: context.device).compile(o, index: 1, drawable: (OutputPassTests.width, OutputPassTests.height))
        let image = try OutputPassTests.render(plan, still: still, drawable: (OutputPassTests.width, OutputPassTests.height), context: context)
        func green(_ x: Int, _ y: Int) -> Int { Int(image[(y * OutputPassTests.width + x) * 4 + 1]) }
        #expect(green(80, 90) == 200 && green(240, 30) == 200, "inside the add mask")
        #expect(green(160, 90) == 0, "the hole")
        #expect(green(10, 10) == 0 && green(310, 170) == 0, "outside")
    }
}
