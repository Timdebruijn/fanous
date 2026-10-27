// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import CoreMedia
import Foundation

/// Writes a QuickTime movie: ProRes through AVFoundation's hardware encoder,
/// HAP through `HAPEncoder` and AVAssetWriter sample passthrough. Optionally
/// adds a 48 kHz stereo 16-bit LPCM track: either the `TestTone` (`audio`) or
/// sample buffers the caller supplies through `appendAudio(_:)` (`externalAudio`).
public final class MovieWriter {
    public enum Codec: Sendable, Equatable, Codable {
        case proRes422HQ
        case proRes422
        case proRes4444
        case hap(HAPEncoder.Variant)

        public var name: String {
            switch self {
            case .proRes422HQ: "prores422hq"
            case .proRes422: "prores422"
            case .proRes4444: "prores4444"
            case .hap(let variant): variant.rawValue.lowercased()
            }
        }
    }

    public enum WriterError: Error { case notReady, failed(String) }

    public let width: Int
    public let height: Int
    public let fps: Int32
    /// Presentation time step of one video frame: `1/fps` unless the caller needs a rational rate (30000/1001).
    public let frameDuration: CMTime
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var hap: HAPEncoder?
    private let hapFormat: CMFormatDescription?
    private let audioInput: AVAssetWriterInput?
    private let audioFormat: CMAudioFormatDescription?
    private let testTone: Bool
    private var frame: Int64 = 0

