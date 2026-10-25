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

    /// bgra8Unorm takes Syphon's blit path; rgba8Unorm differs from the surface format and takes the draw path,
    /// which runs the runtime-compiled shaders.
    @Test(arguments: [MTLPixelFormat.bgra8Unorm, .rgba8Unorm])
    func publishedTextureArrivesUprightInAClient(format: MTLPixelFormat) throws {
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
        #expect(bytes == pattern)

        // The directory learns about servers through distributed notifications, which need the main run loop.
        #expect(Self.wait(seconds: 2) { input.servers.contains { $0.serverName == name } })

        input.disconnect()
        #expect(input.latestTexture == nil)
    }
}
