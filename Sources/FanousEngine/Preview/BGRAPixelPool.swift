// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreVideo
import Metal

/// BGRA pixel buffers on IOSurfaces, Metal-compatible, and their Metal views: what the preview and thumbnail streamers
/// render into on the compositor's command buffer and encode from afterwards (no readback).
enum BGRAPixelPool {
    static func make(width: Int, height: Int, minimumBufferCount: Int) -> CVPixelBufferPool? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: minimumBufferCount] as CFDictionary, attributes as CFDictionary, &pool) == kCVReturnSuccess
        else { return nil }
        return pool
    }

    static func textureCache(device: MTLDevice) -> CVMetalTextureCache? {
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess else { return nil }
        return cache
    }

    /// A buffer from `pool` and its `.bgra8Unorm` view of `width` × `height`; the view must outlive the GPU work on it.
    static func buffer(from pool: CVPixelBufferPool, cache: CVMetalTextureCache, width: Int, height: Int) -> (CVPixelBuffer, CVMetalTexture)? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        var texture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, width, height, 0, &texture) == kCVReturnSuccess, let texture
        else { return nil }
        return (buffer, texture)
    }
}
