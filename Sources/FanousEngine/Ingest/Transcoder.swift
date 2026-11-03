// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import Accelerate
import AudioToolbox
import CoreMedia
import Foundation
import Synchronization

public enum TranscodeError: Error, CustomStringConvertible {
    case noVideoTrack(URL)
    case hapDimensions(Int, Int)
    case reader(String)
    case noFrames
    case cancelled

    public var description: String {
        switch self {
        case .noVideoTrack(let url): "\(url.lastPathComponent) has no video track"
        case .hapDimensions(let w, let h): "HAP needs a width and height that are multiples of 4, the source is \(w)×\(h)"
        case .reader(let message): "cannot read the source: \(message)"
        case .noFrames: "the source has no decodable video frames"
        case .cancelled: "cancelled"
        }
    }
}

/// What a running job checks between frames (DESIGN.md §8.3): cancel, yield to the compositor, and a hard pause (show lock).
final class IngestGate: Sendable {
    private let cancelled = Atomic<Bool>(false)
    private let shouldYield: @Sendable () -> Bool
    private let isPaused: @Sendable () -> Bool

    init(shouldYield: @escaping @Sendable () -> Bool, isPaused: @escaping @Sendable () -> Bool) {
        self.shouldYield = shouldYield
        self.isPaused = isPaused
    }

    var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    func cancel() { cancelled.store(true, ordering: .relaxed) }

    func throwIfCancelled() throws {
        if isCancelled { throw TranscodeError.cancelled }
    }

    /// Called between frames. A pause blocks (polling every 20 ms) until it ends or the job is cancelled; a yield
    /// costs one 20 ms sleep per frame, so a permanently busy compositor slows ingest to 50 fps but never starves it.
    func checkpoint() throws {
        try throwIfCancelled()
        while isPaused() {
            Thread.sleep(forTimeInterval: 0.02)
            try throwIfCancelled()
        }
        if shouldYield() {
            Thread.sleep(forTimeInterval: 0.02)
            try throwIfCancelled()
        }
    }
}

/// Converts one source movie (anything AVFoundation can read) to a `.mov` the engine plays (DESIGN.md §8.3): ProRes or
/// HAP video from BGRA frames, audio as interleaved LPCM in the source's sample rate, channels and bit depth (see
/// `lpcmFormat` for the exceptions). Runs on the calling thread; a run cancelled through its gate (from any thread)
/// removes its partial output.
public enum Transcoder {
    /// An alpha source must keep its alpha: ProRes 422 becomes 4444, HAP and HAP Q become HAP Alpha. HAP Q Alpha ('HapM')
    /// is not available in `HAPEncoder` (it has no two-texture frames), so HAP Q loses its quality tier here, not its alpha.
    public static func effectiveCodec(_ requested: MovieWriter.Codec, sourceHasAlpha: Bool) -> MovieWriter.Codec {
        guard sourceHasAlpha else { return requested }
        switch requested {
        case .proRes422HQ, .proRes422: return .proRes4444
        case .hap(let variant) where variant == .hap || variant == .hapQ: return .hap(.hapAlpha)
        default: return requested
        }
    }

