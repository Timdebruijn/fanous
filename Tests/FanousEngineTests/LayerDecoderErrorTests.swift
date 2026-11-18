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

/// A frame that fails to decode (B278, B342): skipped after a few tries, a failing file backed off and shown in the
/// layer's status, an invalid VideoToolbox session made again. Local only: HAP decode uploads to Metal and ProRes
/// decodes on the GPU's media engine.
@Suite(.serialized, .cleansTempFiles) struct LayerDecoderErrorTests {
    /// A 30-frame 320x176 pattern movie at 25 fps whose `bad` frames have their sample data zeroed (HapDecode refuses
    /// them; VideoToolbox answers a zeroed ProRes frame with an IOKit error, -536870191 here).
    static func movie(_ name: String, codec: MovieWriter.Codec = .hap(.hap), bad: Set<Int>) async throws -> URL {
        let url = try tempDir("fanous-decode-errors").appending(path: name)
        try await writePatternMovie(to: url, size: (320, 176), fps: 25, frames: 30, codec: codec)
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let cursor = try #require(track.makeSampleCursorAtFirstSampleInDecodeOrder())
        var data = try Data(contentsOf: url)
        var index = 0
        repeat {
            if bad.contains(index) {
                let range = cursor.currentSampleStorageRange
                data.resetBytes(in: Int(range.offset)..<Int(range.offset + range.length))
            }
            index += 1
        } while cursor.stepInDecodeOrder(byCount: 1) == 1
        try data.write(to: url)
        return url
    }

    static func capture() -> (Logger, HTTPSServerLogTests.Lines) {
        let lines = HTTPSServerLogTests.Lines()
        return (Logger(label: "test") { _ in HTTPSServerLogTests.Capture(lines: lines) }, lines)
    }

    static func decodeLines(_ lines: HTTPSServerLogTests.Lines) -> [String] { lines.all.withLock { $0 }.filter { $0.hasPrefix("decode") } }

    static func frames(_ ring: FrameRing) -> [Int] { (0..<ring.count).compactMap { ring.peek($0)?.frameIndex } }

