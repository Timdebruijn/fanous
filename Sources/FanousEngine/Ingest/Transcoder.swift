// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
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
        if let composition = probe.upright {  // phone footage: the reader bakes the rotation/flip in, the output has the upright (swapped) size
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
                try gate.checkpoint()
                let finished = try autoreleasepool { () throws -> Bool in
                    guard let sample = videoOutput.copyNextSampleBuffer(), let pixels = CMSampleBufferGetImageBuffer(sample) else { return true }
                    if writer == nil {
                        // Size from the decoded buffer, not the track: anamorphic and cropped sources differ.
                        // ponytail: pixel aspect ratio is not carried over; an anamorphic source plays with square pixels.
                        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
                        if case .hap = requested, width % 4 != 0 || height % 4 != 0 { throw TranscodeError.hapDimensions(width, height) }
                        writer = try MovieWriter(
                            url: destination, width: width, height: height, fps: Int32((1 / probe.frameDuration.seconds).rounded()),
                            frameDuration: probe.frameDuration, codec: requested, externalAudio: audioFormat)
                    }
                    // ponytail: one output frame per source frame at the track's frame duration, so a variable-frame-rate
                    // source (screen recordings) drifts against its audio; resample by PTS (hold/drop) when that matters.
                    // ponytail: the source's first video frame is assumed at t = 0 and the audio is written at its source
                    // time (true after AVAssetReader applied the edit lists).
                    try pumpAudio(until: CMTime(value: Int64(written + 1) * probe.frameDuration.value, timescale: probe.frameDuration.timescale))
                    try writer!.append(pixels)  // ProRes: the reader's buffer goes straight to the adaptor; HAP: encoded from BGRA
                    written += 1
                    return false
                }
                if finished { break }
                progress?(written, max(written, expected))
            }
            if reader.status == .failed { throw TranscodeError.reader(reader.error?.localizedDescription ?? "unknown") }
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

    /// Track properties, loaded once (async API; the caller's thread is not a cooperative one, so blocking is fine,
    /// like `MediaLoader`).
    private struct Probe: @unchecked Sendable {  // AVAssetTrack is not Sendable in this SDK; the probe is handed over once and then used by one thread
        let asset: AVURLAsset
        let video: AVAssetTrack
        let audio: AVAssetTrack?
        let audioFormat: CMAudioFormatDescription?
        let frameDuration: CMTime
        let duration: CMTime
        let hasAlpha: Bool
        /// Non-nil when the track carries a rotation/flip (`preferredTransform`): applies it and sizes the render to match.
        let upright: AVVideoComposition?
        let codec: FourCharCode

        static func load(_ url: URL) async throws -> Probe {
            let asset = AVURLAsset(url: url)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw TranscodeError.noVideoTrack(url) }
            let audio = try await asset.loadTracks(withMediaType: .audio).first
            let audioFormat = try? await audio?.load(.formatDescriptions).first  // a track whose format will not load is skipped, like an undecodable one
            let (nominal, minimum, range, formats, transform) = try await video.load(
                .nominalFrameRate, .minFrameDuration, .timeRange, .formatDescriptions, .preferredTransform)
            // Constant-rate sources: the smallest frame duration is the frame duration. Fall back to the nominal rate.
            var frameDuration = minimum
            if !frameDuration.isNumeric || frameDuration.seconds <= 0 {
                guard nominal > 0 else { throw TranscodeError.reader("unknown frame rate") }
                frameDuration = CMTime(value: 1, timescale: CMTimeScale(nominal.rounded()))
            }
            let alpha = formats.contains { description in
                let flag = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel)
                let subtype = CMFormatDescriptionGetMediaSubType(description)
                return (flag as? Bool) == true || [makeFourCC("Hap5"), makeFourCC("HapM"), makeFourCC("HapA")].contains(subtype)
            }
            // ponytail: the composition renders over opaque black, so a rotated source with alpha keeps the alpha codec but loses the alpha channel.
            var composition: AVMutableVideoComposition?
            if transform.rotatesOrFlips {
                composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
                composition?.frameDuration = frameDuration  // match the identity path: same frame count and pacing
            }
            return Probe(
                asset: asset, video: video, audio: audio, audioFormat: audioFormat, frameDuration: frameDuration, duration: range.duration,
                hasAlpha: alpha,
                upright: composition,
                codec: formats.first.map(CMFormatDescriptionGetMediaSubType) ?? 0)
        }
    }
}
