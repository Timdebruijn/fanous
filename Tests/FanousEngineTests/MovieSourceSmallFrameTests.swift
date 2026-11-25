// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Metal
import Testing

@testable import FanousEngine

@Suite(.cleansTempFiles)
struct MovieSourceSmallFrameTests {
    /// B5: a 64×48 ProRes opens and decodes. The hardware decoder refuses that size at session creation (−12910 on an M1 Pro;
    /// 128×96, 160×64, 256×64 and 320×16 too, while 144×96 and 320×48 pass, so there is no size rule), the software decoder
    /// takes it; before the fallback the open threw `MovieError.decoder(-12910)`.
    @Test func tinyProResOpensAndDecodes() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let url = try tempDir("fanous-tiny").appending(path: "tiny.mov")
        try await writePatternMovie(to: url, size: (64, 48), fps: 25, frames: 3, codec: .proRes422)
        let source = try await MovieSource.open(url: url, device: device, poolSize: 2)
        #expect(source.info.width == 64 && source.info.height == 48 && source.info.frameCount == 3)
        let slot = DecodedFrame(poolIndex: 0)
        try source.decode(frame: 0, into: slot)
        #expect(slot.texture0 != nil)  // a decoded plane (v216 on the software decoder here)
    }
}
