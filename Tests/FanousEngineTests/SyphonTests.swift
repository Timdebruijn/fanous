// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Metal
import Testing

@testable import FanousEngine

@Suite struct SyphonTests {
    static let size = 64

    /// B = x*4, G = y*4, R = 0x80, A = 0xFF: every row and column differs, so a flip in either axis shows.
    static func pattern() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                bytes[i] = UInt8(x * 4)
                bytes[i + 1] = UInt8(y * 4)
                bytes[i + 2] = 0x80
                bytes[i + 3] = 0xFF
            }
        }
        return bytes
    }

    /// Polls `condition` every 10 ms until it holds or `seconds` have passed.
    static func wait(seconds: Double, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    /// Syphon surfaces are in OpenGL order (row 0 at the bottom), so a published Metal texture arrives with its
    /// rows reversed and the compositor samples a Syphon input bottom-up; an OpenGL client such as the Syphon
    /// Simple Client then shows the canvas upright (checked by eye 2026-10-26). bgra8Unorm matches the surface
    /// format, rgba8Unorm takes the conversion path; both go through Syphon's flip draw.
    @Test(arguments: [MTLPixelFormat.bgra8Unorm, .rgba8Unorm])
    func publishedTextureArrivesBottomUpInASurfaceAndTheInputSaysSo(format: MTLPixelFormat) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }  // no GPU: skip
        let name = "FanousTest-\(UUID().uuidString)"
        let output = try SyphonOutput(name: name, device: device)
        let input = SyphonInput(device: device)
        defer {
            input.disconnect()
            output.stop()
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: Self.size, height: Self.size, mipmapped: false)
        descriptor.usage = [.shaderRead]
        let source = try #require(device.makeTexture(descriptor: descriptor))
        let pattern = Self.pattern()
        var sourceBytes = pattern
        if format == .rgba8Unorm {  // same colours, red and blue swapped in memory
            for i in stride(from: 0, to: sourceBytes.count, by: 4) { sourceBytes.swapAt(i, i + 2) }
        }
        source.replace(region: MTLRegionMake2D(0, 0, Self.size, Self.size), mipmapLevel: 0, withBytes: sourceBytes, bytesPerRow: Self.size * 4)

        try input.connect(description: output.serverDescription)

        // The client registers for frames asynchronously, so keep publishing until one arrives.
        let arrived = Self.wait(seconds: 3) {
            guard let commandBuffer = queue.makeCommandBuffer() else { return false }
            output.publish(texture: source, commandBuffer: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            return input.latestTexture != nil
        }
        #expect(arrived)
        #expect(output.hasClients)
        let received = try #require(input.latestTexture)
        #expect(received.width == Self.size && received.height == Self.size)
        #expect(input.frames > 0)

        var bytes = [UInt8](repeating: 0, count: pattern.count)
        received.getBytes(&bytes, bytesPerRow: Self.size * 4, from: MTLRegionMake2D(0, 0, Self.size, Self.size), mipmapLevel: 0)
        let row = Self.size * 4
        let reversed = (0..<Self.size).reversed().flatMap { y in pattern[(y * row)..<((y + 1) * row)] }
        #expect(bytes == reversed)
        #expect(bytes != pattern)
        #expect(input.bottomUp)

        // The directory learns about servers through distributed notifications, which need the main run loop.
        #expect(Self.wait(seconds: 2) { input.servers.contains { $0.serverName == name } })

        input.disconnect()
        #expect(input.latestTexture == nil)
    }
}