    /// Transcodes `source` to `destination` (replacing a file already there). `progress` gets (frames written, frames
    /// expected); the expectation is derived from the track duration and may be off by a frame.
    static func run(
        source: URL, destination: URL, codec: MovieWriter.Codec, gate: IngestGate, progress: ((_ framesDone: Int, _ framesTotal: Int) -> Void)? = nil
    ) throws {
        try gate.throwIfCancelled()
        let probe = try blockingAwait { [source] in try await Probe.load(source) }
        let requested = Self.effectiveCodec(codec, sourceHasAlpha: probe.hasAlpha)

        let reader = try AVAssetReader(asset: probe.asset)
        let bgra = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let videoOutput: AVAssetReaderOutput
        if let composition = probe.upright {  // an odd transform (not a quarter turn or flip): the composition bakes it in, over opaque black
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: [probe.video], videoSettings: bgra)
            output.videoComposition = composition
            videoOutput = output
        } else {
            videoOutput = AVAssetReaderTrackOutput(track: probe.video, outputSettings: bgra)
        }
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw TranscodeError.reader("cannot read the video track") }
        reader.add(videoOutput)
        var audioOutput: AVAssetReaderAudioMixOutput?
        var audioFormat: CMAudioFormatDescription?
        if let audio = probe.audio, let source = probe.audioFormat, let (format, settings) = Self.lpcmFormat(matching: source) {
            let output = AVAssetReaderAudioMixOutput(audioTracks: [audio], audioSettings: settings)
            if reader.canAdd(output) {  // an undecodable audio track must not block the video
                reader.add(output)
                audioOutput = output
                audioFormat = format
            }
        }
        // ponytail: AVFoundation has no HAP decoder ("Cannot Decode"), so a HAP source fails here; the engine's own
        // decoder (MovieSource) plus a texture read-back would cover it, but HAP is already playable and needs no ingest.
        guard reader.startReading() else {
            throw TranscodeError.reader("\(fourCCString(probe.codec)): \(reader.error?.localizedDescription ?? "startReading failed")")
        }

        let expected = max(1, Int((probe.duration.seconds / probe.frameDuration.seconds).rounded()))
        var writer: MovieWriter?
        var written = 0
        var audioEnd = CMTime.zero
        var audioDone = audioOutput == nil
        // Hold/drop by presentation time (B19): output frame k shows the latest source frame at or before its middle,
        // (k + ½) frame durations. Sampling the middle, not the start, keeps a source whose timestamps are quantised
        // (1 ms timescales from OBS remuxes) frame for frame instead of dropping and doubling every third one. A
        // constant-rate source comes out frame for frame; a variable-rate one (screen recordings) is held or dropped so
        // it stays in step with its audio.
        var held: CVPixelBuffer?
        /// Output frames whose middle lies before `time`.
        func slots(before time: CMTime) -> Int {
            max(0, Int((time.seconds / probe.frameDuration.seconds - 0.5).rounded(.up)))
        }
        /// Writes `held` until `count` frames are out, the audio in step; a long hold (a static stretch of a screen
        /// recording) still yields to the compositor and pauses under show lock.
        func emit(upTo count: Int) throws {
            while written < count, let held, let writer {
                try gate.checkpoint()
                try pumpAudio(until: CMTime(value: Int64(written + 1) * probe.frameDuration.value, timescale: probe.frameDuration.timescale))
                try writer.append(held)  // ProRes: the reader's buffer goes straight to the adaptor; HAP: encoded from BGRA
                written += 1
                progress?(written, max(written, expected))
            }
        }

        /// Audio is written up to the end of the current video frame, in step with the video (MovieWriter interleaves sparsely).
        func pumpAudio(until limit: CMTime) throws {
            while !audioDone, audioEnd < limit, let output = audioOutput, let writer {
                try gate.throwIfCancelled()
                guard let sample = output.copyNextSampleBuffer() else {
                    audioDone = true
                    if reader.status == .failed { throw TranscodeError.reader(reader.error?.localizedDescription ?? "audio") }
                    return
                }
                audioEnd = CMSampleBufferGetPresentationTimeStamp(sample) + CMSampleBufferGetDuration(sample)
                try writer.appendAudio(sample)
            }
        }

        do {
            while true {
                try gate.throwIfCancelled()  // emit() checkpoints per output frame
                let finished = try autoreleasepool { () throws -> Bool in
                    guard let sample = videoOutput.copyNextSampleBuffer(), let decoded = CMSampleBufferGetImageBuffer(sample) else { return true }
                    if writer == nil {
                        // Size from the decoded buffer, not the track: anamorphic and cropped sources differ. The pixel
                        // aspect ratio goes with it (B19), swapped by a quarter turn; not on the composition path, which
                        // renders the display size with square pixels.
                        var width = CVPixelBufferGetWidth(decoded), height = CVPixelBufferGetHeight(decoded)
                        var pixelAspect = probe.upright == nil ? probe.pixelAspect : nil
                        if let turn = probe.turn, turn.swapsAxes {
                            swap(&width, &height)
                            pixelAspect = pixelAspect.map { ($0.vertical, $0.horizontal) }
                        }
                        if case .hap = requested, width % 4 != 0 || height % 4 != 0 { throw TranscodeError.hapDimensions(width, height) }
                        writer = try MovieWriter(
                            url: destination, width: width, height: height, fps: Int32((1 / probe.frameDuration.seconds).rounded()),
                            frameDuration: probe.frameDuration, codec: requested, externalAudio: audioFormat, pixelAspect: pixelAspect)
                    }
                    // A quarter turn or flip is done here in the pixels (vImage, exact, alpha kept: B18) instead of by a composition.
                    let pixels = try probe.turn.map { try $0.apply(to: decoded, into: try writer!.makePixelBuffer()) } ?? decoded
                    // Both video and audio are written at their source times (AVAssetReader has applied the edit lists,
                    // so a track starts at 0); a first frame that sits later than 0 is held from 0.
                    if held == nil { held = pixels }
                    try emit(upTo: slots(before: CMSampleBufferGetPresentationTimeStamp(sample)))
                    held = pixels
                    return false
                }
                if finished { break }
            }
            if reader.status == .failed { throw TranscodeError.reader(reader.error?.localizedDescription ?? "unknown") }
            try emit(upTo: max(written + 1, slots(before: probe.start + probe.duration)))  // the last frame, to the track's end (nearest frame)
            guard let writer, written > 0 else { throw TranscodeError.noFrames }
            try pumpAudio(until: CMTime(value: .max, timescale: 1))  // the audio tail, if it outlasts the video
            try gate.throwIfCancelled()
            try writer.finish()
        } catch {
            reader.cancelReading()
            if let writer {
                writer.cancel()
                try? FileManager.default.removeItem(at: destination)
            }
            throw error
        }
    }

    /// The interleaved LPCM the library stores for `source` (ADR-0019: what `AudioTrackReader` reads without a
    /// compressed-audio decoder, converting to 48 kHz stereo float itself), as a format description for `MovieWriter` and
    /// the matching reader settings. The source's sample rate and channel count/layout stay, an LPCM source keeps its bit
    /// depth and integer/float form, a compressed source (AAC, ...) decodes to 24-bit (B19). The exceptions are what
    /// `AVAssetReaderAudioMixOutput` refuses (it raises, which would kill the engine): the rate is clamped to 8–192 kHz,
    /// the depth to 8/16/24/32 (float is always 32), a layout that does not match the channel count is replaced by one
    /// made from the count, a track without a channel count gets stereo.
    /// ponytail: more than two channels are mixed down to stereo here, as before, because the player takes channels 0 and
    /// 1 by index (a 5.1 file would lose its centre); keep them once `AudioTrackReader` has a matrix mix (B143).
    /// Nil only when the format description cannot be made.
    static func lpcmFormat(matching source: CMAudioFormatDescription) -> (CMAudioFormatDescription, [String: Any])? {
        let input = CMAudioFormatDescriptionGetStreamBasicDescription(source)?.pointee
        let rate = min(max(input?.mSampleRate ?? 48_000, 8_000), 192_000)
        let sourceChannels = input?.mChannelsPerFrame ?? 0
        let channels: UInt32 = sourceChannels == 0 || sourceChannels > 2 ? 2 : sourceChannels
        let isLPCM = input?.mFormatID == kAudioFormatLinearPCM && (input?.mBitsPerChannel ?? 0) > 0
        let isFloat = isLPCM && (input?.mFormatFlags ?? 0) & kAudioFormatFlagIsFloat != 0
        let wanted: UInt32 = isLPCM ? input!.mBitsPerChannel : 24
        let bits: UInt32 = isFloat ? 32 : [8, 16, 24, 32].first { $0 >= wanted } ?? 32
        var description = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: (isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bits / 8 * channels, mFramesPerPacket: 1, mBytesPerFrame: bits / 8 * channels, mChannelsPerFrame: channels,
            mBitsPerChannel: bits, mReserved: 0)
        // The source's layout when it has one that agrees with the channel count; mono/stereo by count otherwise.
        var layoutSize = 0
        var layoutData: Data?
        if channels == sourceChannels, let layout = CMAudioFormatDescriptionGetChannelLayout(source, sizeOut: &layoutSize), layoutSize > 0 {
            var count: UInt32 = 0
            var countSize = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioFormatGetProperty(kAudioFormatProperty_NumberOfChannelsForLayout, UInt32(layoutSize), layout, &countSize, &count)
            if status == noErr, count == channels { layoutData = Data(bytes: layout, count: layoutSize) }
        }
        if layoutData == nil {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
            layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        var format: CMAudioFormatDescription?
        let status = layoutData!.withUnsafeBytes { bytes in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &description, layoutSize: bytes.count,
                layout: bytes.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self), magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &format)
        }
        guard status == noErr, let format else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: isFloat, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false, AVChannelLayoutKey: layoutData!,
        ]
        return (format, settings)
    }

    /// 23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60, 100 and 120 fps, as exact durations.
    static let standardFrameDurations: [CMTime] = [
        CMTime(value: 1001, timescale: 24000), CMTime(value: 1, timescale: 24), CMTime(value: 1, timescale: 25), CMTime(value: 1001, timescale: 30000),
        CMTime(value: 1, timescale: 30), CMTime(value: 1, timescale: 48), CMTime(value: 1, timescale: 50), CMTime(value: 1001, timescale: 60000),
        CMTime(value: 1, timescale: 60), CMTime(value: 1, timescale: 100), CMTime(value: 1, timescale: 120),
    ]

    /// The standard frame duration nearest to `rate`, when within 0.5 % of it (29.97 and 30 are 0.1 % apart, so nearest,
    /// not first); nil otherwise. A track with a 1 ms timescale reports 33 ms for 30 fps, and 33 ms output would drift a
    /// frame every 3 s against the source and its audio.
    static func standardFrameDuration(nearest rate: Double) -> CMTime? {
        guard rate > 0, let nearest = standardFrameDurations.min(by: { abs(1 / $0.seconds - rate) < abs(1 / $1.seconds - rate) }),
            abs(1 / nearest.seconds / rate - 1) < 0.005
        else { return nil }
        return nearest
    }

    /// A `preferredTransform` that is a quarter turn or a flip, applied in the pixels: exact (no resampling) and alpha kept.
    enum Turn: Equatable {
        /// A `vImageRotate90_ARGB8888` constant (`kRotate90DegreesClockwise` and friends).
        case quarter(UInt8)
        case flipHorizontal
        case flipVertical

        /// The turn for `transform` (its linear part; the translation only re-origins the rotated frame), nil for anything else.
        init?(_ transform: CGAffineTransform) {
            switch (transform.a, transform.b, transform.c, transform.d) {
            case (0, 1, -1, 0): self = .quarter(UInt8(kRotate90DegreesClockwise))  // a phone held upright tags its landscape pixels this way (measured: matches the composition)
            case (0, -1, 1, 0): self = .quarter(UInt8(kRotate90DegreesCounterClockwise))
            case (-1, 0, 0, -1): self = .quarter(UInt8(kRotate180DegreesClockwise))
            case (-1, 0, 0, 1): self = .flipHorizontal
            case (1, 0, 0, -1): self = .flipVertical
            default: return nil
            }
        }

        var swapsAxes: Bool { if case .quarter(let constant) = self { return constant != UInt8(kRotate180DegreesClockwise) } else { return false } }

        /// `source` turned into `destination` (sized for it: swapped for a quarter turn); returns `destination`.
        func apply(to source: CVPixelBuffer, into destination: CVPixelBuffer) throws -> CVPixelBuffer {
            CVPixelBufferLockBaseAddress(source, .readOnly)
            CVPixelBufferLockBaseAddress(destination, [])
            defer {
                CVPixelBufferUnlockBaseAddress(source, .readOnly)
                CVPixelBufferUnlockBaseAddress(destination, [])
            }
            var from = vImage_Buffer(
                data: CVPixelBufferGetBaseAddress(source), height: vImagePixelCount(CVPixelBufferGetHeight(source)),
                width: vImagePixelCount(CVPixelBufferGetWidth(source)), rowBytes: CVPixelBufferGetBytesPerRow(source))
            var to = vImage_Buffer(
                data: CVPixelBufferGetBaseAddress(destination), height: vImagePixelCount(CVPixelBufferGetHeight(destination)),
                width: vImagePixelCount(CVPixelBufferGetWidth(destination)), rowBytes: CVPixelBufferGetBytesPerRow(destination))
            var transparent: [UInt8] = [0, 0, 0, 0]
            let error =
                switch self {
                case .quarter(let constant): vImageRotate90_ARGB8888(&from, &to, constant, &transparent, vImage_Flags(kvImageNoFlags))
                case .flipHorizontal: vImageHorizontalReflect_ARGB8888(&from, &to, vImage_Flags(kvImageNoFlags))
                case .flipVertical: vImageVerticalReflect_ARGB8888(&from, &to, vImage_Flags(kvImageNoFlags))
                }
            guard error == kvImageNoError else { throw TranscodeError.reader("turn (vImage) failed: \(error)") }
            return destination
        }
    }

    /// Track properties, loaded once (async API; the caller's thread is not a cooperative one, so blocking is fine,
    /// like `MediaLoader`).
    private struct Probe: @unchecked Sendable {  // AVAssetTrack is not Sendable in this SDK; the probe is handed over once and then used by one thread
        let asset: AVURLAsset
        let video: AVAssetTrack
        let audio: AVAssetTrack?
        let audioFormat: CMAudioFormatDescription?
        /// Output frame duration: a constant-rate source's nominal rate (its smallest frame duration when no standard rate
        /// is within 0.5 %); a variable-rate source (its nominal rate differs from its smallest frame duration by over
        /// 1 %) gets its fastest rate, at most 60 fps. Snapped to a standard rate (`standardFrameDurations`), so a 1 ms
        /// timescale (33/34 ms) still means 1/30.
        let frameDuration: CMTime
        let start: CMTime
        let duration: CMTime
        let hasAlpha: Bool
        /// The track's `preferredTransform` when it is a quarter turn or a flip: applied in the pixels by the read loop.
        let turn: Turn?
        /// Non-nil for any other rotation/flip transform: a composition applies it and sizes the render to match (over opaque black).
        let upright: AVVideoComposition?
        /// The track's `PixelAspectRatio` extension (horizontal, vertical spacing); nil for square pixels.
        let pixelAspect: (horizontal: Int, vertical: Int)?
        let codec: FourCharCode

        static func load(_ url: URL) async throws -> Probe {
            let asset = AVURLAsset(url: url)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw TranscodeError.noVideoTrack(url) }
            let audio = try await asset.loadTracks(withMediaType: .audio).first
            let audioFormat = try? await audio?.load(.formatDescriptions).first  // a track whose format will not load is skipped, like an undecodable one
            let (nominal, minimum, range, formats, transform) = try await video.load(
                .nominalFrameRate, .minFrameDuration, .timeRange, .formatDescriptions, .preferredTransform)
            // Constant-rate sources: the nominal rate (frames over duration, exact on any timescale) snapped to a standard
            // rate, else the smallest frame duration as it is. Fall back to the nominal rate without a usable minimum.
            var frameDuration: CMTime
            if !minimum.isNumeric || minimum.seconds <= 0 {
                guard nominal > 0 else { throw TranscodeError.reader("unknown frame rate") }
                frameDuration = Transcoder.standardFrameDuration(nearest: Double(nominal)) ?? CMTime(value: 1, timescale: CMTimeScale(nominal.rounded()))
            } else if abs(minimum.seconds * Double(nominal) - 1) > max(0.01, Double(nominal) / Double(minimum.timescale) + 1e-9) {
                // (over 1 %, or over one tick of the track's timescale: 29.97 on a 1 ms timescale reports 33 ms, 1.1 % off)
                // Variable rate: the fastest rate, so no frame is lost; the smallest gap would make a 1000 fps file of a
                // screen recording with one short gap, so at most 60 fps.
                // ponytail: 60 fps ceiling (no canvas runs faster today; raise it with 120 Hz canvases), and one glitch
                // frame in a 30 fps file still doubles it to 60 fps; a percentile of the sample durations would be the fix.
                let rate = min(60, max(1, (1 / minimum.seconds).rounded()))
                frameDuration = Transcoder.standardFrameDuration(nearest: rate) ?? CMTime(value: 1, timescale: CMTimeScale(rate))
            } else if let standard = Transcoder.standardFrameDuration(nearest: Double(nominal)) {
                frameDuration = standard
            } else if abs(Double(nominal) / Double(nominal).rounded() - 1) < 0.005 {
                frameDuration = CMTime(value: 1, timescale: CMTimeScale(nominal.rounded()))  // 15 fps on a 1 ms timescale: 1/15, not 66 ms
            } else {
                frameDuration = minimum
            }
            let alpha = formats.contains { description in
                let flag = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel)
                let subtype = CMFormatDescriptionGetMediaSubType(description)
                return (flag as? Bool) == true || [makeFourCC("Hap5"), makeFourCC("HapM"), makeFourCC("HapA")].contains(subtype)
            }
            let turn = Turn(transform)
            // ponytail: only an odd transform (not a quarter turn or flip) still goes through the composition, which renders over
            // opaque black: such a source with alpha keeps the alpha codec but loses the alpha channel.
            var composition: AVMutableVideoComposition?
            if transform.rotatesOrFlips, turn == nil {
                composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
                composition?.frameDuration = frameDuration  // caps the composition's rate; the read loop sets the cadence (it delivers the source times)
            }
            var pixelAspect: (horizontal: Int, vertical: Int)?
            if let first = formats.first,
                let ratio = CMFormatDescriptionGetExtension(first, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) as? [String: Int],
                let horizontal = ratio[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String],
                let vertical = ratio[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String], horizontal > 0, vertical > 0, horizontal != vertical,
                (0.1...10).contains(Double(horizontal) / Double(vertical))  // a broken tag is not carried over (the player ignores it too)
            {
                pixelAspect = (horizontal, vertical)
            }
            return Probe(
                asset: asset, video: video, audio: audio, audioFormat: audioFormat, frameDuration: frameDuration, start: range.start, duration: range.duration,
                hasAlpha: alpha,
                turn: turn, upright: composition, pixelAspect: pixelAspect,
                codec: formats.first.map(CMFormatDescriptionGetMediaSubType) ?? 0)
        }
    }
}
