// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import CoreMedia
import Foundation

/// Writes a QuickTime movie: ProRes through AVFoundation's hardware encoder,
/// HAP through `HAPEncoder` and AVAssetWriter sample passthrough. Optionally
/// adds an LPCM track: either the `TestTone` (`audio`, 48 kHz stereo 16-bit) or
/// sample buffers the caller supplies through `appendAudio(_:)` (`externalAudio`,
/// in the format the caller names).
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

        /// The codec whose `name` is `name` (any case); nil for none.
        public static func named(_ name: String?) -> Codec? {
            ([.proRes422HQ, .proRes422, .proRes4444] + HAPEncoder.Variant.allCases.map(Codec.hap)).first { $0.name == name?.lowercased() }
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
    /// `externalAudio` adds an empty LPCM track in that format (interleaved; the source's sample rate, channels and bit
    /// depth, B19): feed it with `appendAudio(_:)` in step with the video (the writer interleaves sparsely and stalls if
    /// audio runs far behind). `frameDuration` overrides `1/fps` for rational rates; `fps` stays the rounded integer rate.
    /// `pixelAspect` (horizontal, vertical spacing) tags the track for anamorphic frames (B19); nil is square pixels.
    /// `pixelFormat` is what `append` gets for ProRes (BGRA, or a 16-bit RGB format, 64ARGB or 64RGBALE, to keep more than
    /// 8 bits); HAP takes BGRA only (any other format throws).
    public init(
        url: URL, width: Int, height: Int, fps: Int32, frameDuration: CMTime? = nil, codec: Codec, audio: Bool = false,
        externalAudio: CMAudioFormatDescription? = nil, pixelAspect: (horizontal: Int, vertical: Int)? = nil,
        pixelFormat: OSType = kCVPixelFormatType_32BGRA
    ) throws {
        precondition(!(audio && externalAudio != nil), "audio is either the test tone or caller-supplied")
        let duration = frameDuration ?? CMTime(value: 1, timescale: fps)
        guard fps > 0, duration.isNumeric, duration.seconds > 0 else { throw WriterError.failed("frame rate must be positive") }  // a job that got through would trap below
        self.width = width
        self.height = height
        self.fps = fps
        self.frameDuration = frameDuration ?? CMTime(value: 1, timescale: fps)
        testTone = audio
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let aspectExtension: [String: Any]? = pixelAspect.map { [
            kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String: $0.horizontal,
            kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String: $0.vertical,
        ] }
        switch codec {
        case .hap(let variant):
            guard pixelFormat == kCVPixelFormatType_32BGRA else { throw WriterError.failed("HAP is encoded from BGRA frames") }
            var description: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, codecType: variant.fourCC, width: Int32(width), height: Int32(height),
                extensions: aspectExtension.map { [kCMFormatDescriptionExtension_PixelAspectRatio as String: $0] as CFDictionary },
                formatDescriptionOut: &description)
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
            // Rec.709 by name (B21): the transcoder's RGB frames carry the source's YCbCr matrix as an attachment, and
            // without these the writer coded and tagged the file with it, so a Rec.601 source became a 601 file that the
            // layer shader (one 709 matrix) read 15–40 codes off on saturated colours. The frames are RGB, so the writer's
            // own 709 matrix is the right one for every source; the 709 primaries and transfer are true for SDR sources only (an
            // HDR/BT.2020 source's RGB frames keep their own primaries and transfer; not measured, no such source here)
            let rec709: [String: Any] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
            var settings: [String: Any] = [AVVideoCodecKey: codecType, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoColorPropertiesKey: rec709]
            if let pixelAspect {
                settings[AVVideoPixelAspectRatioKey] = [AVVideoPixelAspectRatioHorizontalSpacingKey: pixelAspect.horizontal, AVVideoPixelAspectRatioVerticalSpacingKey: pixelAspect.vertical]
            }
            input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                    kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                ])
        }
        input.expectsMediaDataInRealTime = false
        // The track's timescale holds the frame duration exactly: 600 for 24/25/30/50/60/120, else the duration's own
        // (30000 for 29.97; the default 600 would store it as 20/21 ticks and report a 30 fps minimum frame duration).
        input.mediaTimeScale = 600 % self.frameDuration.timescale == 0 ? 600 : self.frameDuration.timescale
        guard writer.canAdd(input) else { throw WriterError.failed("cannot add input") }
        writer.add(input)
        if audio || externalAudio != nil {
            let format: CMAudioFormatDescription
            if let externalAudio {
                format = externalAudio
            } else {
                var description = AudioStreamBasicDescription(
                    mSampleRate: TestTone.sampleRate, mFormatID: kAudioFormatLinearPCM,
                    mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
                    mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
                var tone: CMAudioFormatDescription?
                let status = CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
                    magicCookie: nil, extensions: nil, formatDescriptionOut: &tone)
                guard status == noErr, let tone else { throw WriterError.failed("audio format description \(status)") }
                format = tone
            }
            // LPCM samples go in as they are (passthrough): the track is whatever `format` says, nothing is re-encoded.
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
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

    /// Pixel buffers in the init's `pixelFormat` (ProRes); nil for HAP, which takes any BGRA buffer.
    public var pixelBufferPool: CVPixelBufferPool? { adaptor?.pixelBufferPool }

    /// A pixel buffer of the movie's size: from `pixelBufferPool` (ProRes) or a new BGRA one (HAP).
    public func makePixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        if let pool = pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        } else {
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        }
        guard let buffer else { throw WriterError.failed("pixel buffer") }
        return buffer
    }

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

    /// Appends caller-supplied audio (`externalAudio`): LPCM in the format given at init; blocks until the writer
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
