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

/// Live layer thumbnails (B29): the atlas pass draws only while someone wants thumbnails; a layer showing a built-in
/// test pattern yields a non-black JPEG of its cell, an empty layer none.
@Suite(.serialized) struct ThumbnailStreamerTests {
    @Test func aVisibleLayerYieldsAJPEGAnEmptyOneNoneAndNobodyWatchingDrawsNothing() throws {
        let context = try MetalContext()
        let parameters = TripleBuffer { ParameterSnapshotSlot(maxLayers: 2) }
        let compositor = try Compositor(
            context: context, canvasWidth: 320, canvasHeight: 180, fps: 60, maxLayers: 2, metrics: MetricsRing(capacity: 64), parameters: parameters,
            logger: PreviewHubTests.logger)
        let layers = [RenderLayer(index: 0), RenderLayer(index: 1)]
        let grid = try #require(GeneratorSource(context: context, file: 101, width: 320, height: 180))
        layers[0].current = LayerPlayback(key: MediaKey(folder: 0, file: 101), live: grid)
        layers[0].wanted.store(MediaKey(folder: 0, file: 101).packed, ordering: .relaxed)
        compositor.setLayers(layers)
        parameters.write { slot in
            slot.sequence = 1
            slot.layers[0].intensity = 1
            slot.layers[0].folder = 0
            slot.layers[0].file = 101
            slot.layers[0].fitMode = .stretch
            slot.layers[1].intensity = 1  // no media: still nothing to show
        }
        let hub = try PreviewHub(make: PreviewHubTests.make(context, parameters)) { _ in (320, 180) }
        let thumbnails = try ThumbnailStreamer(context: context, compositor: compositor)
        hub.thumbnails = thumbnails
        compositor.previewTap = { [hub] canvas, buffer, target in hub.tap(canvas: canvas, commandBuffer: buffer, target: target) }
        compositor.skipsIdleWork = true
        compositor.previewWanted = { [hub] in hub.wantsFrames }
        let published = Mutex<[[ThumbnailStreamer.Thumb?]]>([])
        thumbnails.onPublish = { set in published.withLock { $0.append(set) } }
        var ticks = 0
        func tick(_ n: Int) {
            for _ in 0..<n {
                compositor.tick(target: 100 + Double(ticks) / 60, drawable: nil)
                ticks += 1
            }
        }

        tick(30)
        #expect(!hub.wantsFrames && thumbnails.passes.load(ordering: .relaxed) == 0, "nobody watches: no atlas pass")
        #expect(compositor.idleTicks.load(ordering: .relaxed) == 30, "and no GPU work at all")

        let rig = try PreviewHubTests.Rig()
        let connection = rig.connection()
        thumbnails.subscribe(connection: connection, stream: 1)
        #expect(hub.wantsFrames)
        tick(30)
        #expect(thumbnails.passes.load(ordering: .relaxed) == 2, "every 15th tick at 60 fps")
        for _ in 0..<200 where published.withLock({ $0.count }) < 2 { usleep(10_000) }
        let set = try #require(published.withLock { $0.last })
        #expect(set.count == 2)
        let thumb = try #require(set[0], "layer 1 shows the grid")
        #expect(thumb.width == 160 && thumb.height == 90)
        #expect(set[1] == nil, "layer 2 has no media: no thumbnail")
        let image = try #require(CGImageSourceCreateWithData(Data(thumb.jpeg) as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width == 160 && image.height == 90)
        #expect(Self.brightest(image) > 128, "the grid's lines are in the cell")
        #expect(thumbnails.jpeg(layer: 0)?.0 == thumb.jpeg, "CITP gets the same JPEG")
        #expect(thumbnails.jpeg(layer: 1).map { $0.1 > 0 && !$0.0.isEmpty } == true, "an empty layer streams black to CITP")

        hub.remove(connection: connection)
        #expect(!hub.wantsFrames)
        tick(30)
        #expect(thumbnails.passes.load(ordering: .relaxed) == 2, "the last subscriber left: no more passes")
    }

    /// The brightest channel value of a decoded image.
    static func brightest(_ image: CGImage) -> Int {
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
