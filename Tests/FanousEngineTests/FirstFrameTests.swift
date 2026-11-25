// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Metal
import QuartzCore
import Testing

@testable import FanousEngine

/// B294: the first frame a file shows is its start position (the in point, or the out point in a reverse mode), not
/// frame 0. The loader used to ask the decoder for frame 0 before the compositor's hand-off asked for the start, so the
/// ring's first frames were 0, 1, 2 and the swap drew them. B404: a sync slave's start is its master's position and
/// direction, a timecode chase's the chased frame. Compositor-level, a real movie and decoder (GPU: not hosted).
@Suite(.cleansTempFiles) struct FirstFrameTests {
    @Test(arguments: [(PlayMode.loopForward, 0.5 as Float, 10), (PlayMode.loopReverse, 0 as Float, 19)])
    func theFirstFrameShownIsTheStartPosition(mode: PlayMode, inPoint: Float, expected: Int) async throws {
        let (playback, _) = try await onAir(mode: mode, inPoint: inPoint)
        defer { playback.decoder?.stop() }
        #expect(playback.holdFrameIndex == expected, "first frame shown: \(playback.holdFrameIndex), expected \(expected)")
    }

    /// B404: the hand-off asked for the slave's own start (frame 0, or 19 backwards in a reverse mode); the swap tick set
    /// the clock to the master's frame 12, found nothing near it in the ring and held a frame of the wrong start.
    @Test(arguments: [(Int8(1), PlayMode.loopForward, 13), (Int8(-1), PlayMode.loopReverse, 11), (Int8(1), PlayMode.loopReverse, 13)])
    func aSlavesFirstFrameIsItsMastersFrame(masterDirection: Int8, mode: PlayMode, next: Int) async throws {
        let receiver = SyncReceiver(machine: UUID(), logger: testLogger)
        let sender = SyncSender(machine: UUID(), settings: SyncSettings(), network: false, logger: testLogger)
        // a remote master parked at frame 12 of the same 10 fps clip, sending every tick
        let master = SyncPacket.Layer(group: 1, layer: 7, mediaKey: 0x0101, fps: 10, position: 12, direction: masterDirection, finished: false, rate: 0)
        let remote = UUID()
        let (playback, ring) = try await onAir(mode: mode, sync: .slave(group: 1), setUp: { $0.sync = (receiver, sender) }) { _ in
            receiver.table.withLock { $0.offer(master, from: remote, at: CACurrentMediaTime()) }
        }
        defer { playback.decoder?.stop() }
        #expect(playback.holdFrameIndex == 12, "first frame shown: \(playback.holdFrameIndex), expected the master's 12")
        // the ring fills on in the master's direction, not the slave's own play mode's
        let deadline = Date().addingTimeInterval(5)
        while ring.count < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(ring.peek(1)?.frameIndex == next, "next frame decoded: \(ring.peek(1)?.frameIndex ?? -1), expected \(next)")
    }

    /// B404: the hand-off asked for the in point (frame 0); the swap tick chased to frame 12 and held one of 0...3.
    @Test func aChasesFirstFrameIsTheChasedFrame() async throws {
        let clock = TimecodeClock()
        // timecode standing at 00:00:01:05 (frame 30 at 25 fps) = 1.2 s = frame 12 of the 10 fps clip
        let (playback, _) = try await onAir(mode: .timecode, setUp: { $0.timecode = clock }) { target in
            clock.update(Timecode(frameCount: 30, rate: .fps25), at: target, source: "test")
        }
        defer { playback.decoder?.stop() }
        #expect(playback.holdFrameIndex == 12, "first frame shown: \(playback.holdFrameIndex), expected the chased 12")
    }

    /// Stages a 20-frame 10 fps clip on layer 1 and ticks until it is on air; returns it on the very tick the swap drew
    /// it, its decoder still running (the caller stops it). `setUp` runs before the first tick, `everyTick` before each,
    /// with that tick's target.
    private func onAir(
        mode: PlayMode, inPoint: Float = 0, sync: LayerSync = .off, setUp: (Compositor) -> Void = { _ in },
        everyTick: (Double) -> Void = { _ in }
    ) async throws -> (LayerPlayback, FrameRing) {
        let directory = try tempDir("fanous-first-frame-tests")
        let url = directory.appending(path: "clip.mov")
        try await IngestQueueTests.writeSource(to: url, seconds: 2, audio: false)  // 20 frames at 10 fps: the in point 0.5 is frame 10, the end 19
        let context = try MetalContext()
        let layer = RenderLayer(index: 0)
        let (compositor, parameters) = try makeCompositor(context, size: (64, 36), maxLayers: 1)
        compositor.skipsIdleWork = true
        setUp(compositor)
        layer.wanted.store(MediaKey(folder: 1, file: 1).packed, ordering: .relaxed)
        compositor.setLayers([layer])
        parameters.write { slot in
            slot.sequence = 1
            slot.layers[0].intensity = 1
            slot.layers[0].folder = 1
            slot.layers[0].file = 1
            slot.layers[0].playMode = mode
            slot.layers[0].inPoint = inPoint
            slot.layers[0].sync = sync
        }
        let source = try await MovieSource.open(url: url, device: context.device, poolSize: 4)
        let ring = FrameRing(capacity: 4)
        let decoder = LayerDecoder(source: source, ring: ring, logger: testLogger)
        decoder.start(name: "test.decode")  // as the loader does: no request of its own
        let playback = LayerPlayback(key: MediaKey(folder: 1, file: 1), movie: source, decoder: decoder, ring: ring)
        // the loader's latency to the compositor's next tick: a decoder that starts at frame 0 fills the ring with 0...3
        // meanwhile and the swap draws one of them; a decoder that waits for the request decodes nothing yet
        try await Task.sleep(for: .milliseconds(100))
        #expect(ring.isEmpty, "decoded before the hand-off asked for the start frame")
        layer.pending.withLock { $0.set = true; $0.playback = playback }
        var ticks = 0
        func tick() {
            let target = 3600 + Double(ticks) / 60
            everyTick(target)
            compositor.tick(target: target, drawable: nil)
            ticks += 1
        }
        // tick until the file is on air, and read the frame of that very tick: the one the swap drew
        let deadline = Date().addingTimeInterval(5)
        while layer.current !== playback, Date() < deadline {
            tick()
            if layer.current !== playback { try await Task.sleep(for: .milliseconds(5)) }
        }
        if layer.current !== playback { decoder.stop() }
        try #require(layer.current === playback, "the staged file did not get its first frame")
        return (playback, ring)
    }
}
