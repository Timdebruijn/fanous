// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Logging
import Metal
import Testing
import UniformTypeIdentifiers

@testable import FanousEngine

/// Serialized: `IngestQueue.stop()` parks the test's cooperative-pool thread until the worker exits, and a worker that is
/// just loading an asset needs a pool thread itself; ten tests parked there at once would starve it.
@Suite(.serialized) struct IngestQueueTests {
    // MARK: Helpers

    /// 320×176 ProRes 422 HQ with the `TestTone` track, 10 fps (20 frames: HAP Q encoding is slow in a debug build).
    static let sourceFPS: Int32 = 10
    static func writeSource(to url: URL, seconds: Int = 2, audio: Bool = true) async throws {
        try await offPool { try writeSourceBlocking(to: url, seconds: seconds, audio: audio) }
    }

    private static func writeSourceBlocking(to url: URL, seconds: Int, audio: Bool) throws {
        let writer = try MovieWriter(url: url, width: 320, height: 176, fps: sourceFPS, codec: .proRes422HQ, audio: audio)
        for frame in 0..<(seconds * Int(sourceFPS)) {
            try writer.append(try Self.patternBuffer(pool: writer.pixelBufferPool, frame: frame))
        }
        try writer.finish()
    }

    static func patternBuffer(pool: CVPixelBufferPool?, frame: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) } else { CVPixelBufferCreate(nil, 320, 176, kCVPixelFormatType_32BGRA, nil, &buffer) }
        guard let buffer else { throw MovieWriter.WriterError.failed("pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        PatternFrames.fill(
            bgra: CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self), width: 320, height: 176,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), frame: frame)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// A 1 s, 25 fps H.264 `.mp4` (320×176) written with AVAssetWriter, with a 1 s 440 Hz mono AAC track at 44.1 kHz
    /// (what a phone records: not 48 kHz, not stereo, not LPCM).
    /// H.264 with one second of a 440 Hz tone: AAC 44.1 kHz mono, or (`floatAudio`) LPCM 96 kHz stereo 32-bit float.
    /// `presentationTimes` replaces the 25 frames at 25 fps (variable rate: one pattern frame per time given).
    /// `timescale` sets the video track's media timescale (1000 is what an OBS remux has; the times are then rounded to ms).
    /// `alpha` writes ProRes 4444 (in a .mov) with the right half of every frame transparent instead of H.264.
    /// `transform` tags the track (`preferredTransform`); `rotated` is the 90° clockwise tag of a phone held upright.
    static func writeH264(
        to url: URL, rotated: Bool = false, transform: CGAffineTransform? = nil, floatAudio: Bool = false, fiveOne: Bool = false, pixelAspect: (Int, Int)? = nil,
        presentationTimes: [CMTime]? = nil, timescale: CMTimeScale? = nil, alpha: Bool = false
    ) async throws {
        try await offPool {
            try writeH264Blocking(
                to: url, transform: transform ?? (rotated ? CGAffineTransform(rotationAngle: .pi / 2) : nil), floatAudio: floatAudio, fiveOne: fiveOne, pixelAspect: pixelAspect,
                presentationTimes: presentationTimes, timescale: timescale, alpha: alpha)
        }
    }

    private static func writeH264Blocking(
        to url: URL, transform: CGAffineTransform?, floatAudio: Bool, fiveOne: Bool, pixelAspect: (Int, Int)?, presentationTimes: [CMTime]?,
        timescale: CMTimeScale?, alpha: Bool
    ) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: floatAudio || fiveOne || alpha ? .mov : .mp4)
        // fiveOne: 48 kHz 16-bit 5.1 (MPEG order L R C LFE Ls Rs), channel i a constant (i + 1) × 3000 (B143)
        var fiveOneLayout = AudioChannelLayout()
        fiveOneLayout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A
        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: floatAudio
                ? [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 96_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                ]
                : fiveOne
                    ? [
                        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 6, AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                        AVChannelLayoutKey: Data(bytes: &fiveOneLayout, count: MemoryLayout<AudioChannelLayout>.size),
                    ]
                    : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
        audioInput.expectsMediaDataInRealTime = false
        writer.add(audioInput)
        var videoSettings: [String: Any] = [AVVideoCodecKey: alpha ? AVVideoCodecType.proRes4444 : .h264, AVVideoWidthKey: 320, AVVideoHeightKey: 176]
        if let (horizontal, vertical) = pixelAspect {  // anamorphic: 320 coded pixels shown 4:3 wide
            videoSettings[AVVideoPixelAspectRatioKey] = [AVVideoPixelAspectRatioHorizontalSpacingKey: horizontal, AVVideoPixelAspectRatioVerticalSpacingKey: vertical]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        if let timescale { input.mediaTimeScale = timescale }
        if let transform { input.transform = transform }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 176,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw MovieWriter.WriterError.failed(writer.error?.localizedDescription ?? "startWriting") }
        writer.startSession(atSourceTime: .zero)
        let rate = floatAudio ? 96_000.0 : fiveOne ? 48_000.0 : 44_100.0
        let channels: UInt32 = floatAudio ? 2 : fiveOne ? 6 : 1
        let bytesPerFrame: UInt32 = floatAudio ? 8 : fiveOne ? 12 : 2
        var description = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: (floatAudio ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame, mChannelsPerFrame: channels,
            mBitsPerChannel: bytesPerFrame / channels * 8, mReserved: 0)
        var format: CMAudioFormatDescription?
        withUnsafePointer(to: &fiveOneLayout) { layout in
            CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &description, layoutSize: fiveOne ? MemoryLayout<AudioChannelLayout>.size : 0, layout: fiveOne ? layout : nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        }
        let frames = Int(rate)
        let block: CMBlockBuffer
        if fiveOne {
            let constants = (0..<frames * 6).map { Int16(($0 % 6 + 1) * 3000) }
            block = try constants.withUnsafeBytes { try MovieWriter.blockBuffer(copying: $0) }
        } else if floatAudio {
            let tone = (0..<frames * 2).map { Float(sin(2 * .pi * 440 * Double($0 / 2) / rate) * 0.5) }
            block = try tone.withUnsafeBytes { try MovieWriter.blockBuffer(copying: $0) }
        } else {
            let tone = (0..<frames).map { Int16(sin(2 * .pi * 440 * Double($0) / rate) * 16_000) }
            block = try tone.withUnsafeBytes { try MovieWriter.blockBuffer(copying: $0) }
        }
        var audioSample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format!, sampleCount: frames, presentationTimeStamp: .zero, packetDescriptions: nil,
            sampleBufferOut: &audioSample)
        while !audioInput.isReadyForMoreMediaData { usleep(500) }
        guard audioInput.append(audioSample!) else { throw MovieWriter.WriterError.failed(writer.error?.localizedDescription ?? "append (audio)") }
        audioInput.markAsFinished()
        let times = presentationTimes ?? (0..<25).map { CMTime(value: Int64($0), timescale: 25) }
        for (frame, time) in times.enumerated() {
            while !input.isReadyForMoreMediaData { usleep(500) }
            let buffer = try patternBuffer(pool: adaptor.pixelBufferPool, frame: frame)
            if alpha {  // the right half transparent (premultiplied: all zero)
                CVPixelBufferLockBaseAddress(buffer, [])
                let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<176 { memset(base + y * stride + 160 * 4, 0, 160 * 4) }
                CVPixelBufferUnlockBaseAddress(buffer, [])
            }
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw MovieWriter.WriterError.failed(writer.error?.localizedDescription ?? "append")
            }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw MovieWriter.WriterError.failed(writer.error?.localizedDescription ?? "finish") }
    }

    /// A 320×176 PNG: the left half opaque, the right half transparent; the green channel encodes `index`.
    static func writePNG(to url: URL, index: Int) throws {
        let (w, h) = (320, 176)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let p = (y * w + x) * 4
                let opaque = x < w / 2  // premultiplied: the transparent half is all zero
                pixels[p] = opaque ? UInt8(x * 255 / (w - 1)) : 0
                pixels[p + 1] = opaque ? UInt8(index * 25) : 0
                pixels[p + 2] = opaque ? UInt8(y * 255 / (h - 1)) : 0
                pixels[p + 3] = opaque ? 255 : 0
            }
        }
        let image = pixels.withUnsafeMutableBytes { raw in
            CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MovieWriter.WriterError.failed("png") }
    }

    /// Polls until the job is finished (or `timeout`, an issue that says how long it waited); returns its last state.
    /// Sleeps instead of blocking: the queue's worker needs a free thread of the cooperative pool for its async asset
    /// loads, and parallel tests would hog them. 60 s, not 8: a parallel run on a loaded Mac is that much slower (B67).
    @discardableResult
    static func wait(
        for id: UUID, in queue: IngestQueue, timeout: Duration = .seconds(60), sourceLocation: SourceLocation = #_sourceLocation
    ) async -> IngestJob.State {
        let started = ContinuousClock.now
        func state() -> IngestJob.State? { queue.jobs.first(where: { $0.id == id })?.state }
        if !(await waitUntil(timeout) { state()?.isFinished == true }) {
            Issue.record("job not finished after \(ContinuousClock.now - started): \(String(describing: state()))", sourceLocation: sourceLocation)
        }
        return state() ?? .cancelled
    }

    /// Opens `url` the way the engine does and checks the frame count, codec and size.
    static func expectPlayable(_ url: URL, device: MTLDevice, frames: Int, fps: Double, codec: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let source = try await MovieSource.open(url: url, device: device, poolSize: 2)
        #expect(source.info.frameCount == frames, sourceLocation: sourceLocation)
        #expect(source.info.codecName == codec, sourceLocation: sourceLocation)
        #expect(source.info.width == 320 && source.info.height == 176, sourceLocation: sourceLocation)
        #expect(abs(source.info.frameRate - fps) < 0.01, sourceLocation: sourceLocation)
        let slot = DecodedFrame(poolIndex: 0)
        try source.decode(frame: frames / 2, into: slot)
        #expect(slot.frameIndex == frames / 2, sourceLocation: sourceLocation)
    }

    /// The track is readable by `AudioTrackReader` (48 kHz stereo, 2 s) and still holds the test tone: 1 kHz on the left.
    static func expectTestToneAudio(_ url: URL, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let reader = try await AudioTrackReader.open(url: url)
        #expect(reader.hasAudio, sourceLocation: sourceLocation)
        #expect(reader.sampleRate == 48_000 && reader.channelCount == 2, sourceLocation: sourceLocation)
        #expect(abs(reader.duration - 2) < 0.05, sourceLocation: sourceLocation)
        let (samples, count, _) = AudioTests.read(reader, frames: 24_000)
        #expect(count == 24_000, sourceLocation: sourceLocation)
        let crossings = AudioTests.crossings(samples, channel: 0, frames: 2000..<22_000)  // 20 000 frames of 1 kHz: 833 sign changes
        #expect(abs(crossings - 833) <= 3, sourceLocation: sourceLocation)
    }

    /// Where the moving white bar (`PatternFrames`) is in every frame AVFoundation decodes from `url`, in order
    /// (frame n: x = 8n mod 304; a row below the counter, where only the bar has a blue channel above 200).
    static func barPositions(of url: URL) async throws -> [Int] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        var positions: [Int] = []
        while let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let row = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self) + 100 * CVPixelBufferGetBytesPerRow(buffer)
            positions.append((0..<CVPixelBufferGetWidth(buffer)).first { row[$0 * 4] > 200 } ?? -1)
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        return positions
    }

    // MARK: (a) ProRes + audio → HAP Q and ProRes 422 HQ

    @Test func transcodesToHAPQAndProResWithAudio() async throws {
        let directory = try tempDir("fanous-ingest-tests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.mov")
        try await Self.writeSource(to: source)
        let queue = IngestQueue(persistenceURL: directory.appending(path: "queue.json"))
        queue.start()
        defer { queue.stop() }

        let hapJob = queue.enqueue(IngestJob(source: source, destination: directory.appending(path: "library/001_hap.mov"), kind: .transcode(codec: .hap(.hapQ))))
        let proResJob = queue.enqueue(IngestJob(source: source, destination: directory.appending(path: "library/002_prores.mov"), kind: .transcode(codec: .proRes422HQ)))
        #expect(await Self.wait(for: hapJob.id, in: queue) == .done)
        #expect(await Self.wait(for: proResJob.id, in: queue) == .done)
        #expect(FileManager.default.fileExists(atPath: source.path))  // no originals directory, no delete: left in place

        let bars = try await Self.barPositions(of: proResJob.destination)
        #expect(bars.count == 20 && zip(bars, 0..<20).allSatisfy { abs($0 - $1 * 8) <= 2 }, "bar positions \(bars)")  // every frame, in order, content intact
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        try await Self.expectPlayable(hapJob.destination, device: device, frames: 20, fps: 10, codec: "HapY")
        try await Self.expectPlayable(proResJob.destination, device: device, frames: 20, fps: 10, codec: "apch")
        try await Self.expectTestToneAudio(hapJob.destination)
        try await Self.expectTestToneAudio(proResJob.destination)
    }

    // MARK: (b) sequence, alpha promotion

    @Test func sequenceJobAndAlphaPromotion() async throws {
        let directory = try tempDir("fanous-ingest-tests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = directory.appending(path: "frames")
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        for i in 0..<10 { try Self.writePNG(to: frames.appending(path: String(format: "frame_%03d.png", i)), index: i) }
        let queue = IngestQueue(persistenceURL: directory.appending(path: "queue.json"))
        queue.start()
        defer { queue.stop() }

        let sequence = queue.enqueue(IngestJob(source: frames, destination: directory.appending(path: "library/001_seq.mov"), kind: .sequence(fps: 25, codec: .proRes4444)))
        #expect(await Self.wait(for: sequence.id, in: queue) == .done)
        // The alpha-carrying movie keeps its alpha when it is transcoded: ProRes 422 HQ becomes 4444, HAP Q becomes HAP Alpha.
        let toProRes = queue.enqueue(IngestJob(source: sequence.destination, destination: directory.appending(path: "library/002_prores.mov"), kind: .transcode(codec: .proRes422HQ)))
        let toHAP = queue.enqueue(IngestJob(source: sequence.destination, destination: directory.appending(path: "library/003_hap.mov"), kind: .transcode(codec: .hap(.hapQ))))
        #expect(await Self.wait(for: toProRes.id, in: queue) == .done)
        #expect(await Self.wait(for: toHAP.id, in: queue) == .done)

        guard let device = MTLCreateSystemDefaultDevice() else { return }
        for (url, codec) in [(sequence.destination, "ap4h"), (toProRes.destination, "ap4h"), (toHAP.destination, "Hap5")] {
            let movie = try await MovieSource.open(url: url, device: device, poolSize: 2)
            #expect(movie.info.frameCount == 10 && movie.info.codecName == codec, "\(url.lastPathComponent): \(movie.info.codecName) \(movie.info.frameCount)")
        }
    }

    // MARK: (c) stills, originals, name clash

    @Test func stillIsCopiedAndOriginalMoved() async throws {
        let directory = try tempDir("fanous-ingest-tests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let incoming = directory.appending(path: "incoming")
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let png = incoming.appending(path: "title.png")
        try Self.writePNG(to: png, index: 3)
        let bytes = try Data(contentsOf: png)
        let library = directory.appending(path: "library/001_Opening")  // does not exist yet
        let queue = IngestQueue(persistenceURL: directory.appending(path: "queue.json"))
        queue.start()
        defer { queue.stop() }

        let job = queue.enqueue(IngestJob(source: png, destination: library.appending(path: "002_title.png"), kind: .still, originalsDirectory: library.appending(path: "_originals")))
        #expect(await Self.wait(for: job.id, in: queue) == .done)
        #expect(try Data(contentsOf: library.appending(path: "002_title.png")) == bytes)
        #expect(!FileManager.default.fileExists(atPath: png.path))
        #expect(try Data(contentsOf: library.appending(path: "_originals/title.png")) == bytes)
        #expect(queue.jobs.first?.finishedAt != nil)

        // A second original with the same name does not replace the first one.
        try bytes.write(to: png)
        let again = queue.enqueue(IngestJob(source: png, destination: library.appending(path: "003_title.png"), kind: .still, originalsDirectory: library.appending(path: "_originals")))
        #expect(await Self.wait(for: again.id, in: queue) == .done)
        #expect(FileManager.default.fileExists(atPath: library.appending(path: "_originals/title-2.png").path))
    }

    @Test func existingDestinationFailsAndSourceCanBeDeleted() async throws {
        let directory = try tempDir("fanous-ingest-tests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appending(path: "first.png"), second = directory.appending(path: "second.png")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        let destination = directory.appending(path: "library/001_a.png")
        let queue = IngestQueue(persistenceURL: directory.appending(path: "queue.json"))
        queue.start()
        defer { queue.stop() }

        let one = queue.enqueue(IngestJob(source: first, destination: destination, kind: .still, deleteSource: true))
        #expect(await Self.wait(for: one.id, in: queue) == .done)
        #expect(!FileManager.default.fileExists(atPath: first.path))  // deleteSource, no originals directory

        let clash = queue.enqueue(IngestJob(source: second, destination: destination, kind: .still))
        guard case .failed(let message) = await Self.wait(for: clash.id, in: queue) else {
            Issue.record("expected a failure")
            return
        }
        #expect(message.contains("already exists"))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "one")
        #expect(FileManager.default.fileExists(atPath: second.path))  // a failed job leaves its source alone

        queue.remove(id: one.id)
        queue.remove(id: clash.id)
        #expect(queue.jobs.isEmpty)
    }

    // MARK: (d) persistence

    @Test func queueSurvivesRestart() async throws {
        let directory = try tempDir("fanous-ingest-tests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "state/queue.json")  // parent is created on the first save
        let first = IngestQueue(persistenceURL: file)
        first.paused = true
        first.start()
        defer { first.stop() }
        let a = first.enqueue(IngestJob(source: directory.appending(path: "a.mov"), destination: directory.appending(path: "lib/001_a.mov"), kind: .transcode(codec: .hap(.hapQ))))
        let b = first.enqueue(IngestJob(source: directory.appending(path: "seq"), destination: directory.appending(path: "lib/002_b.mov"), kind: .sequence(fps: 30, codec: .proRes4444), originalsDirectory: directory.appending(path: "orig"), deleteSource: true))
        try await Task.sleep(for: .milliseconds(100))
        #expect(first.jobs.allSatisfy { $0.state == .queued })  // paused: nothing was claimed

        let second = IngestQueue(persistenceURL: file)
        #expect(second.jobs.map(\.id) == [a.id, b.id])
        #expect(second.jobs.allSatisfy { $0.state == .queued })
        #expect(second.jobs.map(\.kind) == [a.kind, b.kind])
        #expect(second.jobs[1].originalsDirectory == b.originalsDirectory && second.jobs[1].deleteSource)
        #expect(abs(second.jobs[0].createdAt.timeIntervalSince(a.createdAt)) < 1)

        // A job that was running when the process died starts over.
        var crashed = a
        crashed.state = .running(progress: 0.4)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([crashed]).write(to: file)
        #expect(IngestQueue(persistenceURL: file).jobs.map(\.state) == [.queued])

        // Garbage does not stop the queue from starting.
        try Data("not json".utf8).write(to: file)
        #expect(IngestQueue(persistenceURL: file).jobs.isEmpty)
    }

    /// Done and cancelled jobs older than a minute leave the list (and the file at the next change); a failed one stays.
    @Test func finishedJobsAreForgottenAfterAMinuteFailedOnesStay() throws {
        let directory = try tempDir("fanous-ingest-forget")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "in.mov"), destination = directory.appending(path: "out.mov")
        func job(_ state: IngestJob.State, finished seconds: TimeInterval) -> IngestJob {
            var job = IngestJob(source: source, destination: destination, kind: .transcode(codec: .proRes422))
            job.state = state
            job.finishedAt = Date(timeIntervalSinceNow: -seconds)
            return job
        }
        let old = job(.done, finished: 120), cancelled = job(.cancelled, finished: 120)
        let fresh = job(.done, finished: 5), failed = job(.failed("boom"), finished: 120)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let file = directory.appending(path: "queue.json")
        try encoder.encode([old, cancelled, fresh, failed]).write(to: file)
        let queue = IngestQueue(persistenceURL: file)
        #expect(queue.jobs.map(\.id) == [fresh.id, failed.id])
        queue.remove(id: failed.id)  // any change rewrites the file without the expired jobs
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode([IngestJob].self, from: Data(contentsOf: file))
        #expect(saved.map(\.id) == [fresh.id])
    }

    // MARK: (e) pause and cancel

    @Test func pauseHoldsAndCancelRemovesPartialOutput() async throws {
        let directory = try tempDir("fanous-ingest-tests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.mov")
        try await Self.writeSource(to: source, seconds: 5)  // 50 frames
        let library = directory.appending(path: "library")
        let queue = IngestQueue(persistenceURL: directory.appending(path: "queue.json"))
        queue.shouldYield = { true }  // 20 ms per frame on top of the encode: the 50 frames take over a second
        queue.start()
        defer { queue.stop() }

        let job = queue.enqueue(IngestJob(source: source, destination: library.appending(path: "001_x.mov"), kind: .transcode(codec: .proRes422), originalsDirectory: directory.appending(path: "_originals")))
        func progress() -> Double? {
            if case .running(let value) = queue.jobs.first(where: { $0.id == job.id })?.state { return value }
            return nil
        }
        let deadline = Date().addingTimeInterval(5)
        while (progress() ?? 0) < 0.1, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect((progress() ?? 0) >= 0.1)

        // Timings are loose on purpose: a .utility thread's 20 ms sleeps are coalesced to 150 ms and more on a busy machine.
        queue.paused = true
        var held = progress()
        var stable = 0
        for _ in 0..<50 where stable < 5 {  // settle: the frame in flight finishes, then nothing moves for 500 ms
            try await Task.sleep(for: .milliseconds(100))
            let now = progress()
            if now == held { stable += 1 } else { (held, stable) = (now, 0) }
        }
        #expect(stable == 5)
        try await Task.sleep(for: .milliseconds(300))
        #expect(progress() == held)
        #expect(held.map { $0 < 1 } == true)
        queue.paused = false
        let resumeDeadline = Date().addingTimeInterval(5)
        while (progress() ?? 1) <= (held ?? 1), Date() < resumeDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect((progress() ?? 1) > (held ?? 1))

        queue.cancel(id: job.id)
        #expect(await Self.wait(for: job.id, in: queue) == .cancelled)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []
        #expect(leftovers.isEmpty, "left behind: \(leftovers)")
        #expect(FileManager.default.fileExists(atPath: source.path))  // a cancelled job keeps its source
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "_originals").path))

        // cancelling a queued job works too, and the queue goes on with the next one
        queue.paused = true
        let queued = queue.enqueue(IngestJob(source: source, destination: library.appending(path: "002_y.mov"), kind: .transcode(codec: .hap(.hap))))
        queue.cancel(id: queued.id)
        #expect(queue.jobs.first(where: { $0.id == queued.id })?.state == .cancelled)
    }

    // MARK: (f) H.264

    @Test func h264SourceBecomesPlayableHAP() async throws {
        let directory = try tempDir("fanous-ingest-tests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "phone.mp4")
        try await Self.writeH264(to: source)
        let queue = IngestQueue(persistenceURL: directory.appending(path: "queue.json"))
        queue.start()
        defer { queue.stop() }

        let changes = LockedCounter()
        queue.onChange = { changes.increment() }
        let job = queue.enqueue(IngestJob(source: source, destination: directory.appending(path: "library/001_phone.mov"), kind: .transcode(codec: .hap(.hap)), deleteSource: true))
        #expect(await Self.wait(for: job.id, in: queue) == .done)
        #expect(changes.value >= 2)  // running, done
        #expect(!FileManager.default.fileExists(atPath: source.path))

        guard let device = MTLCreateSystemDefaultDevice() else { return }
        try await Self.expectPlayable(job.destination, device: device, frames: 25, fps: 25, codec: "Hap1")
        // The AAC track is stored as LPCM in its own rate and channel count (B19); the reader plays the mono tone on both channels.
        let reader = try await AudioTrackReader.open(url: job.destination)
        #expect(reader.hasAudio && reader.sampleRate == 44_100 && reader.channelCount == 1)
        #expect(abs(reader.duration - 1) < 0.1)
        let track = try #require(try await AVURLAsset(url: job.destination).loadTracks(withMediaType: .audio).first)
        let description = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee.mBitsPerChannel == 24)  // a compressed source decodes to 24-bit
        let (samples, count, _) = AudioTests.read(reader, frames: 24_000)
        #expect(count == 24_000)
        for channel in 0..<2 {
            #expect(AudioTests.peak(samples, channel: channel, frames: 2000..<22_000) > 0.3)
            #expect(abs(AudioTests.crossings(samples, channel: channel, frames: 2000..<22_000) - 366) <= 4)  // 440 Hz over 20 000 frames
        }
    }

    /// B19: an LPCM source keeps its sample rate, channel count, bit depth and float form; nothing is resampled to 48 kHz
    /// stereo 16-bit any more (the reader converts at playback).
    @Test func lpcmSourceKeepsItsAudioFormat() async throws {
        let directory = try tempDir("fanous-ingest-tests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "master.mov")
        try await Self.writeH264(to: source, floatAudio: true)
        let queue = IngestQueue(persistenceURL: directory.appending(path: "queue.json"))
        queue.start()
        defer { queue.stop() }
        let job = queue.enqueue(IngestJob(source: source, destination: directory.appending(path: "library/001_master.mov"), kind: .transcode(codec: .proRes422)))
        #expect(await Self.wait(for: job.id, in: queue) == .done)

        let track = try #require(try await AVURLAsset(url: job.destination).loadTracks(withMediaType: .audio).first)
        let description = try #require(try await track.load(.formatDescriptions).first)
        let format = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        #expect(format.mFormatID == kAudioFormatLinearPCM && format.mSampleRate == 96_000 && format.mChannelsPerFrame == 2)
        #expect(format.mBitsPerChannel == 32 && format.mFormatFlags & kAudioFormatFlagIsFloat != 0)
        let reader = try await AudioTrackReader.open(url: job.destination)
        #expect(reader.hasAudio && reader.sampleRate == 96_000 && abs(reader.duration - 1) < 0.1)
        let (samples, count, _) = AudioTests.read(reader, frames: 24_000)
        #expect(count == 24_000)
        #expect(abs(AudioTests.crossings(samples, channel: 0, frames: 2000..<22_000) - 366) <= 4)  // 440 Hz over 20 000 frames at 48 kHz
    }

    /// `lpcmFormat` only ever asks `AVAssetReaderAudioMixOutput` for what it accepts: that initialiser raises an ObjC
    /// exception (not a Swift error) on a depth outside 8/16/24/32, a rate outside 8–192 kHz or a layout that does not match
    /// the channel count, which would kill the engine. Each case builds the output here, so a regression crashes this test.
    @Test func lpcmFormatStaysWithinWhatTheReaderAccepts() async throws {
        let directory = try tempDir("fanous-ingest-tests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.mov")
        try await Self.writeSource(to: source, seconds: 1)
        let track = try #require(try await AVURLAsset(url: source).loadTracks(withMediaType: .audio).first)

        func describe(rate: Double, channels: UInt32, bits: UInt32, float: Bool = false, lpcm: Bool = true, layoutTag: AudioChannelLayoutTag? = nil) throws -> CMAudioFormatDescription {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: rate, mFormatID: lpcm ? kAudioFormatLinearPCM : kAudioFormatMPEG4AAC,
                mFormatFlags: lpcm ? (float ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) | kAudioFormatFlagIsPacked : 0,
                mBytesPerPacket: lpcm ? bits / 8 * channels : 0, mFramesPerPacket: lpcm ? 1 : 1024, mBytesPerFrame: lpcm ? bits / 8 * channels : 0,
                mChannelsPerFrame: channels, mBitsPerChannel: lpcm ? bits : 0, mReserved: 0)
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = layoutTag ?? 0
            var format: CMAudioFormatDescription?
            let status = withUnsafePointer(to: &layout) { pointer in
                CMAudioFormatDescriptionCreate(
                    allocator: nil, asbd: &asbd, layoutSize: layoutTag == nil ? 0 : MemoryLayout<AudioChannelLayout>.size, layout: layoutTag == nil ? nil : pointer,
                    magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
            }
            return try #require(format, "format description \(status)")
        }
        let cases: [(CMAudioFormatDescription, Double, UInt32, UInt32, Bool)] = [
            (try describe(rate: 384_000, channels: 1, bits: 64, float: true), 192_000, 1, 32, true),  // DXD fl64: clamped, float32
            (try describe(rate: 44_100, channels: 2, bits: 20), 44_100, 2, 24, false),  // 20-bit → 24
            (try describe(rate: 7350, channels: 1, bits: 0, lpcm: false), 8000, 1, 24, false),  // low-rate AAC: clamped, 24-bit
            (try describe(rate: 48_000, channels: 6, bits: 24, layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A), 48_000, 6, 24, false),  // 5.1 stays (B143)
            (try describe(rate: 48_000, channels: 6, bits: 24), 48_000, 6, 24, false),  // six channels without a layout: discrete in order
            (try describe(rate: 48_000, channels: 2, bits: 16, layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A), 48_000, 2, 16, false),  // layout disagrees with the count → by count
            (try describe(rate: 44_100, channels: 0, bits: 0, lpcm: false), 44_100, 2, 24, false),  // no channel count: stereo (a description cannot carry rate 0)
        ]
        for (description, rate, channels, bits, float) in cases {
            let (format, settings) = try #require(Transcoder.lpcmFormat(matching: description))
            let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
            #expect(asbd.mSampleRate == rate && asbd.mChannelsPerFrame == channels && asbd.mBitsPerChannel == bits, "\(asbd)")
            #expect((asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0) == float)
            #expect(asbd.mBytesPerFrame == bits / 8 * channels)
            _ = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)  // raises on anything the reader refuses
        }
    }

    /// B143: a 5.1 source keeps its six channels and layout in the library file, and the player folds them to stereo by the
    /// layout, so the centre is in both sides (before: ingest mixed to stereo, and the player took channels 0 and 1).
    @Test func fiveOneSourceKeepsItsChannelsAndFoldsAtPlayback() async throws {
        let directory = try tempDir("fanous-ingest-tests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "five-one.mov")
        try await Self.writeH264(to: source, fiveOne: true)
        let queue = IngestQueue(persistenceURL: directory.appending(path: "queue.json"))
        queue.start()
        defer { queue.stop() }
        let job = queue.enqueue(IngestJob(source: source, destination: directory.appending(path: "library/001_five-one.mov"), kind: .transcode(codec: .proRes422)))
        #expect(await Self.wait(for: job.id, in: queue) == .done)
        let track = try #require(try await AVURLAsset(url: job.destination).loadTracks(withMediaType: .audio).first)
        let description = try #require(try await track.load(.formatDescriptions).first)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        var layoutSize = 0
        let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize)
        #expect(asbd.mChannelsPerFrame == 6 && asbd.mSampleRate == 48_000 && layout?.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_MPEG_5_1_A, "\(asbd)")
        let reader = try await AudioTrackReader.open(url: job.destination)
        #expect(reader.channelCount == 6)
        reader.seek(toSeconds: 0.25)
        let samples = AudioTests.read(reader, frames: 4800).samples
        let left = samples[2 * 2400] * 32768, right = samples[2 * 2400 + 1] * 32768
        // L + 0.7071 (C + Ls), R + 0.7071 (C + Rs): 3000 + 0.7071 (9000 + 15000), 6000 + 0.7071 (9000 + 18000)
        #expect(abs(left - 19971) < 40 && abs(right - 25092) < 40, "\(left) \(right)")
    }

    /// B19: an anamorphic source keeps its pixel aspect ratio in the ProRes and the HAP file (the format description's
    /// `PixelAspectRatio` extension; `naturalSize` then reports the display size), and the player reads it.
    @Test func anamorphicSourceKeepsItsPixelAspect() async throws {
        let directory = try tempDir("fanous-ingest-tests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "anamorphic.mp4")
        try await Self.writeH264(to: source, pixelAspect: (4, 3))
        let queue = IngestQueue(persistenceURL: directory.appending(path: "queue.json"))
        queue.start()
        defer { queue.stop() }
        let proRes = queue.enqueue(IngestJob(source: source, destination: directory.appending(path: "library/001_prores.mov"), kind: .transcode(codec: .proRes422)))
        let hap = queue.enqueue(IngestJob(source: source, destination: directory.appending(path: "library/002_hap.mov"), kind: .transcode(codec: .hap(.hap))))
        #expect(await Self.wait(for: proRes.id, in: queue) == .done)
        #expect(await Self.wait(for: hap.id, in: queue) == .done)

        for job in [proRes, hap] {
            let track = try #require(try await AVURLAsset(url: job.destination).loadTracks(withMediaType: .video).first)
            let (descriptions, size) = try await track.load(.formatDescriptions, .naturalSize)
            let ratio = CMFormatDescriptionGetExtension(try #require(descriptions.first), extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) as? [String: Int]
            #expect(ratio?[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String] == 4 && ratio?[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String] == 3, "\(job.destination.lastPathComponent): \(ratio ?? [:])")
            #expect(abs(size.width - 320 * 4 / 3) < 1 && size.height == 176, "\(job.destination.lastPathComponent): \(size)")
            // the library index carries the ratio and the shown width, for the Media screen's label (B146)
            let probed = try await offPool { try LibraryIndex.probeMovie(job.destination) }
            #expect(abs(Double(probed.width) - 320 * 4 / 3) < 1 && probed.height == 176 && abs((probed.pixelAspect ?? 1) - 4.0 / 3) < 0.001, "\(job.destination.lastPathComponent): \(probed)")
        }
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let movie = try await MovieSource.open(url: proRes.destination, device: device, poolSize: 2)
        #expect(movie.info.width == 320 && abs(movie.info.pixelAspect - 4.0 / 3) < 0.001)

        // The Media screen's thumbnail fills its 427:176 frame edge to edge (the still path carries the ratio too; it
        // used to draw the coded 320:176 picture in it, with black bars at both sides).
        let thumbnails = Thumbnailer(context: try MetalContext(), directory: directory.appending(path: "thumbs"), logger: Logger(label: "test"))
        var metadata = MediaMetadata()
        (metadata.width, metadata.height) = (427, 176)
        let name = try #require(thumbnails.make(for: proRes.destination, metadata: metadata, kind: .movie))
        let pixels = try #require(GoldenTests.readPNG(directory.appending(path: "thumbs").appending(path: name)))
        let width = Thumbnailer.width, height = pixels.count / 4 / width
        let row = height / 2
        let left = pixels[(row * width) * 4 + 2], right = pixels[(row * width + width - 1) * 4 + 2]  // blue, 128 in the pattern
        #expect(abs(height - 132) <= 1 && left > 60 && right > 60, "\(width)x\(height) edges blue \(left) \(right)")
    }

    /// B19: a variable-frame-rate source (a screen recording: 10 frames in its first second, 30 in its second) is held and
    /// dropped to a constant rate by presentation time, its fastest rate (30 fps), so it keeps its 2 s and stays in step
    /// with its audio. Before, every source frame became one output frame at the smallest frame duration: 40 frames at
    /// 30 fps, a 1.33 s file that ran ahead of its sound.
    @Test func variableFrameRateSourceIsHeldAndDroppedToAConstantRate() async throws {
        let directory = try tempDir("fanous-ingest-tests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "screen.mp4")
        let times = (0..<10).map { CMTime(value: Int64($0) * 100, timescale: 1000) } + (0..<30).map { CMTime(value: 30 + Int64($0), timescale: 30) }
        try await Self.writeH264(to: source, presentationTimes: times)
        let queue = IngestQueue(persistenceURL: directory.appending(path: "queue.json"))
        queue.start()
        defer { queue.stop() }
        let job = queue.enqueue(IngestJob(source: source, destination: directory.appending(path: "library/001_screen.mov"), kind: .transcode(codec: .proRes422)))
        #expect(await Self.wait(for: job.id, in: queue) == .done)

        let track = try #require(try await AVURLAsset(url: job.destination).loadTracks(withMediaType: .video).first)
        let (rate, range) = try await track.load(.nominalFrameRate, .timeRange)
        #expect(abs(rate - 30) < 0.01 && abs(range.duration.seconds - 2) < 0.04, "\(rate) fps, \(range.duration.seconds) s")
        // output frame k (at k/30 s) shows the latest source frame at or before it: k/3 in the first second, then one each
        let bars = try await Self.barPositions(of: job.destination)
        let expected = (0..<60).map { k in (k < 30 ? k / 3 : 10 + (k - 30)) * 8 % 304 }
        #expect(bars.count == 60 && zip(bars, expected).allSatisfy { abs($0 - $1) <= 2 }, "bars \(bars)")
    }

    /// B19 (review of PR #221): a constant 30 fps source on a 1 ms timescale has 33 and 34 ms frames and reports a 33 ms
    /// smallest frame duration. Snapping the rate to 1/30 and sampling each output frame at its middle keep it frame for
    /// frame over 5 s; sampling at the start dropped and doubled every third frame, and a 33 ms output drifted a frame per 3 s.
    /// 29.97 fps the same way (33 ms against 33.37: 1.1 % off, within one tick), over 1800 frames because the drift of a
    /// 1/30 output against a 29.97 source shows only after about 500 frames.
    @Test(arguments: [(30.0, 150, CMTime(value: 1, timescale: 30)), (30000.0 / 1001, 1800, CMTime(value: 1001, timescale: 30000))])
    func millisecondTimestampsStayFrameForFrame(rate: Double, frames: Int, frameDuration: CMTime) async throws {
        let directory = try tempDir("fanous-ingest-tests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "obs.mp4")
        let times = (0..<frames).map { CMTime(value: Int64((Double($0) * 1000 / rate).rounded()), timescale: 1000) }
        try await Self.writeH264(to: source, presentationTimes: times, timescale: 1000)
        let queue = IngestQueue(persistenceURL: directory.appending(path: "queue.json"))
        queue.start()
        defer { queue.stop() }
        let job = queue.enqueue(IngestJob(source: source, destination: directory.appending(path: "library/001_obs.mov"), kind: .transcode(codec: .proRes422)))
        #expect(await Self.wait(for: job.id, in: queue) == .done)

        let track = try #require(try await AVURLAsset(url: job.destination).loadTracks(withMediaType: .video).first)
        let (nominal, minimum) = try await track.load(.nominalFrameRate, .minFrameDuration)
        #expect(abs(Double(nominal) - rate) < 0.01 && minimum == frameDuration, "\(nominal) fps, \(minimum)")
        let bars = try await Self.barPositions(of: job.destination)
        #expect(bars.count == frames && bars.enumerated().allSatisfy { abs($0.element - $0.offset * 8 % 304) <= 2 }, "\(bars.count) frames, bars \(bars.prefix(40))")
    }

    @Test func rotatedSourceIsBakedUpright() async throws {
        let directory = try tempDir("fanous-ingest-tests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "rotated.mp4")
        try await Self.writeH264(to: source, rotated: true)
        let queue = IngestQueue(persistenceURL: directory.appending(path: "queue.json"))
        queue.start()
        defer { queue.stop() }
        let job = queue.enqueue(IngestJob(source: source, destination: directory.appending(path: "library/001_rotated.mov"), kind: .transcode(codec: .proRes422HQ)))
        #expect(await Self.wait(for: job.id, in: queue) == .done)

        // The library flags the source (upright size, needs ingest) and the output is plain.
        let (before, after) = try await offPool { (try LibraryIndex.probeMovie(source), try LibraryIndex.probeMovie(job.destination)) }
        #expect(before.rotated == true && before.width == 176 && before.height == 320)
        #expect(after.rotated == false && after.width == 176 && after.height == 320 && after.frameCount == 25)

        // 320×176 landscape pixels + 90° clockwise tag -> 176×320 upright, no transform left on the output.
        let asset = AVURLAsset(url: job.destination)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size.width == 176 && size.height == 320)
        #expect(try await track.load(.preferredTransform).isIdentity)
        // Frame 0: the source's top rows are the black counter, its left edge the white bar. Rotated clockwise, the black lands on the right edge and the bar on the left.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        let first = try #require(output.copyNextSampleBuffer())
        var count = 1
        while output.copyNextSampleBuffer() != nil { count += 1 }
        #expect(count == 25)
        let buffer = try #require(CMSampleBufferGetImageBuffer(first))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8) { (base[y * stride + x * 4 + 2], base[y * stride + x * 4 + 1]) }
        #expect(pixel(4, 4).r > 200 && pixel(4, 315).r > 200)
        #expect(pixel(171, 4).r < 40 && pixel(171, 315).r < 40)
    }

    /// B18: a rotated source with alpha keeps its alpha. The quarter turn is done in the pixels (vImage), not by a
    /// composition that renders over opaque black: the source's transparent right half (x ≥ 160) becomes the upright
    /// file's transparent lower half (y ≥ 160), and the pixel aspect ratio comes along, swapped.
    @Test func rotatedSourceWithAlphaKeepsItsAlpha() async throws {
        let directory = try tempDir("fanous-ingest-tests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "rotated-alpha.mov")
        try await Self.writeH264(to: source, rotated: true, pixelAspect: (4, 3), alpha: true)
        let queue = IngestQueue(persistenceURL: directory.appending(path: "queue.json"))
        queue.start()
        defer { queue.stop() }
        let job = queue.enqueue(IngestJob(source: source, destination: directory.appending(path: "library/001_rotated.mov"), kind: .transcode(codec: .proRes422HQ)))
        #expect(await Self.wait(for: job.id, in: queue) == .done)

        let asset = AVURLAsset(url: job.destination)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let (descriptions, size) = try await track.load(.formatDescriptions, .naturalSize)
        let description = try #require(descriptions.first)
        #expect(CMFormatDescriptionGetMediaSubType(description) == makeFourCC("ap4h"), "promoted to 4444")
        let ratio = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) as? [String: Int]
        #expect(ratio?[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String] == 3 && ratio?[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String] == 4, "swapped ratio: \(ratio ?? [:])")
        #expect(abs(size.width - 176 * 3 / 4) < 1 && size.height == 320, "\(size)")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        let first = try #require(output.copyNextSampleBuffer())
        let buffer = try #require(CMSampleBufferGetImageBuffer(first))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        func alpha(_ x: Int, _ y: Int) -> UInt8 { base[y * stride + x * 4 + 3] }
        #expect(alpha(88, 40) == 255 && alpha(4, 150) == 255, "upper half opaque: \(alpha(88, 40)) \(alpha(4, 150))")
        #expect(alpha(88, 170) == 0 && alpha(171, 315) == 0, "lower half transparent: \(alpha(88, 170)) \(alpha(171, 315))")
    }

    /// B18: every `Turn` (both quarter turns, 180°, both flips) and the composition fallback (a transpose) put each source
    /// pixel where the tag says: four interior points of frame 0 (its red/green gradient) are checked at their transformed
    /// positions. A phone's translation (tx/ty) is added to the clockwise case: the linear part alone decides.
    @Test(arguments: [
        ("90 cw", CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 176, ty: 0)), ("90 ccw", CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 320)),
        ("180", CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 320, ty: 176)), ("flip h", CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 320, ty: 0)),
        ("flip v", CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 176)), ("transpose (composition)", CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)),
    ])
    func everyTransformPutsThePixelsWhereTheTagSays(name: String, transform: CGAffineTransform) async throws {
        let directory = try tempDir("fanous-ingest-tests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "tagged.mp4")
        try await Self.writeH264(to: source, transform: transform)
        let queue = IngestQueue(persistenceURL: directory.appending(path: "queue.json"))
        queue.start()
        defer { queue.stop() }
        let job = queue.enqueue(IngestJob(source: source, destination: directory.appending(path: "library/001_tagged.mov"), kind: .transcode(codec: .proRes422)))
        #expect(await Self.wait(for: job.id, in: queue) == .done, "\(name)")

        let asset = AVURLAsset(url: job.destination)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.preferredTransform).isIdentity, "\(name)")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        let first = try #require(output.copyNextSampleBuffer())
        let buffer = try #require(CMSampleBufferGetImageBuffer(first))
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let swaps = transform.a == 0
        #expect(width == (swaps ? 176 : 320) && height == (swaps ? 320 : 176), "\(name): \(width)x\(height)")
        // The stored (untagged) source frame, through the same H.264 decode: the gradient's codes after that decode are what
        // the output must show at the moved positions (the colour chain shifts them by more than a pixel of gradient).
        let sourceAsset = AVURLAsset(url: source)
        let sourceTrack = try #require(try await sourceAsset.loadTracks(withMediaType: .video).first)
        let sourceReader = try AVAssetReader(asset: sourceAsset)
        let sourceOutput = AVAssetReaderTrackOutput(track: sourceTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        sourceReader.add(sourceOutput)
        sourceReader.startReading()
        let sourceFirst = try #require(sourceOutput.copyNextSampleBuffer())
        let stored = try #require(CMSampleBufferGetImageBuffer(sourceFirst))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        CVPixelBufferLockBaseAddress(stored, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(stored, .readOnly)
        }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let storedBase = CVPixelBufferGetBaseAddress(stored)!.assumingMemoryBound(to: UInt8.self)
        let storedStride = CVPixelBufferGetBytesPerRow(stored)
        // Where the tag puts the source frame's corners decides the origin; a source pixel centre maps through the linear part.
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 320, y: 0), CGPoint(x: 0, y: 176), CGPoint(x: 320, y: 176)].map { $0.applying(transform) }
        let origin = CGPoint(x: corners.map(\.x).min()!, y: corners.map(\.y).min()!)
        for (sx, sy) in [(40, 40), (300, 40), (40, 160), (300, 160), (8, 100), (200, 20)] {  // gradient, the white bar, the black counter
            let moved = CGPoint(x: Double(sx) + 0.5, y: Double(sy) + 0.5).applying(transform)
            let (x, y) = (Int(moved.x - origin.x), Int(moved.y - origin.y))
            let out = base + y * stride + x * 4, src = storedBase + sy * storedStride + sx * 4
            let off = (0..<3).map { abs(Int(out[$0]) - Int(src[$0])) }.max()!
            #expect(off <= 12, "\(name): source (\(sx), \(sy)) = (\(src[2]), \(src[1]), \(src[0])) at (\(x), \(y)) reads (\(out[2]), \(out[1]), \(out[0]))")
        }
    }

    @Test func cancelledSequenceLeavesNothing() async throws {
        let directory = try tempDir("fanous-ingest-tests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = directory.appending(path: "frames")
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        for i in 0..<10 { try Self.writePNG(to: frames.appending(path: String(format: "frame_%03d.png", i)), index: i) }
        let queue = IngestQueue(persistenceURL: directory.appending(path: "queue.json"))
        queue.shouldYield = { true }
        queue.start()
        defer { queue.stop() }
        let job = queue.enqueue(IngestJob(source: frames, destination: directory.appending(path: "library/001_seq.mov"), kind: .sequence(fps: 25, codec: .proRes4444), originalsDirectory: directory.appending(path: "_originals")))
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .running(let progress) = queue.jobs[0].state, progress > 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        queue.cancel(id: job.id)
        #expect(await Self.wait(for: job.id, in: queue) == .cancelled)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "library").path)) ?? []).isEmpty)
        #expect(FileManager.default.fileExists(atPath: frames.path))
    }

    @Test func unreadableSourceFailsCleanly() async throws {
        let directory = try tempDir("fanous-ingest-tests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = IngestQueue(persistenceURL: directory.appending(path: "queue.json"))
        queue.start()
        defer { queue.stop() }
        let notAMovie = directory.appending(path: "broken.mp4")
        try Data("this is not a movie".utf8).write(to: notAMovie)
        let job = queue.enqueue(IngestJob(source: notAMovie, destination: directory.appending(path: "library/001_broken.mov"), kind: .transcode(codec: .proRes422HQ)))
        guard case .failed(let message) = await Self.wait(for: job.id, in: queue) else {
            Issue.record("expected a failure")
            return
        }
        #expect(!message.isEmpty)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "library").path)) ?? [] == [])
        #expect(FileManager.default.fileExists(atPath: notAMovie.path))
    }

    /// Two uploads into a folder number the index has not seen yet land in one folder, also with different names: the
    /// index is never rescanned here, like in the second before the debounced rescan or with a root missing at start behind a symlink (B140).
    @Test func uploadsIntoAnUnindexedFolderNumberShareOneFolder() throws {
        let directory = try tempDir("fanous-ingest-tests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = IngestQueue(persistenceURL: directory.appending(path: "queue.json"))
        let library = LibraryIndex(root: directory.appending(path: "library"), cacheDirectory: directory.appending(path: "cache"), logger: Logger(label: "test"))
        let api = IngestAPI(library: { library }, queue: queue, encoder: JSONEncoder(), logger: Logger(label: "test"))
        let still = directory.appending(path: "still.png")
        try Self.writePNG(to: still, index: 0)
        for name in ["red.png", "blue.png"] {
            #expect(api.enqueue(source: still, folder: 3, file: nil, name: name, codec: nil, fps: nil, keepOriginal: true).status == 202)
        }
        #expect(queue.jobs.map { $0.destination.deletingLastPathComponent().lastPathComponent } == ["003_red", "003_red"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.root.path) == ["003_red"])
    }

    /// A sequence job with `fps` 0 (or 241) is refused with 400 and nothing is queued: it used to reach `MovieWriter`,
    /// where a zero timescale trapped the engine, and the persisted job would have trapped it again at every start.
    @Test func sequenceWithAnImpossibleFrameRateIsRefused() async throws {
        let directory = try tempDir("fanous-ingest-tests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = IngestQueue(persistenceURL: directory.appending(path: "queue.json"))
        let library = LibraryIndex(root: directory.appending(path: "library"), cacheDirectory: directory.appending(path: "cache"), logger: Logger(label: "test"))
        let api = IngestAPI(library: { library }, queue: queue, encoder: JSONEncoder(), logger: Logger(label: "test"))
        let frames = directory.appending(path: "frames")
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        try Self.writePNG(to: frames.appending(path: "frame_000.png"), index: 0)
        for fps: Int32 in [0, -25, 241] {
            #expect(api.enqueue(source: frames, folder: 1, file: nil, name: nil, codec: nil, fps: fps, keepOriginal: true).status == 400, "fps \(fps)")
        }
        #expect(queue.jobs.isEmpty && !FileManager.default.fileExists(atPath: library.root.path), "nothing queued, no folder made")
        #expect(api.enqueue(source: frames, folder: 1, file: nil, name: nil, codec: nil, fps: 240, keepOriginal: true).status == 202)

        // A job persisted with such a rate before the guard ends as failed once the queue runs it, instead of trapping at every start.
        let old = directory.appending(path: "old-frames")  // its own folder: the accepted job above moves `frames` to _originals
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Self.writePNG(to: old.appending(path: "frame_000.png"), index: 0)
        let replayed = queue.enqueue(IngestJob(source: old, destination: directory.appending(path: "library/001_Folder/002_old.mov"), kind: .sequence(fps: 0, codec: .proRes422)))
        queue.start()
        defer { queue.stop() }
        if case .failed(let text) = await Self.wait(for: replayed.id, in: queue) { #expect(text.contains("frame rate"), "failed with: \(text)") } else { Issue.record("not failed") }
    }

    /// B51: while a library root change holds enqueues, a new job is refused with 409 and nothing is queued.
    @Test func heldEnqueueIsRefused() throws {
        let directory = try tempDir("fanous-ingest-tests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = IngestQueue(persistenceURL: directory.appending(path: "queue.json"))
        let library = LibraryIndex(root: directory.appending(path: "library"), cacheDirectory: directory.appending(path: "cache"), logger: Logger(label: "test"))
        let api = IngestAPI(library: { library }, queue: queue, encoder: JSONEncoder(), logger: Logger(label: "test"))
        let still = directory.appending(path: "still.png")
        try Self.writePNG(to: still, index: 0)
        api.holdEnqueue("the library root is changing")
        api.holdEnqueue("the library root is changing")
        #expect(api.enqueue(source: still, folder: 1, file: nil, name: nil, codec: nil, fps: nil, keepOriginal: true).status == 409)
        api.releaseEnqueue()
        #expect(api.enqueue(source: still, folder: 1, file: nil, name: nil, codec: nil, fps: nil, keepOriginal: true).status == 409, "holds nest")
        #expect(queue.jobs.isEmpty)
        api.releaseEnqueue()
        #expect(api.enqueue(source: still, folder: 1, file: nil, name: nil, codec: nil, fps: nil, keepOriginal: true).status == 202)
        #expect(queue.jobs.count == 1)
    }

    /// Uploads into one folder in quick succession get their own numbers, while the earlier job is still queued and once
    /// it is written but not yet indexed (the index is never rescanned here, like in the 500 ms before the debounced rescan).
    @Test func quickUploadsIntoOneFolderGetConsecutiveNumbers() async throws {
        let directory = try tempDir("fanous-ingest-tests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = IngestQueue(persistenceURL: directory.appending(path: "queue.json"))
        let library = LibraryIndex(root: directory.appending(path: "library"), cacheDirectory: directory.appending(path: "cache"), logger: Logger(label: "test"))
        let api = IngestAPI(library: { library }, queue: queue, encoder: JSONEncoder(), logger: Logger(label: "test"))
        let sources = (1...3).map { directory.appending(path: "red-\($0).png") }
        for (index, source) in sources.enumerated() { try Self.writePNG(to: source, index: index) }
        func upload(_ source: URL, file: Int? = nil) -> String? {
            #expect(api.enqueue(source: source, folder: 3, file: file, name: "red.png", codec: nil, fps: nil, keepOriginal: false).status == 202)
            return queue.jobs.last?.destination.lastPathComponent
        }

        #expect(upload(sources[0]) == "001_red.png")
        #expect(upload(sources[1]) == "002_red.png")
        #expect(upload(sources[2], file: 1) == "001_red.png", "an explicit file number is taken as given")
        queue.cancel(id: queue.jobs.last!.id)

        queue.start()
        defer { queue.stop() }
        for job in queue.jobs.prefix(2) { #expect(await Self.wait(for: job.id, in: queue) == .done) }
        #expect(upload(sources[2]) == "003_red.png")
        #expect(await Self.wait(for: queue.jobs.last!.id, in: queue) == .done)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
