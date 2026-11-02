// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import Foundation
import Testing

@testable import FanousEngine

struct ClientErrorTextTests {
    /// B25: a Foundation/AVFoundation error's client text carries no file URL; the engine's own errors keep their text.
    @Test func foreignErrorsLoseTheirPathAndOwnErrorsKeepTheirText() async {
        let url = URL(fileURLWithPath: "/Users/someone/Movies/Fanous Library/001_Missing/missing_clip.mov")
        do {
            _ = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
            Issue.record("a missing file should not load")
        } catch {
            #expect("\(error)".contains("missing_clip.mov"), "the interpolated error carries the path, the premise of clientText")
            #expect(!error.clientText.contains("missing_clip") && !error.clientText.contains("file://"))
            #expect(!error.clientText.isEmpty)
        }
        #expect(MovieError.decoder(-12910).clientText == "\(MovieError.decoder(-12910))")
    }
}
