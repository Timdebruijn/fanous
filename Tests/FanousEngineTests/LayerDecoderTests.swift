// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Logging
import Metal
import QuartzCore
import Synchronization
import Testing

@testable import FanousEngine

/// The decode thread sleeps on a full ring and is only woken by a changed request or a freed slot; it fills the ring
/// ahead of the requested frame in play direction (B364).
@Suite(.serialized, .cleansTempFiles) struct LayerDecoderTests {
    /// B294: a started decoder decodes nothing until the compositor's first request, and then that frame first: the
    /// loader used to ask for frame 0 at start, so a file cut in at an in point or in a reverse mode showed frame 0 first.
    @Test func decodesNothingBeforeTheFirstRequestAndThatFrameFirst() async throws {
        let directory = try tempDir("fanous-ingest-tests")
        let url = directory.appending(path: "clip.mov")
        try await IngestQueueTests.writeSource(to: url, seconds: 2, audio: false)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = try await MovieSource.open(url: url, device: device, poolSize: 4)
        let ring = FrameRing(capacity: 4)
        let decoder = LayerDecoder(source: source, ring: ring, logger: testLogger)
        decoder.start(name: "test.decode")
        defer { decoder.stop() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(ring.isEmpty && decoder.decoded.load(ordering: .relaxed) == 0, "decoded before any request")
        decoder.request(frame: 7, direction: -1)  // a 20-frame clip
        await waitUntil { ring.count == 4 }
        #expect(ring.peek(0)?.frameIndex == 7, "the first frame is the requested one")
        #expect(ring.peek(1)?.frameIndex == 6, "and the next ones follow in play direction")
    }

    /// B319: the decode thread runs at ADR-0002's class, above the control plane's `.userInitiated`.
    @Test func theDecodeThreadIsUserInteractive() async throws {
        let (_, decoder) = try await layer(frames: 4, capacity: 2)
        defer { decoder.stop() }
        #expect(decoder.thread?.qualityOfService == .userInteractive)
    }

    /// B319 measurement, `FANOUS_BENCH=1`: a 1080p ProRes 422 HQ clip decoded as fast as the ring is emptied (a
    /// `.userInteractive` consumer, as the compositor is) for 2 s, alone and with twice as many spinning
    /// `.userInitiated` threads as cores. Prints frames per second and the longest gap between two frames.
    @Test(.offPool, .enabled(if: ProcessInfo.processInfo.environment["FANOUS_BENCH"] != nil))
    func printDecodeRateUnderLoad() async throws {
        let url = try tempDir("fanous-ingest-tests").appending(path: "clip.mov")
        let frames = 50
        try await writePatternMovie(to: url, size: (1920, 1080), fps: 25, frames: frames)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = try await MovieSource.open(url: url, device: device, poolSize: 5)
        let ring = FrameRing(capacity: 4)
        let decoder = LayerDecoder(source: source, ring: ring, logger: testLogger)
        decoder.start(name: "test.decode")
        defer { decoder.stop() }
        func run(_ label: String) {
            let done = DispatchSemaphore(value: 0)
            let consumer = Thread {
                var popped = 0, maxGap = 0.0
                let start = CACurrentMediaTime()
                var last = start
                decoder.request(frame: 0, direction: 1)
                while CACurrentMediaTime() - start < 2 {
                    guard !ring.isEmpty else {
                        usleep(100)
                        continue
                    }
                    let now = CACurrentMediaTime()
                    maxGap = max(maxGap, now - last)
                    last = now
                    ring.pop()
                    popped += 1
                    decoder.request(frame: popped % frames, direction: 1)
                }
                print(String(format: "B319 decode %@: %.1f frames/s, longest gap %.1f ms", label, Double(popped) / 2, maxGap * 1000))
                done.signal()
            }
            consumer.qualityOfService = .userInteractive
            consumer.start()
            done.wait()
        }
        func loaded() {
            let spinning = Atomic<Bool>(true)
            let threads = ProcessInfo.processInfo.activeProcessorCount * 2
            let stopped = DispatchSemaphore(value: 0)
            for _ in 0..<threads {
                let thread = Thread {
                    var x = 0.0
                    while spinning.load(ordering: .relaxed) { x += 1 }
                    if x < 0 { print(x) }
                    stopped.signal()
                }
                thread.qualityOfService = .userInitiated
                thread.start()
            }
            run("with \(threads) spinning .userInitiated threads")
            spinning.store(false, ordering: .relaxed)
            for _ in 0..<threads { stopped.wait() }
        }
        run("alone")
        loaded()
    }

    @Test func aFullRingSleepsUntilTheRequestChanges() async throws {
        let directory = try tempDir("fanous-ingest-tests")
        let url = directory.appending(path: "clip.mov")
        try await IngestQueueTests.writeSource(to: url, seconds: 2, audio: false)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = try await MovieSource.open(url: url, device: device, poolSize: 4)
        let ring = FrameRing(capacity: 4)
        let decoder = LayerDecoder(source: source, ring: ring, logger: testLogger)
        decoder.start(name: "test.decode")
        defer { decoder.stop() }

        decoder.request(frame: 0, direction: 1)
        await waitUntil { ring.count == 4 }
        #expect(ring.count == 4, "the ring fills")

        // a paused layer asks for the same frame every tick: one wake-up for the first request, none after
        let wakeups = decoder.wakeups.load(ordering: .relaxed)
        for _ in 0..<300 { decoder.request(frame: 0, direction: 1) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(decoder.wakeups.load(ordering: .relaxed) == wakeups, "identical requests wake nobody")
        let decodedWhileAsleep = decoder.decoded.load(ordering: .relaxed)
        try await Task.sleep(for: .milliseconds(200))
        #expect(decoder.decoded.load(ordering: .relaxed) == decodedWhileAsleep, "a full ring decodes nothing")

        // a new frame wakes it: the compositor popped a slot, the thread refills it
        ring.pop()
        decoder.request(frame: 1, direction: 1)
        await waitUntil { ring.count == 4 }
        #expect(ring.count == 4, "refilled after the wake-up")
        #expect(decoder.wakeups.load(ordering: .relaxed) == wakeups + 1)

        // and a direction change is a request of its own
        decoder.request(frame: 1, direction: -1)
        #expect(decoder.wakeups.load(ordering: .relaxed) == wakeups + 2)
    }

    /// Plays the clock's `frames` in `direction` with a clock the test controls: each tick asks for its frame once the
    /// decode thread has filled the ring, as a decoder faster than the clip's rate does. A tick in `unseen` requests
    /// but draws nothing (a layer at intensity 0 keeps its decoder fed). Returns the frame shown on each drawn tick and
    /// the ring's frame numbers just before it.
    private func play(
        _ playback: LayerPlayback, _ decoder: LayerDecoder, _ frames: [Int], direction: Int, unseen: Set<Int> = []
    ) async -> (shown: [Int], rings: [[Int]]) {
        var shown: [Int] = []
        var rings: [[Int]] = []
        for (tick, frame) in frames.enumerated() {
            decoder.request(frame: frame, direction: direction)
            await waitUntil(.seconds(2)) { decoder.ring.count == decoder.ring.capacity }
            guard !unseen.contains(tick) else { continue }
            rings.append((0..<decoder.ring.count).compactMap { decoder.ring.peek($0)?.frameIndex })
            shown.append(playback.frame(at: frame, direction: direction)?.frameIndex ?? -1)
        }
        return (shown, rings)
    }

    private func layer(frames: Int, capacity: Int) async throws -> (LayerPlayback, LayerDecoder) {
        let url = try tempDir("fanous-ingest-tests").appending(path: "clip.mov")
        try await writePatternMovie(to: url, size: (128, 64), fps: 25, frames: frames)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = try await MovieSource.open(url: url, device: device, poolSize: capacity)
        let ring = FrameRing(capacity: capacity)
        let decoder = LayerDecoder(source: source, ring: ring, logger: testLogger)
        decoder.start(name: "test.decode")
        return (LayerPlayback(key: MediaKey(packed: 1), movie: source, decoder: decoder, ring: ring), decoder)
    }

    /// The ring holds consecutive frames in play direction, each once.
    private func consecutive(_ ring: [Int], direction: Int, count: Int) -> Bool {
        zip(ring, ring.dropFirst()).allSatisfy { ($0.1 - $0.0 - direction) % count == 0 }
    }

    @Test func playingForwardShowsEveryFrameAcrossTheLoop() async throws {
        let (playback, decoder) = try await layer(frames: 20, capacity: 8)
        defer { decoder.stop() }
        let (shown, rings) = await play(playback, decoder, (0..<30).map { $0 % 20 }, direction: 1)
        // the old fill alternated the requested frame and the next one, and the layer held the second for 10 frames
        #expect(shown == (0..<30).map { $0 % 20 }, "the shown frame follows the clock, also past the loop")
        #expect(rings.allSatisfy { $0.count == 8 && consecutive($0, direction: 1, count: 20) }, "\(rings)")
    }

    @Test func playingInReverseShowsEveryFrameAcrossTheLoop() async throws {
        let (playback, decoder) = try await layer(frames: 20, capacity: 8)
        defer { decoder.stop() }
        let (shown, rings) = await play(playback, decoder, (0..<30).map { (19 - $0 + 20) % 20 }, direction: -1)
        #expect(shown == (0..<30).map { (19 - $0 + 20) % 20 }, "the shown frame follows the clock backwards")
        #expect(rings.allSatisfy { $0.count == 8 && consecutive($0, direction: -1, count: 20) }, "\(rings)")
    }

    @Test func aSeekLandsOnTheRequestedFrame() async throws {
        let (playback, decoder) = try await layer(frames: 40, capacity: 8)
        defer { decoder.stop() }
        _ = await play(playback, decoder, Array(0..<5), direction: 1)
        // a jump past the ring: what is buffered is on the wrong side, the ring drains and the thread restarts there
        decoder.request(frame: 30, direction: 1)
        _ = playback.frame(at: 30, direction: 1)
        let (shown, rings) = await play(playback, decoder, [30, 31, 32], direction: 1)
        #expect(shown == [30, 31, 32])
        #expect(rings.last == Array(30...37), "filled ahead from the requested frame")
    }

    // With a ring that holds frames ahead, the shown frame must reach the clock's frame on the tick it is asked for,
    // also when the clock moves more than one frame per tick (B364 review: the pick looked at the first 3 ring frames
    // only, the shown frame moved at most one frame per tick and fell behind for good)
    @Test func twoFramesPerTickShowTheClocksFrames() async throws {
        let (playback, decoder) = try await layer(frames: 40, capacity: 8)
        defer { decoder.stop() }
        let clock = (0..<30).map { $0 * 2 % 40 }
        let (shown, _) = await play(playback, decoder, clock, direction: 1)
        #expect(shown == clock)
    }

    @Test func aSkippedFrameDoesNotLeaveTheLayerLate() async throws {
        let (playback, decoder) = try await layer(frames: 40, capacity: 8)
        defer { decoder.stop() }
        let clock = Array(0...9) + Array(11...29)
        let (shown, _) = await play(playback, decoder, clock, direction: 1)
        #expect(shown == clock)
    }

    @Test func aLayerUnseenForAFewTicksComesBackOnTheClock() async throws {
        let (playback, decoder) = try await layer(frames: 40, capacity: 8)
        defer { decoder.stop() }
        let clock = Array(0..<30)
        // 4 ticks unseen: the ring kept the frames up to 5 past the last shown one (and that one and the one before)
        let (shown, _) = await play(playback, decoder, clock, direction: 1, unseen: Set(10..<14))
        #expect(shown == Array(0..<10) + Array(14..<30))
    }

    // A step back (a position set by a sync master or timecode): one frame back is the previously shown frame, still in
    // the ring; three back finds every ring frame ahead of the clock, and the pick must not take the farthest of them:
    // the ring drains, the last shown frame holds for that tick, the thread restarts at the request
    @Test func aStepBackLandsOnTheRequestedFrame() async throws {
        let (playback, decoder) = try await layer(frames: 40, capacity: 8)
        defer { decoder.stop() }
        _ = await play(playback, decoder, Array(0..<10), direction: 1)
        let (back1, _) = await play(playback, decoder, [8, 9, 10], direction: 1)
        #expect(back1 == [8, 9, 10])
        let (back3, _) = await play(playback, decoder, [7, 8, 9], direction: 1)
        #expect(back3 == [10, 8, 9], "\(back3)")
    }
}
