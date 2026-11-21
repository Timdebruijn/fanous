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
/// the buffer that takes it past 1.04 GB, counted as `CVPixelBufferGetDataSize`; that is the 122nd frame of 1080p, the
/// 31st of 4K or the 272nd of 720p), every ProRes decode in flight blocks for about 60 ms inside
/// `VTDecompressionSessionDecodeFrame`, once per process. A picture swapped in just then draws an older frame for a
/// few ticks (docs/benchmarks/README.md). This passes the mark where it costs least: one black ProRes frame is encoded
/// and decoded over and over through one session, every output buffer kept, until `target` bytes are held; then all of
/// it is let go. The process stays past the mark afterwards.
public enum DecoderWarmUp {
    public struct Report: Sendable, Equatable {
        /// Why it did not run, or that it stopped short of the target; nil when it reached it.
        public var skipped: String?
        /// Bytes of decoder output held at the end.
        public var heldBytes = 0
        /// The longest decode, and the bytes held when it began: on the Mac measured, the block and the mark. With 0
        /// bytes it is the session's first decode: no block.
        public var longestDecode = 0.0
        public var longestAtBytes = 0
        public var seconds = 0.0
    }

    /// What it holds before it lets go: half as much again as the mark measured.
    // ponytail: one mark measured on one Mac (1.04 GB with 32 GB of memory, macOS 27.2.1). If another Mac has it
    // higher this does not reach it and playback is as it was without the warm-up; the log line gives the longest
    // decode and where it came, which on a Mac with the mark is the block (about 60 ms) and elsewhere about 1 ms.
    static let target = 1_500_000_000
    /// Below this much memory it does not run: 1.5 GB held next to a show is too much of an 8 GB Mac.
    static let leastMemory: UInt64 = 16_000_000_000
    private static let started = Atomic<Bool>(false)
    public static var hasStarted: Bool { started.load(ordering: .relaxed) }

    /// Once per process, on a thread of its own: the library index calls it when a scan or a probe shows the first
    /// ProRes movie after the engine's start, and the loader when it opens one the library had not shown. Pictures may
    /// play then: those whose ring is full ride the block out, one swapped in while it runs can meet it (B392).
    public static func startOnce(logger: Logger) {
        guard !started.exchange(true, ordering: .relaxed) else { return }
        let thread = Thread { log(run(target: target), logger: logger) }
        thread.name = "org.fanous.decode.warmup"
        thread.qualityOfService = .userInitiated  // as the decode threads: it is half a second of work, and late is worse than busy
        thread.start()
    }

    /// The same on the calling thread, which waits for it: the engine at its start when the first scan shows ProRes,
    /// and `fanous-bench` before its service starts. Returns at once when the warm-up was started before.
    public static func runOnce(logger: Logger) {
        guard !started.exchange(true, ordering: .relaxed) else { return }
        log(run(target: target), logger: logger)
    }

    private static func log(_ report: Report, logger: Logger) {
        // the same fields whether it reached the target or stopped short: where the longest decode began is the mark
        var metadata: Logger.Metadata = [
            "ms": "\(Int(report.seconds * 1000))", "heldMB": "\(report.heldBytes / 1_000_000)",
            "longestDecodeMs": "\(Int(report.longestDecode * 1000))", "longestAtMB": "\(report.longestAtBytes / 1_000_000)",
        ]
        if let skipped = report.skipped { metadata["reason"] = "\(skipped)" }
        logger.info(report.skipped == nil ? "decoder warm-up" : report.heldBytes > 0 ? "decoder warm-up stopped short" : "decoder warm-up skipped", metadata: metadata)
    }

    /// Decodes and holds until `target` bytes are held.
    static func run(target: Int, memory: UInt64 = SystemInfo.physicalMemoryBytes, width: Int = 1920, height: Int = 1080) -> Report {
        var report = Report()
        guard target > 0 else { return report }
        guard memory >= leastMemory else {
            report.skipped = "\(memory / 1_000_000_000) GB of memory"
            return report
        }
        let start = ContinuousClock.now
        guard let sample = sample(width: width, height: height), let description = CMSampleBufferGetFormatDescription(sample) else {
            report.skipped = "no ProRes encoder"
            return report
        }
        let session: VTDecompressionSession
        do {
            session = try MovieSource.makeSession(description, codec: kCMVideoCodecType_AppleProRes422).0
        } catch {
            report.skipped = "no ProRes decoder: \(error)"
            return report
        }
        defer { VTDecompressionSessionInvalidate(session) }
        nonisolated(unsafe) var held: [CVPixelBuffer] = []
        let most = target / (width * height * 4) + 1  // the decoder's frame is 4:2:2 at 16 bits or more: the loop ends whatever a size reads as
        var status = noErr
        while report.heldBytes < target, held.count < most {
            let before = held.count
            let t0 = ContinuousClock.now
            nonisolated(unsafe) var decoded = noErr
            status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, buffer, _, _ in
                decoded = status
                if let buffer { held.append(buffer) }
            }
            if status == noErr { status = decoded }  // a failure the decoder reports through the handler
            guard status == noErr, held.count > before, let buffer = held.last else { break }
            let seconds = (ContinuousClock.now - t0) / .seconds(1)
            if seconds > report.longestDecode { (report.longestDecode, report.longestAtBytes) = (seconds, report.heldBytes) }
            report.heldBytes += CVPixelBufferGetDataSize(buffer)
        }
        report.seconds = (ContinuousClock.now - start) / .seconds(1)
        // short of the target the mark may not be passed, and it does not run again: the log must not read as done
        if report.heldBytes < target { report.skipped = "stopped at \(report.heldBytes / 1_000_000) MB of \(target / 1_000_000) (decode status \(status), \(held.count) frames)" }
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
