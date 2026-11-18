// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import FanousCore
import Foundation
import Logging
import Metal
import Synchronization
import Testing
import VideoToolbox

@testable import FanousEngine

/// A frame that fails to decode (B278, B342): skipped, a failing file shown in the layer's status with a bounded log, an
/// invalid VideoToolbox session made again. Local only: HAP decode uploads to Metal and ProRes decodes on the GPU's
/// media engine.
@Suite(.serialized, .cleansTempFiles) struct LayerDecoderErrorTests {
    /// One clean 16-frame 320x176 HAP pattern movie at 25 fps per run, and where each frame's sample sits in it.
    static let clean = Mutex<(data: Data, samples: [Range<Int>])?>(nil)

    /// A copy of the clean movie whose `bad` frames have their sample data zeroed (HapDecode refuses them).
    static func movie(_ name: String, bad: Set<Int>) async throws -> URL {
        if clean.withLock({ $0 }) == nil {
            let url = try tempDir("fanous-decode-errors").appending(path: "clean.mov")
            try await writePatternMovie(to: url, size: (320, 176), fps: 25, frames: 16, codec: .hap(.hap))
            let samples = try await sampleRanges(url)
            let data = try Data(contentsOf: url)
            clean.withLock { $0 = (data, samples) }
        }
        var (data, samples) = try #require(clean.withLock { $0 })
        for frame in bad { data.resetBytes(in: samples[frame]) }
        let url = try tempDir("fanous-decode-errors").appending(path: name)
        try data.write(to: url)
        return url
    }

    /// The byte range of every sample of the movie's video track, in decode order.
    static func sampleRanges(_ url: URL) async throws -> [Range<Int>] {
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let cursor = try #require(track.makeSampleCursorAtFirstSampleInDecodeOrder())
        var ranges: [Range<Int>] = []
        repeat {
            let range = cursor.currentSampleStorageRange
            ranges.append(Int(range.offset)..<Int(range.offset + range.length))
        } while cursor.stepInDecodeOrder(byCount: 1) == 1
        return ranges
    }

    static func capture() -> (Logger, HTTPSServerLogTests.Lines) {
        let lines = HTTPSServerLogTests.Lines()
        return (Logger(label: "test") { _ in HTTPSServerLogTests.Capture(lines: lines) }, lines)
    }

    static func decodeLines(_ lines: HTTPSServerLogTests.Lines) -> [String] { lines.all.withLock { $0 }.filter { $0.hasPrefix("decode") } }

    static func frames(_ ring: FrameRing) -> [Int] { (0..<ring.count).compactMap { ring.peek($0)?.frameIndex } }

