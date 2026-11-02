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
            // the interpolated text carried `NSURL=file:///Users/…` on macOS 26 (the premise; not asserted, the OS may format it otherwise)
            #expect(!error.clientText.contains("missing_clip") && !error.clientText.contains("file://") && !error.clientText.contains("/Users"))
            #expect(!error.clientText.isEmpty)
        }
        #expect(MovieError.decoder(-12910).clientText == "\(MovieError.decoder(-12910))")
    }
}
