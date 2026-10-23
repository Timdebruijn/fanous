// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import LanthornCore
import Logging
import Metal
import Synchronization
import UniformTypeIdentifiers

/// Thumbnails (DESIGN.md §8.4): one mid-file frame per movie, decoded by the
/// engine's own decoders and rendered through the layer pipeline into a
/// 320-px-wide canvas, then JPEG via ImageIO. Stills use ImageIO's thumbnail
/// path. Runs on the library thread, one at a time.
public final class Thumbnailer: @unchecked Sendable {
    public static let width = 320
    public let directory: URL
    private let context: MetalContext
    private let logger: Logger
    private var compositor: Compositor?
    private let parameters = TripleBuffer { ParameterSnapshotSlot(maxLayers: 1) }

    public init(context: MetalContext, directory: URL, logger: Logger) {
        self.context = context
        self.directory = directory
        self.logger = logger
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Writes `<sha256(path|mtime|size)>.jpg` and returns the file name; nil when the media cannot be decoded.
    public func make(for url: URL, metadata: MediaMetadata, kind: LibraryItem.Kind) -> String? {
        let name = Self.fileName(for: url)
        let output = directory.appending(path: name)
        if FileManager.default.fileExists(atPath: output.path) { return name }
        let ok: Bool
        switch kind {
        case .still, .sequence: ok = stillThumbnail(url, to: output)
        case .movie: ok = movieThumbnail(url, metadata: metadata, to: output)
        case .other: ok = false
        }
        return ok ? name : nil
    }

    public static func fileName(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = "\(url.path)|\(Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0))|\(values?.fileSize ?? 0)"
        return SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    private func stillThumbnail(_ url: URL, to output: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: Self.width, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { return false }
        return Self.writeJPEG(image, to: output)
    }

    private func movieThumbnail(_ url: URL, metadata: MediaMetadata, to output: URL) -> Bool {
        // the compositor handles every source kind (YCbCr planes, HAP Q, alpha) exactly as on stage
        let height = max(2, Int((Double(Self.width) * Double(max(1, metadata.height)) / Double(max(1, metadata.width))).rounded()) & ~1)
        do {
            let compositor = try Compositor(
                context: context, canvasWidth: Self.width, canvasHeight: height, fps: 60, maxLayers: 1, metrics: MetricsRing(capacity: 8),
                parameters: parameters, logger: logger)
            let source = try blocking { try await MovieSource.open(url: url, device: self.context.device, poolSize: 1) }
            let frame = DecodedFrame(poolIndex: 0)
            try source.decode(frame: source.info.frameCount / 2, into: frame)
            frame.frameIndex = 0
            let layer = RenderLayer(index: 0)
            layer.current = LayerPlayback(key: MediaKey(folder: 1, file: 1), still: frame)
            layer.wanted.store(MediaKey(folder: 1, file: 1).packed, ordering: .relaxed)
            compositor.setLayers([layer])
            parameters.write { slot in
                slot.sequence += 1
                slot.layers[0].intensity = 1
                slot.layers[0].folder = 1
                slot.layers[0].file = 1
            }
            compositor.tick(target: 1, drawable: nil)
            let (w, h, rgba) = compositor.readback()
            guard w > 0, let image = Self.image(rgba: rgba, width: w, height: h) else { return false }
            return Self.writeJPEG(image, to: output)
        } catch {
            logger.warning("thumbnail failed", metadata: ["file": "\(url.lastPathComponent)", "error": "\(error)"])
            return false
        }
    }

    static func image(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
    }

    static func writeJPEG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    private func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
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
