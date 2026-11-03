// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Accelerate
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
    public static func convert(frames: [URL], to output: URL, fps: Int32, codec: MovieWriter.Codec, progress: ((Int, Int) throws -> Void)? = nil) throws -> Int {
        guard let first = frames.first, let probe = image(at: first) else { throw IngestError.noImages(output) }
        let width = probe.width, height = probe.height
        // ProRes: 16 bits per channel, so a 16-bit TIFF/PNG render keeps its precision. RGBA little-endian (64RGBALE), not
        // the transcoder's 64ARGB: Core Graphics draws 16-bit RGB with the alpha last only. HAP is 8-bit.
        let deep: Bool = if case .hap = codec { false } else { true }
        let writer = try MovieWriter(
            url: output, width: width, height: height, fps: fps, codec: codec, pixelFormat: deep ? kCVPixelFormatType_64RGBALE : kCVPixelFormatType_32BGRA)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw IngestError.unreadable(first) }
        for (index, url) in frames.enumerated() {
            try autoreleasepool {
                guard let image = index == 0 ? probe : image(at: url) else { throw IngestError.unreadable(url) }
                guard image.width == width, image.height == height else { throw IngestError.sizeMismatch(url, width, height) }
                let buffer = try writer.makePixelBuffer()
                try draw(image, from: url, into: buffer, deep: deep, colorSpace: colorSpace)
                try writer.append(buffer)
            }
            try progress?(index + 1, frames.count)
        }
        try writer.finish()
        return frames.count
    }

    /// Draws `image` into `buffer` (16-bit RGBA little-endian when `deep`, else BGRA) with straight alpha, which ProRes 4444,
    /// HAP Alpha and the layer shader take: Core Graphics draws premultiplied only, so the pixels are un-premultiplied after
    /// (before, a pixel at half alpha was stored at half its colour and the shader darkened it once more).
    static func draw(_ image: CGImage, from url: URL, into buffer: CVPixelBuffer, deep: Bool, colorSpace: CGColorSpace) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: deep ? 16 : 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
            bitmapInfo: deep
                ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
                : CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw IngestError.unreadable(url) }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var pixels = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(buffer), height: vImagePixelCount(height), width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(buffer))
        let flags = vImage_Flags(kvImageNoFlags)
        // BGRA through the RGBA8888 function (the C header's BGRA one is a macro for it): only the alpha's place counts, last
        let error = deep ? vImageUnpremultiplyData_RGBA16U(&pixels, &pixels, flags) : vImageUnpremultiplyData_RGBA8888(&pixels, &pixels, flags)
        guard error == kvImageNoError else { throw IngestError.unreadable(url) }
    }

    static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
}
