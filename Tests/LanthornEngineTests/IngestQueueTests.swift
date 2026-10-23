// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers

@testable import LanthornEngine

/// Serialized: `IngestQueue.stop()` parks the test's cooperative-pool thread until the worker exits, and a worker that is
/// just loading an asset needs a pool thread itself; ten tests parked there at once would starve it.
@Suite(.serialized) struct IngestQueueTests {
    // MARK: Helpers

    /// Runs blocking AVFoundation work (`AVAssetWriter.finishWriting` + semaphore) on a thread of its own. Swift Testing runs a
    /// test per core on the cooperative pool, and that many threads parked in `finishWriting` leave AVFoundation no thread to
    /// deliver the completion on: the run hangs (reproduced with a bare AVAssetWriter, no engine code).
    static func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread { continuation.resume(with: Result { try body() }) }
        }
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "lanthorn-ingest-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

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
    static func writeH264(to url: URL, rotated: Bool = false) async throws {
        try await offPool { try writeH264Blocking(to: url, rotated: rotated) }
    }

    private static func writeH264Blocking(to url: URL, rotated: Bool) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let audioInput = AVAssetWriterInput(
            mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
        audioInput.expectsMediaDataInRealTime = false
        writer.add(audioInput)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 176])
        input.expectsMediaDataInRealTime = false
        if rotated { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }  // how a phone held upright tags its footage
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 176,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw MovieWriter.WriterError.failed(writer.error?.localizedDescription ?? "startWriting") }
        writer.startSession(atSourceTime: .zero)
        var description = AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let tone = (0..<44_100).map { Int16(sin(2 * .pi * 440 * Double($0) / 44_100) * 16_000) }
        let block = try tone.withUnsafeBytes { try MovieWriter.blockBuffer(copying: $0) }
        var audioSample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format!, sampleCount: tone.count, presentationTimeStamp: .zero, packetDescriptions: nil,
            sampleBufferOut: &audioSample)
        while !audioInput.isReadyForMoreMediaData { usleep(500) }
        guard audioInput.append(audioSample!) else { throw MovieWriter.WriterError.failed(writer.error?.localizedDescription ?? "append (audio)") }
        audioInput.markAsFinished()
        for frame in 0..<25 {
            while !input.isReadyForMoreMediaData { usleep(500) }
            let buffer = try patternBuffer(pool: adaptor.pixelBufferPool, frame: frame)
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 25)) else {
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

    /// Polls until the job is finished (or `timeout`); returns its last state. Sleeps instead of blocking: the queue's
    /// worker needs a free thread of the cooperative pool for its async asset loads, and parallel tests would hog them.
    @discardableResult
    static func wait(for id: UUID, in queue: IngestQueue, timeout: Double = 8) async -> IngestJob.State {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let job = queue.jobs.first(where: { $0.id == id }), job.state.isFinished { return job.state }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return queue.jobs.first(where: { $0.id == id })?.state ?? .cancelled
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
        let directory = try Self.temporaryDirectory()
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
        let directory = try Self.temporaryDirectory()
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

    // MARK: (c) stills, originals, overwrite

    @Test func stillIsCopiedAndOriginalMoved() async throws {
        let directory = try Self.temporaryDirectory()
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

    @Test func existingDestinationFailsUnlessOverwriteAndSourceCanBeDeleted() async throws {
        let directory = try Self.temporaryDirectory()
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

        let replace = queue.enqueue(IngestJob(source: second, destination: destination, kind: .still, overwrite: true))
        #expect(await Self.wait(for: replace.id, in: queue) == .done)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "two")
        queue.remove(id: one.id)
        queue.remove(id: clash.id)
        #expect(queue.jobs.map(\.id) == [replace.id])
    }

    // MARK: (d) persistence

    @Test func queueSurvivesRestart() async throws {
        let directory = try Self.temporaryDirectory()
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

    // MARK: (e) pause and cancel

    @Test func pauseHoldsAndCancelRemovesPartialOutput() async throws {
        let directory = try Self.temporaryDirectory()
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
        let directory = try Self.temporaryDirectory()
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
        // The AAC track arrives as 48 kHz stereo LPCM, the mono tone on both channels.
        let reader = try await AudioTrackReader.open(url: job.destination)
        #expect(reader.hasAudio && reader.sampleRate == 48_000 && reader.channelCount == 2)
        #expect(abs(reader.duration - 1) < 0.1)
        let (samples, count, _) = AudioTests.read(reader, frames: 24_000)
        #expect(count == 24_000)
        for channel in 0..<2 {
            #expect(AudioTests.peak(samples, channel: channel, frames: 2000..<22_000) > 0.3)
            #expect(abs(AudioTests.crossings(samples, channel: channel, frames: 2000..<22_000) - 366) <= 4)  // 440 Hz over 20 000 frames
        }
    }

    @Test func rotatedSourceIsRejectedNotWrittenSideways() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "rotated.mp4")
        try await Self.writeH264(to: source, rotated: true)
        let queue = IngestQueue(persistenceURL: directory.appending(path: "queue.json"))
        queue.start()
        defer { queue.stop() }
        let job = queue.enqueue(IngestJob(source: source, destination: directory.appending(path: "library/001_rotated.mov"), kind: .transcode(codec: .proRes422HQ)))
        guard case .failed(let message) = await Self.wait(for: job.id, in: queue) else {
            Issue.record("expected a failure")
            return
        }
        #expect(message.contains("rotated"))
        #expect(!FileManager.default.fileExists(atPath: job.destination.path))
    }

    @Test func cancelledSequenceLeavesNothing() async throws {
        let directory = try Self.temporaryDirectory()
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
        let directory = try Self.temporaryDirectory()
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
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
