// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

/// Timecode chase offsets in frames (DESIGN.md §15.1): one for the project, one per layer (1-based).
/// Immutable; the engine swaps a new instance into the compositor.
public final class TimecodeOffsets: Sendable {
    public let project: Double
    public let layers: [Int: Double]
    public init(project: Double, layers: [Int: Double]) {
        self.project = project
        self.layers = layers
    }
}
