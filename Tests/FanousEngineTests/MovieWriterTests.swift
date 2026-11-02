// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import Foundation
import Testing

@testable import FanousEngine

struct MovieWriterTests {
    /// B21: the ProRes the ingest writes is Rec.709, whatever the source was tagged. The transcoder's BGRA frames carry the
    /// source's YCbCr matrix as an attachment (AVAssetReader copies it), and without colour properties the writer took that
    /// tag and matrix for the file, so a Rec.601 source became a 601-coded file that the layer shader (one 709 matrix) read
    /// with 15–40 codes of error on saturated colours (measured 2026-11-02).
    @Test func proResIsWrittenAsRec709WhateverTheSourceTag() async throws {
        let url = try tempDir("fanous-writer").appending(path: "601.mov")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await offPool {
            let writer = try MovieWriter(url: url, width: 320, height: 176, fps: 25, codec: .proRes422)
            let buffer = try writer.makePixelBuffer()
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_SMPTE_C, .shouldPropagate)
            for _ in 0..<3 { try writer.append(buffer) }
            try writer.finish()
        }
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let description = try #require(try await track.load(.formatDescriptions).first)
        let matrix = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String
        #expect(matrix == kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String, "the file's matrix: \(matrix ?? "none")")
    }
}
