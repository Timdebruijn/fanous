// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

/// Preview stream sizes (DESIGN.md §11.3, B32): a subscriber asks for a width (`sub` `w`), the engine encodes one of
/// four size classes in the target's own aspect, one encoder per (target, class).
public enum PreviewSize {
    public static let classes = [320, 640, 960, 1280]
    /// Without a `w` (older clients, CITP's canvas streamer).
    public static let defaultClass = 640
    /// Encoders in total before a new size of a target falls back to a size that target already has.
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

    /// Even pixel size of class `width` in the aspect of a `shape` picture (a canvas, an output's region). A shape
    /// that would pass 2160 lines gets fewer columns instead.
    public static func size(class width: Int, shape: (width: Int, height: Int)) -> (width: Int, height: Int) {
        let sw = max(1, shape.width), sh = max(1, shape.height)
        let w = max(2, min(width, 2160 * sw / sh) & ~1)
        return (w, max(2, (w * sh / sw) & ~1))
    }
}