    /// Two isolated bad frames are skipped and the frames after them arrive, with one log line between them (the skip
    /// lines are rate-limited per decoder). Before, the thread tried the first bad frame every 50 ms, with a line each
    /// time, for as long as the clock stayed within a ring's length of it.
    @Test func badFramesAreSkipped() async throws {
        let url = try await Self.movie("two-bad.mov", bad: [10, 12])
        let source = try await MovieSource.open(url: url, device: try #require(MTLCreateSystemDefaultDevice()), poolSize: 4)
        let ring = FrameRing(capacity: 4)
        let (logger, lines) = Self.capture()
        let decoder = LayerDecoder(source: source, ring: ring, logger: logger)
        let reports = Mutex<[String?]>([])
        decoder.failing = { error in reports.withLock { $0.append(error) } }
        decoder.start(name: "test.decode")
        defer { decoder.stop() }
        // as the compositor drives it: frame 9 is shown and the ring fills, then the clock is at 11 and a slot is free,
        // then at 13
        decoder.request(frame: 9, direction: 1)
        #expect(await waitUntil { ring.count == 4 }, "the ring fills: \(Self.frames(ring))")
        for frame in [11, 13] {
            ring.pop()
            decoder.request(frame: frame, direction: 1)
            #expect(await waitUntil { Self.frames(ring).contains(frame) }, "frame \(frame) arrives: \(Self.frames(ring))")
        }
        #expect(!Self.frames(ring).contains(10) && !Self.frames(ring).contains(12))
        let found = Self.decodeLines(lines)
        #expect(found.count == 1 && found.first?.hasPrefix("decode failed, frame skipped") == true, "\(found)")
        #expect(reports.withLock { $0 }.isEmpty, "isolated bad frames are not a failing file")
    }

    /// A file whose every frame fails sets the layer's error, as a failed open does (B342; the readiness item "No decoder
    /// errors" reads the same field), with two log lines, not one per try. Before: `error` stayed null and the log got a
    /// line every 50 ms. The loader's decoder runs with the real `failingAfter` (half a second).
    @Test func aFailingFileSetsTheLayerError() async throws {
        let url = try await Self.movie("all-bad.mov", bad: Set(0..<16))
        let (logger, lines) = Self.capture()
        let layer = RenderLayer(index: 0)
        let loader = MediaLoader(layers: [layer], media: [], device: try #require(MTLCreateSystemDefaultDevice()), ringCapacity: 4, logger: logger)
        loader.resolver = { _ in url }
        loader.start()
        defer { loader.stop() }
        layer.wanted.store(MediaKey(folder: 1, file: 1).packed, ordering: .relaxed)
        loader.wake.signal()
        #expect(await waitUntil { layer.mediaStatus.withLock { $0.error } != nil })
        let status = layer.mediaStatus.withLock { $0 }
        #expect(status.kind == "movie" && status.error == "HapDecode failed (3)", "\(status)")
        try await Task.sleep(for: .milliseconds(200))  // a window to count lines in: there is no end state to wait for
        let found = Self.decodeLines(lines)
        #expect(found.count == 2 && found.first?.hasPrefix("decode failed, frame skipped") == true && found.last?.hasPrefix("decode failing") == true, "\(found)")
    }

    /// A failing file logs a count every `reportEvery`, and the first frame that decodes again clears the error, says so
    /// once and is shown. Intervals injected: failing after 50 ms, a count every 100 ms.
    @Test func aFailingFileReportsACountAndClearsOnAGoodFrame() async throws {
        let url = try await Self.movie("first-half-bad.mov", bad: Set(0..<8))
        let source = try await MovieSource.open(url: url, device: try #require(MTLCreateSystemDefaultDevice()), poolSize: 4)
        let ring = FrameRing(capacity: 4)
        let (logger, lines) = Self.capture()
        let decoder = LayerDecoder(source: source, ring: ring, logger: logger)
        decoder.failingAfter = 0.05
        decoder.reportEvery = 0.1
        let reports = Mutex<[String?]>([])
        decoder.failing = { error in reports.withLock { $0.append(error) } }
        decoder.start(name: "test.decode")
        defer { decoder.stop() }
        decoder.request(frame: 0, direction: 1)  // a paused layer on a bad frame: the same frame is asked for again
        #expect(await waitUntil { Self.decodeLines(lines).contains { $0.hasPrefix("decode still failing") } })
        #expect(reports.withLock { $0.first } == "HapDecode failed (3)")
        #expect(Self.decodeLines(lines).filter { $0.hasPrefix("decode failing") }.count == 1)
        let still = Self.decodeLines(lines).first { $0.hasPrefix("decode still failing") } ?? ""
        #expect(still.contains("linesHeldBack=0"), "a count line held back nothing: \(still)")
        decoder.request(frame: 10, direction: 1)
        #expect(await waitUntil { reports.withLock { $0.last } == .some(nil) }, "a good frame clears the error")
        #expect(await waitUntil { Self.frames(ring).contains(10) }, "the good frame is there to show: \(Self.frames(ring))")
        #expect(Self.decodeLines(lines).filter { $0.hasPrefix("decode recovered") }.count == 1, "\(Self.decodeLines(lines))")
    }

    /// A VideoToolbox session that went invalid (made so here through the API, as sleep and wake or a GPU reset would,
    /// not measured) is made again and the frame decodes; a second one within `rebuildEvery` is not. Before, every later
    /// frame failed with -12903 until the file was selected again.
    @Test func anInvalidSessionIsMadeAgain() async throws {
        let url = try tempDir("fanous-decode-errors").appending(path: "prores.mov")
        try await writePatternMovie(to: url, size: (320, 176), fps: 25, frames: 4, codec: .proRes422HQ)
        let source = try await MovieSource.open(url: url, device: try #require(MTLCreateSystemDefaultDevice()), poolSize: 1)
        let (logger, lines) = Self.capture()
        source.logger = logger
        source.rebuildEvery = 3600  // the second invalidation below falls inside the interval however slow the Mac
        let frame = DecodedFrame(poolIndex: 0)
        try source.decode(frame: 0, into: frame)
        // the session through reflection, so the same test runs against code without a seam
        func invalidate() throws {
            let wrapped = Mirror(reflecting: source).children.first { $0.label == "session" }?.value
            let object = wrapped.flatMap { Mirror(reflecting: $0).children.first?.value as AnyObject? }
            let session = try #require(object.flatMap { CFGetTypeID($0) == VTDecompressionSessionGetTypeID() ? unsafeDowncast($0, to: VTDecompressionSession.self) : nil })
            VTDecompressionSessionInvalidate(session)
        }
        try invalidate()
        try source.decode(frame: 1, into: frame)
        #expect(source.sessionRebuilds == 1)
        #expect(lines.all.withLock { $0 }.filter { $0.hasPrefix("decoder session made again") }.count == 1)
        #expect(try patternBarX(frame, size: (320, 176)) == 8, "frame 1 as drawn on stage")
        try invalidate()
        #expect(throws: MovieError.self) { try source.decode(frame: 2, into: frame) }
        #expect(source.sessionRebuilds == 1, "at most one new session per interval")
    }
}