    /// `audio: true` adds an LPCM 48 kHz stereo track (`TestTone`), written per video frame so its length matches the video.
    /// `externalAudio: true` adds the same track but leaves it empty: feed it with `appendAudio(_:)` (16-bit interleaved
    /// stereo at 48 kHz, in step with the video: the writer interleaves sparsely and stalls if audio runs far behind).
    /// `frameDuration` overrides `1/fps` for rational rates; `fps` stays the rounded integer rate.
    public init(
        url: URL, width: Int, height: Int, fps: Int32, frameDuration: CMTime? = nil, codec: Codec, audio: Bool = false,
        externalAudio: Bool = false
    ) throws {
        precondition(!(audio && externalAudio), "audio is either the test tone or caller-supplied")
        self.width = width
        self.height = height
        self.fps = fps
        self.frameDuration = frameDuration ?? CMTime(value: 1, timescale: fps)
        testTone = audio
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        switch codec {
        case .hap(let variant):
            var description: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, codecType: variant.fourCC, width: Int32(width), height: Int32(height),
                extensions: nil, formatDescriptionOut: &description)
            guard status == noErr, let description else { throw WriterError.failed("format description \(status)") }
            hapFormat = description
            hap = HAPEncoder(variant: variant, width: width, height: height)
            input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: description)
            adaptor = nil
        default:
            let codecType: AVVideoCodecType =
                switch codec {
                case .proRes422HQ: .proRes422HQ
                case .proRes422: .proRes422
                default: .proRes4444
                }
            hapFormat = nil
            input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [AVVideoCodecKey: codecType, AVVideoWidthKey: width, AVVideoHeightKey: height])
            adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                ])
        }
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw WriterError.failed("cannot add input") }
        writer.add(input)
        if audio || externalAudio {
            var description = AudioStreamBasicDescription(
                mSampleRate: TestTone.sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
                mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
            var format: CMAudioFormatDescription?
            let status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
                magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
            guard status == noErr, let format else { throw WriterError.failed("audio format description \(status)") }
            let audioInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: TestTone.sampleRate, AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ], sourceFormatHint: format)
            audioInput.expectsMediaDataInRealTime = false
            // Fed in lockstep with the video, one frame at a time. With the default (tightly interleaved) the writer holds
            // video back until it has a full second of audio ahead of it, and append() stalls forever around frame 37.
            // ponytail: sparse interleave needs macOS 26; the floor is 15, where this fails loudly instead of hanging.
            // A requestMediaDataWhenReady pull model per input would work everywhere.
            guard #available(macOS 26.0, *) else { throw WriterError.failed("an audio track needs macOS 26 or newer") }
            audioInput.mediaDataLocation = .sparselyInterleavedWithMainMediaData
            guard writer.canAdd(audioInput) else { throw WriterError.failed("cannot add audio input") }
            writer.add(audioInput)
            self.audioInput = audioInput
            audioFormat = format
        } else {
            audioInput = nil
            audioFormat = nil
        }
        guard writer.startWriting() else { throw WriterError.failed(writer.error?.localizedDescription ?? "startWriting") }
        writer.startSession(atSourceTime: .zero)
    }

    /// A BGRA pixel buffer from `pixelBufferPool` (ProRes) or any BGRA buffer (HAP).
    public var pixelBufferPool: CVPixelBufferPool? { adaptor?.pixelBufferPool }

    deinit {
        // An early exit (error, cancel) must not leave the writer open: it asserts or leaves a half-written file.
        if writer.status == .writing { writer.cancelWriting() }
    }

    /// Abandons the movie: the writer stops and deletes the partial file.
    public func cancel() { writer.cancelWriting() }

    public func append(_ pixelBuffer: CVPixelBuffer) throws {
        if testTone { try appendTestTone() }
        try waitUntilReady(input)
        let time = CMTime(value: frame * frameDuration.value, timescale: frameDuration.timescale)
        if let adaptor {
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw WriterError.failed(writer.error?.localizedDescription ?? "append")
            }
        } else if var encoder = hap, let hapFormat {
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
            let bytes = try encoder.encode(bgra: base, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer))
            hap = encoder
            let sample = try Self.sampleBuffer(bytes: bytes, format: hapFormat, time: time, duration: frameDuration)
            guard input.append(sample) else { throw WriterError.failed(writer.error?.localizedDescription ?? "append (HAP passthrough)") }
        }
        frame += 1
    }

    /// The audio samples that belong to video frame `frame`: `[frame * 48000 / fps, (frame + 1) * 48000 / fps)`,
    /// so any integer fps stays sample-exact and the phase of the tones is continuous across frames.
    private func appendTestTone() throws {
        guard audioInput != nil, let audioFormat else { return }
        let first = frame * Int64(TestTone.sampleRate) / Int64(fps)
        let count = Int((frame + 1) * Int64(TestTone.sampleRate) / Int64(fps) - first)
        let samples = [Int16](unsafeUninitializedCapacity: count * 2) { buffer, initialized in
            TestTone.fill(interleaved: buffer.baseAddress!, firstFrame: first, count: count)
            initialized = count * 2
        }
        let block = try samples.withUnsafeBytes { try Self.blockBuffer(copying: $0) }
        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: audioFormat, sampleCount: count,
            presentationTimeStamp: CMTime(value: first, timescale: Int32(TestTone.sampleRate)), packetDescriptions: nil,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw WriterError.failed("audio sample buffer \(status)") }
        try appendAudio(sample)
    }

    /// Appends caller-supplied audio (`externalAudio`): LPCM, 48 kHz, stereo, 16-bit interleaved; blocks until the writer
    /// takes it. Timestamps are written as given, on the same timeline as the video (frame `n` is at `n * frameDuration`).
    public func appendAudio(_ sampleBuffer: CMSampleBuffer) throws {
        guard let audioInput else { throw WriterError.notReady }
        try waitUntilReady(audioInput)
        guard audioInput.append(sampleBuffer) else { throw WriterError.failed(writer.error?.localizedDescription ?? "append (audio)") }
    }

    /// Polls like the writer's own pull model would, but gives up when the writer has failed or been cancelled
    /// (`isReadyForMoreMediaData` then stays false forever).
    private func waitUntilReady(_ input: AVAssetWriterInput) throws {
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else { throw WriterError.failed(writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)") }
            usleep(500)
        }
    }

    /// Blocks until AVFoundation has finished the file. Call it from a plain thread (the ingest worker, a CLI), never from a
    /// Swift concurrency task: with the cooperative pool full of tasks parked here the completion never arrives (B63; likely
    /// because the completion queue, `com.apple.root.default-qos`, then gets no worker thread).
    public func finish() throws {
        input.markAsFinished()
        audioInput?.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw WriterError.failed(writer.error?.localizedDescription ?? "finishWriting \(writer.status.rawValue)") }
    }

    /// A block buffer that owns a copy of `bytes`.
    static func blockBuffer(copying bytes: UnsafeRawBufferPointer) throws -> CMBlockBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw WriterError.failed("block buffer \(status)") }
        status = CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        guard status == noErr else { throw WriterError.failed("block copy \(status)") }
        return block
    }

    static func sampleBuffer(bytes: ArraySlice<UInt8>, format: CMFormatDescription, time: CMTime, duration: CMTime) throws -> CMSampleBuffer {
        let block = try bytes.withUnsafeBytes { try blockBuffer(copying: $0) }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var size = bytes.count
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw WriterError.failed("sample buffer \(status)") }
        return sample
    }
}

