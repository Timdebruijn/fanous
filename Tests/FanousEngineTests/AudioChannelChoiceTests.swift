// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Testing

@testable import FanousEngine

/// B399: the compositor's swap gives a layer's next file the audio channel its other playback does not hold. Chosen at
/// load (alternating per movie), a load that was replaced before it was shown skipped a channel and the next file landed
/// on the one the current file still played on. Local and self-hosted runs only (Metal, media).
@Suite(.serialized, .cleansTempFiles) struct AudioChannelChoiceTests {
    /// One layer on a 2 s clip with sound, decoders running so a staged file gets its first frame and is swapped in.
    final class Rig {
        let compositor: Compositor
        let layer = RenderLayer(index: 0)
        let channels = [LayerAudioChannel(), LayerAudioChannel()]
        let source: MovieSource
        let reader: AudioTrackReader
        private let parameters: TripleBuffer<ParameterSnapshotSlot>
        private var ticks = 0
        private var sequence: UInt64 = 0
        var dissolve: Float = 0

        init() async throws {
            let directory = try tempDir("fanous-audio-channel-tests")
            let url = directory.appending(path: "clip.mov")
            try await IngestQueueTests.writeSource(to: url, seconds: 2, audio: true)
            let context = try MetalContext()
            source = try await MovieSource.open(url: url, device: context.device, poolSize: 4)
            reader = try await AudioTrackReader.open(url: url)
            (compositor, parameters) = try makeCompositor(context, size: (64, 36), maxLayers: 1, metrics: MetricsRing(capacity: 4096))
            compositor.skipsIdleWork = true
            layer.wanted.store(MediaKey(folder: 1, file: 1).packed, ordering: .relaxed)
            compositor.setLayers([layer])
            publish()
        }

        /// A loaded movie with sound, as the loader hands it over: reader and the layer's channel pair, no channel yet.
        func playback() -> LayerPlayback {
            let ring = FrameRing(capacity: 4)
            let decoder = LayerDecoder(source: source, ring: ring, logger: testLogger)
            decoder.audioReader = reader
            decoder.audioChannels = channels
            decoder.start(name: "test.decode")
            return LayerPlayback(key: MediaKey(folder: 1, file: 1), movie: source, decoder: decoder, ring: ring)
        }

        func publish() {
            sequence += 1
            let sequence = sequence, dissolve = dissolve
            parameters.write { slot in
                slot.sequence = sequence
                slot.layers[0].intensity = 1
                slot.layers[0].folder = 1
                slot.layers[0].file = 1
                slot.layers[0].dissolve = dissolve
            }
        }

        /// Hands `playback` to the compositor as the loader does, and ticks until it is current (its first frame decoded).
        func load(_ playback: LayerPlayback) async throws {
            layer.pending.withLock { $0.set = true; $0.playback = playback }
            tick()  // taken: staged, first frame requested
            let deadline = Date().addingTimeInterval(5)
            while layer.current !== playback, Date() < deadline {
                try await Task.sleep(for: .milliseconds(5))
                tick()
            }
            try #require(layer.current === playback, "the staged file did not get its first frame")
        }

        func tick() {
            compositor.tick(target: 3600 + Double(ticks) / 60, drawable: nil)
            ticks += 1
        }

        func stop() { for p in [layer.current, layer.outgoing, layer.staged] { p?.stop() } }
    }

    @Test func aReplacedLoadDoesNotPutTheNextFileOnTheCurrentFilesChannel() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        let a = rig.playback()
        try await rig.load(a)
        let channelA = try #require(a.audioChannel)
        #expect(rig.channels.contains { $0 === channelA })
        #expect(a.decoder?.audioEnabled.load(ordering: .relaxed) == true)

        // B is loaded and replaced by C before it is shown. At load time B would have taken the other channel and C the
        // one A plays on; chosen at the swap, C gets the one A does not hold.
        let b = rig.playback()
        rig.layer.pending.withLock { $0.set = true; $0.playback = b }
        rig.tick()  // B staged (its frame requested, but we do not wait for it)
        let c = rig.playback()
        try await rig.load(c)  // C's take retires B (never shown), C is swapped in: a cut, A retired
        #expect(b.audioChannel == nil)  // never on air: never given a channel
        let channelC = try #require(c.audioChannel)
        #expect(channelC !== channelA)
        #expect(a.decoder?.audioEnabled.load(ordering: .relaxed) == false)
        b.stop()
        a.stop()

        // A dissolve: C stays on air as the outgoing; D must take the other channel.
        rig.dissolve = 1
        rig.publish()
        let d = rig.playback()
        try await rig.load(d)
        #expect(rig.layer.outgoing === c)
        let channelD = try #require(d.audioChannel)
        #expect(channelD !== channelC)
        #expect(c.decoder?.audioEnabled.load(ordering: .relaxed) == true && d.decoder?.audioEnabled.load(ordering: .relaxed) == true)
    }
}
