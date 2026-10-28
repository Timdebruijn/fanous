// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

/// Enumerated parameter values. Raw values are the band order in the channel map.

public enum PlayMode: Int, CaseIterable, Codable, Sendable {
    case loopForward, loopReverse, onceHold, onceHoldReverse, onceBlack, onceBlackReverse, bounce, freeze, timecode, scrub
}

public enum FitMode: Int, CaseIterable, Codable, Sendable { case fit, fill, stretch, native }

public enum BlendMode: Int, CaseIterable, Codable, Sendable {
    case normal, add, screen, multiply, subtract, difference, lighten, darken
}

public enum Effect: Int, CaseIterable, Codable, Sendable {
    case none, blur, pixelate, mirror, kaleidoscope, invert, strobe, lumaKey, chromaKey, edge, threshold, tint
}

public enum LayerControl: Int, CaseIterable, Codable, Sendable { case idle, retrigger, resyncAudio, clearError }

/// Layer channel 51 (DESIGN.md §23.1). Band values: 0 off, 1–8 master group 1–8, 9–16 slave group 1–8.
public enum LayerSync: Equatable, Sendable {
    case off, master(group: Int), slave(group: Int)

    public static let groups = 8

    public init(bandValue: Int) {
        switch bandValue {
        case 1...Self.groups: self = .master(group: bandValue)
        case Self.groups + 1...2 * Self.groups: self = .slave(group: bandValue - Self.groups)
        default: self = .off
        }
    }
}

public enum MasterControl: Int, CaseIterable, Codable, Sendable { case normal, freezeAll, blackout }

public enum OutputControl: Int, CaseIterable, Codable, Sendable { case normal, blackout, freeze }

public enum TestPattern: Int, CaseIterable, Codable, Sendable {
    case off, grid, colourBars, blendCheck, outputID, crosshair, greySteps, checkerboard
    /// Flat full-field signal levels for the seam check (DESIGN §9.9); Blend check is the 50 % field.
    case grey0, grey25, grey75, white
}

public enum BlendSwitch: Int, CaseIterable, Codable, Sendable { case on, raw }
