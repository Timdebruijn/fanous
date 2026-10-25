// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import CoreMedia
import Foundation
import Synchronization

public enum TranscodeError: Error, CustomStringConvertible {
    case noVideoTrack(URL)
    case rotatedSource
    case hapDimensions(Int, Int)
    case reader(String)
    case noFrames
    case cancelled

    public var description: String {
        switch self {
        case .noVideoTrack(let url): "\(url.lastPathComponent) has no video track"
        case .rotatedSource: "the source is rotated or flipped (preferredTransform); export it upright first"
        case .hapDimensions(let w, let h): "HAP needs a width and height that are multiples of 4, the source is \(w)×\(h)"
        case .reader(let message): "cannot read the source: \(message)"
        case .noFrames: "the source has no decodable video frames"
        case .cancelled: "cancelled"
        }
    }
}

/// What a running job checks between frames (DESIGN.md §8.3): cancel, yield to the compositor, and a hard pause (show lock).
final class IngestGate: @unchecked Sendable {
    private struct Hooks {
        var shouldYield: (@Sendable () -> Bool)?
        var isPaused: (@Sendable () -> Bool)?
    }
    private let cancelled = Atomic<Bool>(false)
    private let hooks = Mutex(Hooks())

    var shouldYield: (@Sendable () -> Bool)? {
        get { hooks.withLock { $0.shouldYield } }
        set { hooks.withLock { $0.shouldYield = newValue } }
    }
    var isPaused: (@Sendable () -> Bool)? {
        get { hooks.withLock { $0.isPaused } }
        set { hooks.withLock { $0.isPaused = newValue } }
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
        let (shouldYield, isPaused) = hooks.withLock { ($0.shouldYield, $0.isPaused) }
        while isPaused?() == true {
            Thread.sleep(forTimeInterval: 0.02)
            try throwIfCancelled()
        }
        if shouldYield?() == true {
            Thread.sleep(forTimeInterval: 0.02)
            try throwIfCancelled()
        }
    }
}

/// Converts one source movie (anything AVFoundation can read) to a `.mov` the engine plays (DESIGN.md §8.3): ProRes or
/// HAP video from BGRA frames, audio as 48 kHz stereo 16-bit LPCM. Runs on the calling thread; `cancel()` may be called
/// from any thread and a cancelled run removes its partial output.
public final class Transcoder: @unchecked Sendable {
    public struct Summary: Sendable {
        public let frames: Int
        /// The codec written: the requested one, promoted when the source carries alpha (see `effectiveCodec`).
        public let codec: MovieWriter.Codec
        public let hasAudio: Bool
    }

    public let source: URL
    public let destination: URL
    public let codec: MovieWriter.Codec
    let gate: IngestGate

    public init(source: URL, destination: URL, codec: MovieWriter.Codec) {
        self.source = source
        self.destination = destination
        self.codec = codec
        gate = IngestGate()
    }

    init(source: URL, destination: URL, codec: MovieWriter.Codec, gate: IngestGate) {
        self.source = source
        self.destination = destination
        self.codec = codec
        self.gate = gate
    }

    /// Checked between frames; when it returns true the next frame waits 20 ms (the engine sets this from compositor load).
    public var shouldYield: (@Sendable () -> Bool)? {
        get { gate.shouldYield }
        set { gate.shouldYield = newValue }
    }

    /// While this returns true the job holds between frames (show lock); `cancel()` still ends it.
    public var isPaused: (@Sendable () -> Bool)? {
        get { gate.isPaused }
        set { gate.isPaused = newValue }
    }

    public func cancel() { gate.cancel() }

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
    @discardableResult
    public func run(progress: ((_ framesDone: Int, _ framesTotal: Int) -> Void)? = nil) throws -> Summary {
        try gate.throwIfCancelled()
        let probe = try Self.blocking { [source] in try await Probe.load(source) }
        guard probe.upright else { throw TranscodeError.rotatedSource }
        let requested = Self.effectiveCodec(codec, sourceHasAlpha: probe.hasAlpha)

        let reader = try AVAssetReader(asset: probe.asset)
        let videoOutput = AVAssetReaderTrackOutput(
            track: probe.video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw TranscodeError.reader("cannot read the video track") }
        reader.add(videoOutput)
        var audioOutput = probe.audio.map { AVAssetReaderAudioMixOutput(audioTracks: [$0], audioSettings: Self.audioSettings) }
        if let output = audioOutput {
            if reader.canAdd(output) { reader.add(output) } else { audioOutput = nil }  // an undecodable audio track must not block the video
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
                            frameDuration: probe.frameDuration, codec: requested, externalAudio: audioOutput != nil)
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
            return Summary(frames: written, codec: requested, hasAudio: audioOutput != nil)
        } catch {
            reader.cancelReading()
            if let writer {
                writer.cancel()
                try? FileManager.default.removeItem(at: destination)
            }
            throw error
        }
    }

    /// 48 kHz stereo 16-bit interleaved LPCM: what `AudioTrackReader` reads without a compressed-audio decoder (ADR-0019).
    /// The mix output resamples and up/downmixes whatever the source has.
    /// ponytail: 16 bit; a 24-bit master loses its low bits (the writer's track format is 16-bit like the test tone).
    private static var audioSettings: [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        return [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: TestTone.sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ]
    }

    /// Track properties, loaded once (async API; the caller's thread is not a cooperative one, so blocking is fine,
    /// like `MediaLoader`).
    private struct Probe: @unchecked Sendable {  // AVAssetTrack is not Sendable in this SDK; the probe is handed over once and then used by one thread
        let asset: AVURLAsset
        let video: AVAssetTrack
        let audio: AVAssetTrack?
        let frameDuration: CMTime
        let duration: CMTime
        let hasAlpha: Bool
        let upright: Bool
        let codec: FourCharCode

        static func load(_ url: URL) async throws -> Probe {
            let asset = AVURLAsset(url: url)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw TranscodeError.noVideoTrack(url) }
            let audio = try await asset.loadTracks(withMediaType: .audio).first
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
            return Probe(
                asset: asset, video: video, audio: audio, frameDuration: frameDuration, duration: range.duration, hasAlpha: alpha,
                upright: transform.a == 1 && transform.b == 0 && transform.c == 0 && transform.d == 1,
                codec: formats.first.map(CMFormatDescriptionGetMediaSubType) ?? 0)
        }
    }

    private static func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let done = DispatchSemaphore(value: 0)
        let box = Mutex<Result<T, Error>?>(nil)
        Task.detached(priority: .utility) {
            let result: Result<T, Error>
            do { result = .success(try await body()) } catch { result = .failure(error) }
            box.withLock { $0 = result }
            done.signal()
        }
        done.wait()
        return try box.withLock { $0 }!.get()
    }
}
