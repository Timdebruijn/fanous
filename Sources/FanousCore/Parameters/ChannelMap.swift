// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

/// The single source of truth for the DMX personality (DESIGN.md §6, ADR-0008).
/// DMX decoding, GDTF export, OSC addresses, UI labels and docs/channel-map.md
/// are all derived from these tables.
public enum ChannelMap {
    public static let reservedLayerChannels = 51...64
    public static let reservedMasterChannels = 7...8
    public static let reservedOutputChannels = 6...8

    public static func specs(for mode: FixtureMode) -> [ParameterSpec] {
        switch mode {
        case .layer: layer
        case .master: master
        case .output: output
        }
    }

    /// Spec order position per parameter, built once (these lookups sit on the per-packet DMX path).
    private static let indexTable: [ParameterID: Int] = {
        var table: [ParameterID: Int] = [:]
        for mode in [FixtureMode.layer, .master, .output] {
            for (i, spec) in specs(for: mode).enumerated() { table[spec.id] = i }
        }
        return table
    }()

    public static func spec(_ id: ParameterID) -> ParameterSpec { specs(for: id.mode)[index(of: id)] }

    public static func index(of id: ParameterID) -> Int { indexTable[id]! }

    /// Raw values of a fixture at `address` (1-based) in a universe of 512 slots, in spec order.
    public static func rawValues(mode: FixtureMode, slots: [UInt8], address: Int) -> [UInt16]? {
        let base = address - 1
        guard base >= 0, base + mode.footprint <= slots.count else { return nil }
        return specs(for: mode).map { spec in
            let i = base + spec.channel - 1
            return spec.bits == 16 ? UInt16(slots[i]) << 8 | UInt16(slots[i + 1]) : UInt16(slots[i])
        }
    }

    public static func defaults(for mode: FixtureMode) -> [UInt16] { specs(for: mode).map(\.defaultRaw) }

    // MARK: - Kinds

    static func percent(_ max: Double = 100) -> ParameterKind { .curve([CurvePoint(0, 0), CurvePoint(255, max)], unit: "%") }
    static let percent16: ParameterKind = .curve([CurvePoint(0, 0), CurvePoint(65535, 100)], unit: "%")
    static let centred16: ParameterKind = .curve([CurvePoint(0, -100), CurvePoint(32768, 0), CurvePoint(65535, 100)], unit: "%")
    static let centred8: ParameterKind = .curve([CurvePoint(0, -100), CurvePoint(128, 0), CurvePoint(255, 100)], unit: "%")
    static let gain8: ParameterKind = .curve([CurvePoint(0, 0), CurvePoint(128, 100), CurvePoint(255, 200)], unit: "%")
    static let degrees16: ParameterKind = .curve([CurvePoint(0, -180), CurvePoint(32768, 0), CurvePoint(65535, 180)], unit: "°")
    static let speed16: ParameterKind = .curve(
        [CurvePoint(0, 0), CurvePoint(32767, 100), CurvePoint(32768, 100), CurvePoint(65535, 400)], unit: "%")
    static let scale16: ParameterKind = .curve(
        [CurvePoint(0, 0), CurvePoint(32767, 100), CurvePoint(32768, 100), CurvePoint(65535, 800)], unit: "%")

    static func bands(width: Int, _ names: [String], fallback: Int = 0) -> ParameterKind {
        let bands = names.enumerated().map { index, name in
            Band(from: UInt8(index * width), to: UInt8(min(255, (index + 1) * width - 1)), name: name, value: index)
        }
        return .bands(bands, fallback: fallback)
    }

    // MARK: - Layer (64 channels, 8 per universe)