extension HAPEncoder.Variant: Codable {}

/// Synthetic benchmark content: animated gradient, a moving bar and a 16-bit
/// binary frame counter (32 px squares, top-left) so decoded frames are identifiable.
public enum PatternFrames {
    public static func fill(bgra: UnsafeMutablePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, frame: Int) {
        let barX = (frame * 8) % max(1, width - 16)
        for y in 0..<height {
            let row = bgra + y * bytesPerRow
            let green = UInt8(y * 255 / max(1, height - 1))
            for x in 0..<width {
                let p = row + x * 4
                var r = UInt8((x * 255 / max(1, width - 1) + frame * 2) & 255)
                var g = green
                var b: UInt8 = 128
                if x >= barX && x < barX + 16 { r = 255; g = 255; b = 255 }
                if y < 32 && x < 32 * 16 {
                    let bit = 15 - x / 32
                    let on = (frame >> bit) & 1 == 1
                    r = on ? 255 : 0; g = r; b = r
                }
                p[0] = b; p[1] = g; p[2] = r; p[3] = 255
            }
        }
    }

    /// Reads the counter back from a BGRA frame (tests and the decode spike).
    public static func counter(bgra: UnsafePointer<UInt8>, bytesPerRow: Int) -> Int {
        var value = 0
        for i in 0..<16 {
            let p = bgra + 16 * bytesPerRow + (i * 32 + 16) * 4
            if p[2] > 127 { value |= 1 << (15 - i) }
        }
        return value
    }
}

/// Synthetic audio for benchmark and test media: 1 kHz on the left, 440 Hz on the
/// right, and at every whole second a 10 ms "click" on both channels. The click
/// is the tone at full level instead of half level (a level step, easy to find
/// by threshold, and it leaves the zero-crossing count of the tone intact).
public enum TestTone {
    public static let sampleRate = 48_000.0
    public static let leftFrequency = 1000.0
    public static let rightFrequency = 440.0
    public static let toneLevel = 0.5
    public static let clickLevel = 0.95
    /// Click length in frames (10 ms).
    public static let clickFrames = 480

    /// Interleaved 16-bit stereo for frames `firstFrame ..< firstFrame + count` of the stream.
    public static func fill(interleaved: UnsafeMutablePointer<Int16>, firstFrame: Int64, count: Int) {
        let rate = Int64(sampleRate)
        for i in 0..<count {
            let n = firstFrame + Int64(i)
            let level = (n % rate) < Int64(clickFrames) ? clickLevel : toneLevel
            let t = Double(n) / sampleRate
            interleaved[2 * i] = Int16((sin(2 * .pi * leftFrequency * t) * level * 32767).rounded())
            interleaved[2 * i + 1] = Int16((sin(2 * .pi * rightFrequency * t) * level * 32767).rounded())
        }
    }
}
