// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import Foundation
import LanthornEngine
import Logging

enum MediaGenerator {
    struct Spec {
        let codec: MovieWriter.Codec
        let width: Int
        let height: Int
        let fps: Int32
        var name: String { "\(codec.name)_\(width)x\(height)p\(fps).mov" }
    }

    static let specs: [Spec] = [
        Spec(codec: .proRes422HQ, width: 1920, height: 1080, fps: 60),
        Spec(codec: .proRes422HQ, width: 3840, height: 2160, fps: 30),
        Spec(codec: .proRes422HQ, width: 3840, height: 2160, fps: 60),
        Spec(codec: .proRes4444, width: 1920, height: 1080, fps: 60),
        Spec(codec: .hap(.hapQ), width: 1920, height: 1080, fps: 60),
        Spec(codec: .hap(.hapQ), width: 3840, height: 2160, fps: 30),
        Spec(codec: .hap(.hapQ), width: 3840, height: 2160, fps: 60),
        Spec(codec: .hap(.hap), width: 1920, height: 1080, fps: 60),
    ]

    static func generate(into directory: URL, seconds: Double, only: String?, audio: Bool = false, logger: Logger) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for spec in specs where only == nil || spec.name.contains(only!) {
            let url = directory.appending(path: spec.name)
            let frames = Int(seconds * Double(spec.fps))
            let started = Date()
            let writer = try MovieWriter(url: url, width: spec.width, height: spec.height, fps: spec.fps, codec: spec.codec, audio: audio)
            var buffer: CVPixelBuffer?
            if let pool = writer.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            } else {
                CVPixelBufferCreate(nil, spec.width, spec.height, kCVPixelFormatType_32BGRA, nil, &buffer)
            }
            guard let buffer else { throw MovieWriter.WriterError.failed("pixel buffer") }
            for frame in 0..<frames {
                var scratch: CVPixelBuffer? = buffer
                if writer.pixelBufferPool != nil {  // the adaptor keeps buffers in flight; take a fresh one each time
                    scratch = nil
                    CVPixelBufferPoolCreatePixelBuffer(nil, writer.pixelBufferPool!, &scratch)
                }
                guard let pixelBuffer = scratch else { throw MovieWriter.WriterError.failed("pixel buffer") }
                CVPixelBufferLockBaseAddress(pixelBuffer, [])
                PatternFrames.fill(
                    bgra: CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self), width: spec.width,
                    height: spec.height, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), frame: frame)
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                try writer.append(pixelBuffer)
            }
            try writer.finish()
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            logger.info(
                "wrote \(spec.name)",
                metadata: ["frames": "\(frames)", "audio": "\(audio)", "MB": "\(size / 1_000_000)", "seconds": "\(Int(Date().timeIntervalSince(started)))"])
        }
    }
}
