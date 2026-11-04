// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import Foundation
import Testing

@testable import FanousEngine

struct ClientErrorTextTests {
    /// B25: a Foundation/AVFoundation error's client text carries no file URL; the engine's own errors keep their text.
    @Test func foreignErrorsLoseTheirPathAndOwnErrorsKeepTheirText() {
        // built as AVFoundation reports a file it cannot open: the URL in the user info, which the interpolated text prints
        // (`NSURL=file:///Users/…`), and a description without it
        let url = URL(fileURLWithPath: "/Users/someone/Movies/Fanous Library/001_Missing/missing_clip.mov")
        let error: any Error = NSError(
            domain: AVFoundationErrorDomain, code: AVError.Code.fileFormatNotRecognized.rawValue,
            userInfo: [
                NSURLErrorKey: url, NSLocalizedDescriptionKey: "Cannot Open", NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -12847),
            ])
        #expect(error.clientText == "Cannot Open")
        #expect(MovieError.decoder(-12910).clientText == "\(MovieError.decoder(-12910))")
    }
}
