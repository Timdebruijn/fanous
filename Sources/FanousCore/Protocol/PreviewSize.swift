// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

/// Preview stream sizes (DESIGN.md §11.3, B32): a subscriber asks for a width (`sub` `w`), the engine encodes one of
/// four size classes in the target's own aspect, one encoder per (target, class).
public enum PreviewSize {
    public static let classes = [320, 640, 960, 1280]
    /// Without a `w` (older clients, CITP's canvas streamer).
    public static let defaultClass = 640
    /// H.264 encoders in total, the canvas one counted, across targets (B70): past it a new (target, size) falls back to
    /// an encoding size of its target or its canvas, else gets JPEG (`PreviewHub`).
    public static let maxEncoders = 4

    /// The smallest class at least `wanted` wide, `wanted` clamped to 160–1280; 640 without a wish.
    public static func sizeClass(wanted: Int?) -> Int {
        guard let wanted else { return defaultClass }
        let w = min(1280, max(160, wanted))
        return classes.first { $0 >= w } ?? 1280
    }

    /// The class in `have` nearest to `wanted`, the larger one on a tie; nil when `have` is empty.
    public static func nearest(_ wanted: Int, in have: some Sequence<Int>) -> Int? {
        have.min { (abs($0 - wanted), -$0) < (abs($1 - wanted), -$1) }
    }

    /// Even pixel size of class `width` in the aspect of a `shape` picture (a canvas, an output's region), at most the
    /// pixels of the class's 16:9 frame: a shape narrower than 16:9 gets fewer columns, so cost and H.264 level stay
    /// bounded (1280 class: level 3.1). Extreme strips are clamped to 2160 lines and lose their aspect.
    public static func size(class width: Int, shape: (width: Int, height: Int)) -> (width: Int, height: Int) {
        let sw = max(1, shape.width), sh = max(1, shape.height)
        // w·h ≤ width²·9/16 with h = w·sh/sw  ⇔  w ≤ width·¾·√(sw/sh)
        let w = 16 * sh <= 9 * sw ? width : Int(Double(width) * 0.75 * (Double(sw) / Double(sh)).squareRoot())
        let even = max(2, w & ~1)
        return (even, min(2160, max(2, (even * sh / sw) & ~1)))
    }
}
