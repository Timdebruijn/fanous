// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

extension Error {
    /// The text a client may see (B25). Interpolating a Foundation or AVFoundation error prints its `UserInfo`, which
    /// carries the file's `NSURL` (measured: `loadTracks` on a missing file gives `NSURL=file:///Users/…`), and `live.layers[].error`,
    /// the readiness `decoders` detail and `/api/library` `reason` reach the monitor role, which gets no paths. The engine's own
    /// errors (`MovieError`, …) describe themselves without paths and keep their text; every other error gives its
    /// `localizedDescription`.
    var clientText: String {
        (self as NSError).domain.hasPrefix("FanousEngine.") || (self as NSError).domain.hasPrefix("FanousCore.") ? "\(self)" : localizedDescription
    }
}
