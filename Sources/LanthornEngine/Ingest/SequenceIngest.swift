// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// Phase 3 ingest stub (DESIGN.md §8.3): an image sequence becomes a movie the
/// engine plays natively. ProRes 4444 keeps alpha; HAP Q is the fast path for
/// opaque content. Phase 4 wraps this in the ingest queue with progress and
/// originals handling.
public enum SequenceIngest {
    public enum IngestError: Error, CustomStringConvertible {
        case noImages(URL)
        case unreadable(URL)
        case sizeMismatch(URL, Int, Int)

        public var description: String {
            switch self {
            case .noImages(let url): "no images in \(url.path)"
            case .unreadable(let url): "cannot read \(url.lastPathComponent)"
            case .sizeMismatch(let url, let w, let h): "\(url.lastPathComponent) is not \(w)×\(h) like the first frame"
            }
        }
    }

    /// Image files of `directory` in name order (the usual frame-number suffix sorts naturally).
    public static func frames(in directory: URL) throws -> [URL] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let images = names.filter { StillSource.extensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) && !$0.hasPrefix(".") }
        guard !images.isEmpty else { throw IngestError.noImages(directory) }
        return images.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { directory.appending(path: $0) }
    }

    /// Writes `frames` at `fps` to `output`. Returns the number of frames written.
    @discardableResult
    public static func convert(frames: [URL], to output: URL, fps: Int32, codec: MovieWriter.Codec, progress: ((Int, Int) -> Void)? = nil) throws -> Int {
        guard let first = frames.first, let probe = image(at: first) else { throw IngestError.noImages(output) }
        let width = probe.width, height = probe.height
        let writer = try MovieWriter(url: output, width: width, height: height, fps: fps, codec: codec)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw IngestError.unreadable(first) }
        for (index, url) in frames.enumerated() {
            try autoreleasepool {
                guard let image = index == 0 ? probe : image(at: url) else { throw IngestError.unreadable(url) }
                guard image.width == width, image.height == height else { throw IngestError.sizeMismatch(url, width, height) }
                var buffer: CVPixelBuffer?
                if let pool = writer.pixelBufferPool {
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                } else {
                    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
                }
                guard let buffer else { throw MovieWriter.WriterError.failed("pixel buffer") }
                CVPixelBufferLockBaseAddress(buffer, [])
                defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                guard let context = CGContext(
                    data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                else { throw IngestError.unreadable(url) }
                context.clear(CGRect(x: 0, y: 0, width: width, height: height))
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                try writer.append(buffer)
            }
            progress?(index + 1, frames.count)
        }
        try writer.finish()
        return frames.count
    }

    static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
}
