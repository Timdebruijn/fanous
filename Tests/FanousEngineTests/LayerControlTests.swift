// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Metal
import Testing

@testable import FanousEngine

/// B363: the Control channel's "Resync audio" and "Clear error" bands act once, on the tick the band is entered, like
/// Retrigger. Before, both were parsed and handled nowhere. Compositor-level (Metal, a real movie: not hosted).
@Suite(.cleansTempFiles) struct LayerControlTests {
    /// A 2 s 10 fps clip on air on layer 1, its decoder running; `control` sets the Control value of the next tick.
    final class Rig {
        let compositor: Compositor
        let layer = RenderLayer(index: 0)
        let playback: LayerPlayback
        private let parameters: TripleBuffer<ParameterSnapshotSlot>
        private var ticks = 0
        private var sequence: UInt64 = 0

        init() async throws {
            let url = try tempDir("fanous-layer-control-tests").appending(path: "clip.mov")
            try await IngestQueueTests.writeSource(to: url, seconds: 2, audio: false)
            let context = try MetalContext()
            (compositor, parameters) = try makeCompositor(context, size: (64, 36), maxLayers: 1)
            layer.wanted.store(MediaKey(folder: 1, file: 1).packed, ordering: .relaxed)
            compositor.setLayers([layer])
            let source = try await MovieSource.open(url: url, device: context.device, poolSize: 4)
            let ring = FrameRing(capacity: 4)
            let decoder = LayerDecoder(source: source, ring: ring, logger: testLogger)
            decoder.start(name: "test.decode")
            playback = LayerPlayback(key: MediaKey(folder: 1, file: 1), movie: source, decoder: decoder, ring: ring)
            control(.idle)
            layer.pending.withLock { $0.set = true; $0.playback = playback }
            let deadline = Date().addingTimeInterval(5)
            while layer.current !== playback, Date() < deadline {
                tick()
                try await Task.sleep(for: .milliseconds(5))
            }
            if layer.current !== playback { decoder.stop() }
            try #require(layer.current === playback, "the staged file did not get its first frame")
        }

        func control(_ value: LayerControl) {
            sequence += 1
            let sequence = sequence
            parameters.write { slot in  // a whole slot: the triple buffer's slots are not copies of each other
                slot.sequence = sequence
                slot.layers[0].intensity = 1
                slot.layers[0].speed = 1
                slot.layers[0].folder = 1
                slot.layers[0].file = 1
                slot.layers[0].control = value
            }
        }

        func tick() {
            compositor.tick(target: 3600 + Double(ticks) / 60, drawable: nil)
            ticks += 1
        }
    }

    /// Resync audio signals the layer's channel one jump: the producer's next fill drains and reseeks at the clock. While
    /// the value stays in the band nothing more happens. On the old code the fill after the band was entered only topped up.
    @Test func resyncAudioReseeksTheChannelOnceOnTheTickTheBandIsEntered() async throws {
        let rig = try await Rig()
        defer { rig.playback.decoder?.stop() }
        // the test is the producer: the channel hangs on the decoder without its audio enabled, so its thread never fills
        let channel = LayerAudioChannel()
        rig.playback.decoder?.audioChannel = channel
        rig.tick()
        try #require(channel.isActive)
        let source = RampSource()
        var seeks = 0
        func fill(_ wanted: Double) { channel.fill(wanted: wanted, read: { source.read($0, $1) }, seek: { seeks += 1; source.seek($0) }) }
        fill(0)  // the first segment
        AudioTests.pull(channel, frames: 480, wanted: 0)
        #expect(seeks == 1)

        rig.control(.resyncAudio)
        rig.tick()
        fill(0.01)  // the ring holds the old segment: asks for a drain
        AudioTests.pull(channel, frames: 480, wanted: 0.01)  // drains
        fill(0.01)  // the new segment, from the clock
        #expect(seeks == 2, "Resync audio did not reseek the channel")

        rig.tick()  // the value stays: no second jump
        rig.tick()
        fill(channel.nextFramePTS)
        #expect(seeks == 2, "a held Resync audio reseeked again")

        rig.control(.idle)
        rig.tick()
        rig.control(.resyncAudio)  // entered again
        rig.tick()
        fill(channel.nextFramePTS)  // asks for a drain
        AudioTests.pull(channel, frames: 480, wanted: channel.nextFramePTS)
        fill(channel.nextFramePTS)
        #expect(seeks == 3, "entering the band again did not reseek")
    }

    /// Clear error asks the loader once per entry of the band; a held value asks nothing more.
    @Test func clearErrorAsksTheLoaderOnceOnTheTickTheBandIsEntered() async throws {
        let rig = try await Rig()
        defer { rig.playback.decoder?.stop() }
        rig.control(.clearError)
        rig.tick()
        let asked = rig.layer.clearErrorRequested.exchange(false, ordering: .relaxed)
        #expect(asked)
        rig.tick()
        let askedAgain = rig.layer.clearErrorRequested.load(ordering: .relaxed)
        #expect(!askedAgain, "a held Clear error asked again")
        rig.control(.retrigger)  // another band in between
        rig.tick()
        rig.control(.clearError)
        rig.tick()
        let askedOnReentry = rig.layer.clearErrorRequested.load(ordering: .relaxed)
        #expect(askedOnReentry)
    }

    /// The loader's side: Clear error empties the layer's error and opens the failed selection again (B299: before, a
    /// failed open stayed black and was retried only when the selection changed).
    @Test func clearErrorEmptiesTheErrorAndOpensTheFailedSelectionAgain() async throws {
        let opens = MediaLoaderTests.Opens()
        opens.failing.withLock { $0 = ["2.png"] }
        let (loader, layers) = try MediaLoaderTests.loader(layers: 1, opens: opens)
        loader.start()
        defer { loader.stop() }
        MediaLoaderTests.select(layers[0], 2, loader)
        #expect(await waitUntil { MediaLoaderTests.take(layers[0]) == MediaKey(packed: 0) })
        #expect(layers[0].mediaStatus.withLock { $0.error != nil })
        opens.failing.withLock { $0 = [] }  // the volume is back
        try await Task.sleep(for: .milliseconds(300))  // three loader passes: nothing retries by itself
        #expect(opens.started.withLock { $0 } == ["2.png"])
        layers[0].clearErrorRequested.store(true, ordering: .relaxed)  // what the compositor does on the band's edge
        loader.wake.signal()
        #expect(await waitUntil { MediaLoaderTests.take(layers[0]) == MediaKey(folder: 1, file: 2) }, "the failed selection was not opened again")
        #expect(layers[0].mediaStatus.withLock { $0.error == nil && $0.kind == "still" })
        #expect(opens.started.withLock { $0 } == ["2.png", "2.png"])
    }
}