    /// One bad frame is skipped and the frame after it arrives, with one log line. Before, the thread tried the same
    /// frame every 50 ms, with a line each time, for as long as the clock stayed within a ring's length of it.
    @Test func aBadFrameIsSkipped() async throws {
        let url = try await Self.movie("one-bad.mov", bad: [10])
        let source = try await MovieSource.open(url: url, device: try #require(MTLCreateSystemDefaultDevice()), poolSize: 4)
        let ring = FrameRing(capacity: 4)
        let (logger, lines) = Self.capture()
        let decoder = LayerDecoder(source: source, ring: ring, logger: logger)
        let reports = Mutex<[String?]>([])
        decoder.failing = { error in reports.withLock { $0.append(error) } }
        decoder.start(name: "test.decode")
        defer { decoder.stop() }
        // as the compositor drives it: frame 9 is shown, the thread fills the ring (it comes back to frame 9 after each
        // try past it), then the clock is at 11 and a slot is free
        decoder.request(frame: 9, direction: 1)
        #expect(await waitUntil(.seconds(3)) { ring.count == 4 }, "the ring fills: \(Self.frames(ring))")
        ring.pop()
        decoder.request(frame: 11, direction: 1)
        #expect(await waitUntil(.seconds(3)) { Self.frames(ring).contains(11) }, "frame 11 arrives: \(Self.frames(ring))")
        #expect(!Self.frames(ring).contains(10))
        let found = Self.decodeLines(lines)
        #expect(found.count == 1 && found.first?.hasPrefix("decode failed, frame skipped") == true, "\(found)")
        #expect(reports.withLock { $0 }.isEmpty, "one skipped frame is not a failing file")
    }

    /// A file whose every frame fails sets the layer's error, as a failed open does (B342; the readiness item "No decoder
    /// errors" reads the same field), and is backed off: two log lines, not one per try. Before: `error` stayed null and
    /// the log got a line every 50 ms.
    @Test func aFailingFileSetsTheLayerErrorAndIsBackedOff() async throws {
        let url = try await Self.movie("all-bad.mov", bad: Set(0..<30))
        let (logger, lines) = Self.capture()
        let layer = RenderLayer(index: 0)
        let loader = MediaLoader(layers: [layer], media: [], device: try #require(MTLCreateSystemDefaultDevice()), ringCapacity: 4, logger: logger)
        loader.resolver = { _ in url }
        loader.start()
        defer { loader.stop() }
        layer.wanted.store(MediaKey(folder: 1, file: 1).packed, ordering: .relaxed)
        loader.wake.signal()
        #expect(await waitUntil(.seconds(3)) { layer.mediaStatus.withLock { $0.error } != nil })
        let status = layer.mediaStatus.withLock { $0 }
        #expect(status.kind == "movie" && status.error == "HapDecode failed (3)", "\(status)")
        try await Task.sleep(for: .milliseconds(500))  // a window to count lines in: there is no end state to wait for
        let found = Self.decodeLines(lines)
        #expect(found.count == 2 && found.first?.hasPrefix("decode failed, frame skipped") == true && found.last?.hasPrefix("decode failing") == true, "\(found)")
    }

    /// The count lines of a failing file come every `reportEvery`, and the first frame that decodes again clears the
    /// error and says so once. Intervals injected: pauses of 50 ms at most, a count every 200 ms.
    @Test func aFailingFileReportsACountAndClearsOnAGoodFrame() async throws {
        let url = try await Self.movie("first-half-bad.mov", bad: Set(0..<15))
        let source = try await MovieSource.open(url: url, device: try #require(MTLCreateSystemDefaultDevice()), poolSize: 4)
        let ring = FrameRing(capacity: 4)
        let (logger, lines) = Self.capture()
        let decoder = LayerDecoder(source: source, ring: ring, logger: logger)
        decoder.longestPause = 0.05
        decoder.reportEvery = 0.2
        let reports = Mutex<[String?]>([])
        decoder.failing = { error in reports.withLock { $0.append(error) } }
        decoder.start(name: "test.decode")
        defer { decoder.stop() }
        decoder.request(frame: 0, direction: 1)  // a paused layer on a bad frame: the same frame is asked for again
        #expect(await waitUntil(.seconds(3)) { Self.decodeLines(lines).contains { $0.hasPrefix("decode still failing") } })
        #expect(reports.withLock { $0.first } == "HapDecode failed (3)")
        decoder.request(frame: 20, direction: 1)
        #expect(await waitUntil(.seconds(3)) { reports.withLock { $0.last } == .some(nil) }, "a good frame clears the error")
        #expect(await waitUntil(.seconds(3)) { ring.count == 4 })
        #expect(Self.frames(ring).allSatisfy { $0 == 20 || $0 == 21 }, "\(Self.frames(ring))")
        let found = Self.decodeLines(lines)
        #expect(found.filter { $0.hasPrefix("decode recovered") }.count == 1, "\(found)")
    }

    /// A VideoToolbox session that went invalid (made so here through the API, as sleep and wake or a GPU reset would,
    /// not measured) is made again once and the frame decodes. Before, every later frame failed with -12903 until the
    /// file was selected again.
    @Test func anInvalidSessionIsMadeAgain() async throws {
        let url = try tempDir("fanous-decode-errors").appending(path: "prores.mov")
        try await writePatternMovie(to: url, size: (320, 176), fps: 25, frames: 4, codec: .proRes422HQ)
        let source = try await MovieSource.open(url: url, device: try #require(MTLCreateSystemDefaultDevice()), poolSize: 1)
        let frame = DecodedFrame(poolIndex: 0)
        try source.decode(frame: 0, into: frame)
        // the session through reflection, so the same test runs against code without a seam
        let wrapped = Mirror(reflecting: source).children.first { $0.label == "session" }?.value
        let object = wrapped.flatMap { Mirror(reflecting: $0).children.first?.value as AnyObject? }
        let session = try #require(object.flatMap { CFGetTypeID($0) == VTDecompressionSessionGetTypeID() ? unsafeBitCast($0, to: VTDecompressionSession.self) : nil })
        VTDecompressionSessionInvalidate(session)
        try source.decode(frame: 1, into: frame)
        #expect(source.sessionRebuilds == 1)
        #expect(try patternBarX(frame, size: (320, 176)) == 8, "frame 1 as drawn on stage")
        try source.decode(frame: 2, into: frame)
        #expect(source.sessionRebuilds == 1, "the new session stays")
    }
}
