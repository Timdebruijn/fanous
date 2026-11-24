// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Metal
import Testing

@testable import FanousEngine

/// B399: the compositor's swap gives a layer's next file the audio channel its other playback does not hold. Chosen at
/// load (alternating per movie), a load that was replaced before it was shown skipped a channel and the next file landed
/// on the one the current file still played on. Local and self-hosted runs only (Metal, media).
@Suite(.serialized, .cleansTempFiles) struct AudioChannelChoiceTests {
    /// One layer on a 2 s clip with sound, decoders running so a staged file gets its first frame and is swapped in.
    /// Every playback opens the clip for itself: a source and a reader serve one decode thread at a time.
    final class Rig {
        let compositor: Compositor
        let layer = RenderLayer(index: 0)
        let channels = [LayerAudioChannel(), LayerAudioChannel()]
        let url: URL
        let device: MTLDevice
        private var playbacks: [LayerPlayback] = []
        private let parameters: TripleBuffer<ParameterSnapshotSlot>
        private var ticks = 0
        private var sequence: UInt64 = 0
        var dissolve: Float = 0

        init() async throws {
            let directory = try tempDir("fanous-audio-channel-tests")
            url = directory.appending(path: "clip.mov")
            try await IngestQueueTests.writeSource(to: url, seconds: 2, audio: true)
            let context = try MetalContext()
            device = context.device
            (compositor, parameters) = try makeCompositor(context, size: (64, 36), maxLayers: 1, metrics: MetricsRing(capacity: 4096))
            compositor.skipsIdleWork = true
            layer.wanted.store(MediaKey(folder: 1, file: 1).packed, ordering: .relaxed)
            compositor.setLayers([layer])
            publish()
        }

        /// A loaded movie with sound, as the loader hands it over: reader and the layer's channel pair, no channel yet.
        func playback() async throws -> LayerPlayback {
            let source = try await MovieSource.open(url: url, device: device, poolSize: 4)
            let ring = FrameRing(capacity: 4)
            let decoder = LayerDecoder(source: source, ring: ring, logger: testLogger)
            decoder.audioReader = try await AudioTrackReader.open(url: url)
            decoder.audioChannels = channels
            decoder.start(name: "test.decode")
            let playback = LayerPlayback(key: MediaKey(folder: 1, file: 1), movie: source, decoder: decoder, ring: ring)
            playbacks.append(playback)
            return playback
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

        /// Fades to no media (the current becomes the outgoing when `dissolve` > 0).
        func fadeToNothing() {
            layer.pending.withLock { $0.set = true; $0.playback = nil }
            tick()
        }

        func stop() { for p in playbacks { p.stop() } }  // every decoder thread, also those of retired playbacks
    }

    @Test func aReplacedLoadDoesNotPutTheNextFileOnTheCurrentFilesChannel() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        let a = try await rig.playback()
        try await rig.load(a)
        let channelA = try #require(a.audioChannel)
        #expect(rig.channels.contains { $0 === channelA })
        #expect(a.decoder?.audioEnabled.load(ordering: .relaxed) == true)

        // B is loaded and replaced by C before it is shown. At load time B would have taken the other channel and C the
        // one A plays on; chosen at the swap, C gets the one A does not hold.
        let b = try await rig.playback()
        rig.layer.pending.withLock { $0.set = true; $0.playback = b }
        rig.tick()  // B staged (its frame requested, but we do not wait for it)
        let c = try await rig.playback()
        try await rig.load(c)  // C's take retires B (never shown), C is swapped in: a cut, A retired
        #expect(b.audioChannel == nil)  // never on air: never given a channel
        let channelC = try #require(c.audioChannel)
        #expect(channelC !== channelA)
        #expect(a.decoder?.audioEnabled.load(ordering: .relaxed) == false)

        // A dissolve: C stays on air as the outgoing; D must take the other channel.
        rig.dissolve = 1
        rig.publish()
        let d = try await rig.playback()
        try await rig.load(d)
        #expect(rig.layer.outgoing === c)
        let channelD = try #require(d.audioChannel)
        #expect(channelD !== channelC)
        #expect(c.decoder?.audioEnabled.load(ordering: .relaxed) == true && d.decoder?.audioEnabled.load(ordering: .relaxed) == true)
    }

    /// From the review: a fade to no media makes the current the outgoing with no current; a file fired within the fade
    /// must not take the outgoing's channel (the first version chose against the current only).
    @Test func aFileFiredDuringAFadeToNothingAvoidsTheOutgoingsChannel() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        rig.dissolve = 1
        rig.publish()
        let a = try await rig.playback()
        try await rig.load(a)
        let channelA = try #require(a.audioChannel)
        rig.fadeToNothing()
        #expect(rig.layer.current == nil && rig.layer.outgoing === a)
        let b = try await rig.playback()
        try await rig.load(b)
        #expect(rig.layer.outgoing === a)  // still fading
        let channelB = try #require(b.audioChannel)
        #expect(channelB !== channelA)
        #expect(a.decoder?.audioEnabled.load(ordering: .relaxed) == true && b.decoder?.audioEnabled.load(ordering: .relaxed) == true)
    }
}
