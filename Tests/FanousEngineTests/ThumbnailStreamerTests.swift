// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreGraphics
import FanousCore
import Foundation
import ImageIO
import Logging
import Metal
import Synchronization
import Testing

@testable import FanousEngine

/// Live layer thumbnails (B29): the atlas pass draws only while someone wants thumbnails, and then the canvas only on
/// pass ticks; a layer showing a built-in test pattern yields a non-black JPEG of its cell, an empty layer none.
@Suite(.serialized) struct ThumbnailStreamerTests {
    /// `count` render layers at 320×180, 60 fps; the grid (101) on layer `grid` (0-based), the others without media.
    final class Rig {
        let compositor: Compositor
        let hub: PreviewHub
        let thumbnails: ThumbnailStreamer
        let published = Mutex<[[ThumbnailStreamer.Thumb?]]>([])
        private var ticks = 0

        init(layers count: Int, grid: Int) throws {
            let context = try MetalContext()
            let parameters = TripleBuffer { ParameterSnapshotSlot(maxLayers: count) }
            compositor = try Compositor(
                context: context, canvasWidth: 320, canvasHeight: 180, fps: 60, maxLayers: count, metrics: MetricsRing(capacity: 64), parameters: parameters,
                logger: PreviewHubTests.logger)
            let layers = (0..<count).map { RenderLayer(index: $0) }
            let generator = try #require(GeneratorSource(context: context, file: 101, width: 320, height: 180))
            layers[grid].current = LayerPlayback(key: MediaKey(folder: 0, file: 101), live: generator)
            layers[grid].wanted.store(MediaKey(folder: 0, file: 101).packed, ordering: .relaxed)
            compositor.setLayers(layers)
            parameters.write { slot in
                slot.sequence = 1
                for i in 0..<count { slot.layers[i].intensity = 1 }  // without media still nothing to show
                slot.layers[grid].folder = 0
                slot.layers[grid].file = 101
                slot.layers[grid].fitMode = .stretch
            }
            hub = try PreviewHub(make: PreviewHubTests.make(context, parameters)) { _ in (320, 180) }
            thumbnails = try ThumbnailStreamer(context: context, compositor: compositor)
            hub.thumbnails = thumbnails
            compositor.previewTap = { [hub] canvas, buffer, target in hub.tap(canvas: canvas, commandBuffer: buffer, target: target) }
            compositor.skipsIdleWork = true
            compositor.previewWanted = { [hub] in hub.wantsFrames }
            thumbnails.onPublish = { [unowned self] set in published.withLock { $0.append(set) } }
        }

        func tick(_ n: Int) {
            for _ in 0..<n {
                compositor.tick(target: 100 + Double(ticks) / 60, drawable: nil)
                ticks += 1
            }
        }

        /// One pass period (15 ticks), then waits until its set is published.
        func pass() throws -> [ThumbnailStreamer.Thumb?] {
            let before = published.withLock { $0.count }
            tick(15)
            for _ in 0..<300 where published.withLock({ $0.count }) == before { usleep(10_000) }
            return try #require(published.withLock { $0.count > before ? $0.last : nil })
        }
    }

    @Test func aVisibleLayerYieldsAJPEGAnEmptyOneNoneAndNobodyWatchingDrawsNothing() throws {
        let rig = try Rig(layers: 2, grid: 0)
        rig.tick(30)
        #expect(rig.thumbnails.passes.load(ordering: .relaxed) == 0, "nobody watches: no atlas pass")
        #expect(rig.compositor.idleTicks.load(ordering: .relaxed) == 30, "and no GPU work at all")

        let connection = try PreviewHubTests.Rig().connection()
        rig.thumbnails.subscribe(connection: connection, stream: 1)
        #expect(rig.thumbnails.wantsFrames)
        _ = try rig.pass()
        let set = try rig.pass()
        #expect(rig.thumbnails.passes.load(ordering: .relaxed) == 2, "every 15th tick at 60 fps")
        #expect(rig.compositor.idleTicks.load(ordering: .relaxed) == 30 + 28, "only thumbnails wanted: the canvas is drawn on pass ticks only")
        #expect(set.count == 2)
        let thumb = try #require(set[0], "layer 1 shows the grid")
        #expect(thumb.width == 160 && thumb.height == 90)
        #expect(set[1] == nil, "layer 2 has no media: no thumbnail")
        #expect(try Self.brightest(thumb) > 128, "the grid's lines are in the cell")
        #expect(rig.thumbnails.jpeg(layer: 0)?.0 == thumb.jpeg, "CITP gets the same JPEG")
        let black = try #require(rig.thumbnails.jpeg(layer: 1))
        #expect(black.1 == 160 && black.2 == 90 && !black.0.isEmpty, "an empty layer streams black at its cell size to CITP")

        rig.hub.remove(connection: connection)
        #expect(!rig.thumbnails.wantsFrames)
        rig.tick(30)
        #expect(rig.thumbnails.passes.load(ordering: .relaxed) == 2, "the last subscriber left: no more passes")
    }

    /// Layer 5 sits in the second atlas row: the crop must find it in the second row.
    @Test func aLayerInTheSecondAtlasRowIsCutFromItsOwnCell() throws {
        let rig = try Rig(layers: 5, grid: 4)
        rig.thumbnails.alwaysEncode = true
        let set = try rig.pass()
        #expect(set.count == 5 && set[0..<4].allSatisfy { $0 == nil })
        let thumb = try #require(set[4])
        #expect(try Self.brightest(thumb) > 128, "the grid of layer 5, not the black slot of the first row")
    }

    /// The brightest RGB value of a JPEG.
    static func brightest(_ thumb: ThumbnailStreamer.Thumb) throws -> Int {
        let image = try #require(CGImageSourceCreateWithData(Data(thumb.jpeg) as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width == thumb.width && image.height == thumb.height)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn: Void? = pixels.withUnsafeMutableBytes { raw in
            CGContext(
                data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?
                .draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return drawn == nil ? 0 : Int(pixels.indices.filter { $0 % 4 != 3 }.map { pixels[$0] }.max() ?? 0)
    }
}