    public static let layer: [ParameterSpec] = [
        l(.intensity, "Intensity", 1, 16, 0, percent16, "Intensity"),
        l(.folder, "Folder", 3, 8, 0, .index(max: 255), "Media"),
        l(.file, "File", 4, 8, 0, .index(max: 255), "Media"),
        l(.playMode, "Play mode", 5, 8, 0, bands(width: 16, [
            "Loop fwd", "Loop rev", "Once hold", "Once hold rev", "Once black", "Once black rev", "Bounce", "Freeze",
            "Timecode", "Scrub",
        ]), "Playback"),
        l(.speed, "Speed", 6, 16, 32768, speed16, "Playback"),
        l(.inPoint, "In point", 8, 16, 0, percent16, "Playback"),
        l(.outPoint, "Out point", 10, 16, 65535, percent16, "Playback"),
        l(.dissolve, "Dissolve", 12, 8, 0, .curve([CurvePoint(0, 0), CurvePoint(255, 25.5)], unit: "s"), "Playback"),
        l(.positionX, "Position X", 13, 16, 32768, centred16, "Geometry"),
        l(.positionY, "Position Y", 15, 16, 32768, centred16, "Geometry"),
        l(.positionZ, "Position Z", 17, 16, 32768, centred16, "Geometry"),
        l(.scaleX, "Scale X", 19, 16, 32768, scale16, "Geometry"),
        l(.scaleY, "Scale Y", 21, 16, 32768, scale16, "Geometry"),
        l(.fitMode, "Fit mode", 23, 8, 0, bands(width: 64, ["Fit", "Fill", "Stretch", "Native"]), "Geometry"),
        l(.rotationX, "Rotation X", 24, 16, 32768, degrees16, "Geometry"),
        l(.rotationY, "Rotation Y", 26, 16, 32768, degrees16, "Geometry"),
        l(.rotationZ, "Rotation Z", 28, 16, 32768, degrees16, "Geometry"),
        l(.red, "Red", 30, 8, 255, percent(), "Colour"),
        l(.green, "Green", 31, 8, 255, percent(), "Colour"),
        l(.blue, "Blue", 32, 8, 255, percent(), "Colour"),
        l(.brightness, "Brightness", 33, 8, 128, centred8, "Colour"),
        l(.contrast, "Contrast", 34, 8, 128, gain8, "Colour"),
        l(.saturation, "Saturation", 35, 8, 128, gain8, "Colour"),
        l(.hue, "Hue", 36, 8, 0, .curve([CurvePoint(0, 0), CurvePoint(255, 360)], unit: "°"), "Colour"),
        l(.blendMode, "Blend mode", 37, 8, 0, bands(width: 16, [
            "Normal", "Add", "Screen", "Multiply", "Subtract", "Difference", "Lighten", "Darken",
        ]), "Compositing"),
        l(.effect1, "Effect 1", 38, 8, 0, effectBands, "Effects"),
        l(.effect1A, "Effect 1 param A", 39, 8, 0, percent(), "Effects"),
        l(.effect1B, "Effect 1 param B", 40, 8, 0, percent(), "Effects"),
        l(.effect2, "Effect 2", 41, 8, 0, effectBands, "Effects"),
        l(.effect2A, "Effect 2 param A", 42, 8, 0, percent(), "Effects"),
        l(.effect2B, "Effect 2 param B", 43, 8, 0, percent(), "Effects"),
        l(.cropLeft, "Crop left", 44, 8, 0, percent(), "Crop"),
        l(.cropRight, "Crop right", 45, 8, 0, percent(), "Crop"),
        l(.cropTop, "Crop top", 46, 8, 0, percent(), "Crop"),
        l(.cropBottom, "Crop bottom", 47, 8, 0, percent(), "Crop"),
        l(.audioVolume, "Audio volume", 48, 8, 0, percent(), "Audio"),
        l(.audioPan, "Audio pan", 49, 8, 128, centred8, "Audio"),
        l(.control, "Control", 50, 8, 0, bands(width: 8, ["Idle", "Retrigger", "Resync audio", "Clear error"]), "Control"),
    ]

    static let effectBands = bands(width: 16, [
        "None", "Blur", "Pixelate", "Mirror", "Kaleidoscope", "Invert", "Strobe", "Luma key", "Chroma key", "Edge",
        "Threshold", "Tint",
    ])

    // MARK: - Master (8 channels)

    public static let master: [ParameterSpec] = [
        m(.intensity, "Master intensity", 1, 16, 65535, percent16, "Intensity"),
        m(.control, "Control", 3, 8, 0, bands(width: 64, ["Normal", "Freeze all", "Blackout"]), "Control"),
        m(.testPattern, "Test pattern", 4, 8, 0, testPatternBands, "Control"),
        m(.speed, "Master speed", 5, 16, 32768, speed16, "Playback"),
    ]

    static let testPatternBands = bands(width: 16, [
        "Off", "Grid", "Colour bars", "Blend check", "Output ID", "Crosshair", "Grey steps", "Checkerboard",
    ])

    // MARK: - Output (8 channels)

    public static let output: [ParameterSpec] = [
        o(.intensity, "Output intensity", 1, 16, 65535, percent16, "Intensity"),
        o(.control, "Control", 3, 8, 0, bands(width: 64, ["Normal", "Blackout", "Freeze"]), "Control"),
        o(.testPattern, "Test pattern", 4, 8, 0, testPatternBands, "Control"),
        o(.blend, "Blend", 5, 8, 0, .bands([Band(from: 0, to: 127, name: "On", value: 0), Band(from: 128, to: 255, name: "Raw", value: 1)], fallback: 0), "Mapping"),
    ]

    private static func l(_ p: LayerParameter, _ name: String, _ ch: Int, _ bits: Int, _ def: UInt16, _ kind: ParameterKind, _ group: String) -> ParameterSpec {
        ParameterSpec(id: .layer(p), name: name, channel: ch, bits: bits, defaultRaw: def, kind: kind, group: group)
    }
    private static func m(_ p: MasterParameter, _ name: String, _ ch: Int, _ bits: Int, _ def: UInt16, _ kind: ParameterKind, _ group: String) -> ParameterSpec {
        ParameterSpec(id: .master(p), name: name, channel: ch, bits: bits, defaultRaw: def, kind: kind, group: group)
    }
    private static func o(_ p: OutputParameter, _ name: String, _ ch: Int, _ bits: Int, _ def: UInt16, _ kind: ParameterKind, _ group: String) -> ParameterSpec {
        ParameterSpec(id: .output(p), name: name, channel: ch, bits: bits, defaultRaw: def, kind: kind, group: group)
    }
}
