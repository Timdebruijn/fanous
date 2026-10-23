// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AppKit
import Foundation
import LanthornEngine
import Metal
import UniformTypeIdentifiers

/// Cross-process Syphon check: lists servers, connects to one, counts frames
/// and optionally writes the last frame as PNG (Phase 3 acceptance: the
/// canvas is visible in another process).
enum SyphonProbe {
    static func run(app: String, server: String, seconds: Double, output: URL?) throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.noDevice }
        let input = SyphonInput(device: device)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let servers = input.servers
            print("servers: \(servers.map { "\($0.appName) / \($0.serverName)" })")
            do {
                try input.connect(appName: app, serverName: server)
            } catch {
                print("connect failed: \(error)")
                exit(1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                let frames = input.frames
                print("received \(frames) frames in \(seconds) s (\(String(format: "%.1f", Double(frames) / seconds)) fps)")
                if let texture = input.latestTexture {
                    print("last frame: \(texture.width)x\(texture.height) \(texture.pixelFormat.rawValue)")
                    if let output { write(texture, device: device, to: output) }
                }
                exit(frames > 0 ? 0 : 1)
            }
        }
        application.run()
    }

    static func write(_ texture: MTLTexture, device: MTLDevice, to url: URL) {
        let w = texture.width, h = texture.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        // Syphon textures are shared IOSurfaces: copy into a readable texture first
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: w, height: h, mipmapped: false)
        descriptor.storageMode = .shared
        guard let copy = device.makeTexture(descriptor: descriptor), let queue = device.makeCommandQueue(), let cb = queue.makeCommandBuffer(),
            let blit = cb.makeBlitCommandEncoder()
        else { return }
        blit.copy(from: texture, to: copy)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        copy.getBytes(&pixels, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        if texture.pixelFormat == .bgra8Unorm {
            for i in stride(from: 0, to: pixels.count, by: 4) { pixels.swapAt(i, i + 2) }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
            let image = CGImage(
                width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) { print("wrote \(url.path)") }
    }
}
