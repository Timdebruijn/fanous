// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreMedia
import CoreVideo
import Foundation
import Logging
import Synchronization
import VideoToolbox

/// B389: the first time a process holds about 1 GB of ProRes decoder output at once (measured on an M1 Pro with 32 GB:
/// 1.04 GB, which is 122 frames of 1080p, 31 of 4K or 272 of 720p), every ProRes decode in flight blocks for about
/// 60 ms inside `VTDecompressionSessionDecodeFrame`, once per process. Playing, that is a layer started at the wrong
/// moment drawing an older frame for a few ticks (docs/benchmarks/README.md). This pays it where no picture depends on
/// it: one ProRes frame is encoded and decoded over and over through one session, every output buffer kept, until a
/// decode blocks or `cap` bytes are held; then all of it is let go. The process stays past the mark afterwards.
public enum DecoderWarmUp {
    public struct Report: Sendable, Equatable {
        /// Bytes of decoder output held when it stopped.
        public var heldBytes = 0
        /// Bytes held when a decode blocked; nil when none did up to the cap.
        public var blockedAtBytes: Int?
        public var longestDecode = 0.0
        public var seconds = 0.0
    }

    /// A decode this long is the block: a frame of the warm-up takes about 1 ms and the block about 60.
    static let blocked = 0.040
    private static let started = Atomic<Bool>(false)

    /// As much as is held at most: an eighth of the memory, between 1.5 and 4 GB.
    // ponytail: one mark measured on one Mac (1.04 GB with 32 GB of memory); the cap guesses that it does not grow
    // faster than the memory. The log line says where a decode blocked, or that none did: read it on another Mac.
    static var cap: Int { Int(min(max(SystemInfo.physicalMemoryBytes / 8, 1_500_000_000), 4_000_000_000)) }

    /// Once per process, on a thread of its own; the loader calls it when it first opens a ProRes movie. That movie's
    /// ring is full, 8 frames ahead, well before the block comes (about 0.3 s later) and rides it out.
    public static func startOnce(logger: Logger) {
        guard !started.exchange(true, ordering: .relaxed) else { return }
        let thread = Thread {
            let report = run(cap: cap)
            logger.info(
                "decoder warm-up",
                metadata: [
                    "ms": "\(Int(report.seconds * 1000))", "heldMB": "\(report.heldBytes / 1_000_000)",
                    "blockedAtMB": "\(report.blockedAtBytes.map { "\($0 / 1_000_000)" } ?? "none")", "longestDecodeMs": "\(Int(report.longestDecode * 1000))",
                ])
        }
        thread.name = "org.fanous.decode.warmup"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Decodes and holds until a decode blocks or `cap` bytes are held; an empty report when the encoder or the
    /// decoder is not there.
    static func run(cap: Int, width: Int = 1920, height: Int = 1080) -> Report {
        var report = Report()
        let start = ContinuousClock.now
        guard let sample = sample(width: width, height: height), let description = CMSampleBufferGetFormatDescription(sample),
            let (session, _) = try? MovieSource.makeSession(description, codec: kCMVideoCodecType_AppleProRes422)
        else { return report }
        defer { VTDecompressionSessionInvalidate(session) }
        nonisolated(unsafe) var held: [CVPixelBuffer] = []
        while report.heldBytes < cap {
            let before = held.count
            let t0 = ContinuousClock.now
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { _, _, buffer, _, _ in
                if let buffer { held.append(buffer) }
            }
            guard status == noErr, held.count > before, let buffer = held.last else { break }
            let seconds = (ContinuousClock.now - t0) / .seconds(1)
            report.longestDecode = max(report.longestDecode, seconds)
            if seconds >= blocked, before > 0 {  // the first decode of a session is slow by itself
                report.blockedAtBytes = report.heldBytes
                report.heldBytes += CVPixelBufferGetDataSize(buffer)
                break
            }
            report.heldBytes += CVPixelBufferGetDataSize(buffer)
        }
        report.seconds = (ContinuousClock.now - start) / .seconds(1)
        return report
    }

    /// One encoded ProRes 422 frame (black), or nil when the encoder is not there.
    static func sample(width: Int, height: Int) -> CMSampleBuffer? {
        var session: VTCompressionSession?
        guard
            VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_AppleProRes422, encoderSpecification: nil,
                imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr,
            let session
        else { return nil }
        defer { VTCompressionSessionInvalidate(session) }
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, 0, CVPixelBufferGetDataSize(buffer)) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        nonisolated(unsafe) var encoded: CMSampleBuffer?
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: .zero, duration: .invalid, frameProperties: nil, infoFlagsOut: nil
        ) { status, _, sample in
            if status == noErr { encoded = sample }
        }
        guard status == noErr, VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) == noErr else { return nil }
        return encoded
    }
}
