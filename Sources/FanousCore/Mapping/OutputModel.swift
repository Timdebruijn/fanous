// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

// The output / mapping model of DESIGN.md §9.1, as stored in the project document. Coordinates of warp, slice
// and mask points are normalized to the output region (0,0 = top-left, 1,1 = bottom-right); overlaps and
// feathers are in output pixels. Everything here is plain data; the engine compiles it into textures.

public struct MapPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

/// A rectangle in normalized coordinates (slice source on the canvas).
public struct MapRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
    public static let full = MapRect(x: 0, y: 0, w: 1, h: 1)
}

/// A rectangle in display pixels (output region).
public struct PixelRect: Codable, Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var w: Int
    public var h: Int
    public init(x: Int, y: Int, w: Int, h: Int) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

public struct BlendEdge: Codable, Hashable, Sendable {
    /// Overlap width in output pixels; 0 = no blend on this edge.
    public var overlap: Double = 0
    /// S-curve power (DESIGN.md §9.2).
    public var power: Double = 2
    /// Projector gamma the factor is pre-compensated for.
    public var gamma: Double = 2.2
    /// Per-channel gamma (r, g, b; DESIGN.md §9.9, OPEN-14); nil = `gamma` for all three.
    public var gammaRGB: [Double]? = nil
    public init(overlap: Double = 0, power: Double = 2, gamma: Double = 2.2, gammaRGB: [Double]? = nil) {
        self.overlap = overlap
        self.power = power
        self.gamma = gamma
        self.gammaRGB = gammaRGB
    }
}

public struct BlendSettings: Codable, Hashable, Sendable {
    public var left = BlendEdge()
    public var right = BlendEdge()
    public var top = BlendEdge()
    public var bottom = BlendEdge()
    /// Black lift, 0…1 of full scale: outside the overlap zones, or by coverage with overlaps on both axes (§9.10).
    public var lift: Double = 0
    /// Feather of the lift transition at the zone boundary, output pixels.
    public var liftFeather: Double = 0
    public init() {}
    public var isIdentity: Bool { left.overlap <= 0 && right.overlap <= 0 && top.overlap <= 0 && bottom.overlap <= 0 && lift <= 0 }
}

public struct MeshWarp: Codable, Hashable, Sendable {
    public var cols: Int
    public var rows: Int
    /// `rows × cols` control points, row-major from the top-left, in normalized output coordinates.
    public var points: [MapPoint]
    public init(cols: Int, rows: Int, points: [MapPoint]) {
        self.cols = cols
        self.rows = rows
        self.points = points
    }
    /// An undistorted grid.
    public static func identity(cols: Int, rows: Int) -> MeshWarp {
        var points: [MapPoint] = []
        for r in 0..<rows {
            for c in 0..<cols { points.append(MapPoint(Double(c) / Double(max(1, cols - 1)), Double(r) / Double(max(1, rows - 1)))) }
        }
        return MeshWarp(cols: cols, rows: rows, points: points)
    }
    public var isIdentity: Bool { self == .identity(cols: cols, rows: rows) }
}

public struct WarpSettings: Codable, Hashable, Sendable {
    /// Four corners: top-left, top-right, bottom-right, bottom-left.
    public var cornerPin: [MapPoint] = [MapPoint(0, 0), MapPoint(1, 0), MapPoint(1, 1), MapPoint(0, 1)]
    /// Optional mesh on top of the corner pin (2×2 … 33×33).
    public var mesh: MeshWarp? = nil
    public init() {}
    public var isIdentity: Bool { cornerPin == WarpSettings().cornerPin && (mesh?.isIdentity ?? true) }
}

public struct MaskSettings: Codable, Hashable, Sendable {
    /// Polygon in normalized output coordinates (≥ 3 points); the inside is visible.
    public var path: [MapPoint]
    /// Soft edge width in output pixels.
    public var feather: Double = 0
    public init(path: [MapPoint], feather: Double = 0) {
        self.path = path
        self.feather = feather
    }
}

public struct SliceConfig: Codable, Hashable, Sendable {
    public var id: Int
    public var canvas: Int = 1
    /// Source rectangle on the canvas.
    public var source: MapRect = .full
    /// Destination quad on the output: top-left, top-right, bottom-right, bottom-left.
    public var dest: [MapPoint] = [MapPoint(0, 0), MapPoint(1, 0), MapPoint(1, 1), MapPoint(0, 1)]
    public var mask: MaskSettings? = nil
    public var opacity: Double = 1
    public init(id: Int) { self.id = id }
}

public struct DisplayIdentity: Codable, Equatable, Sendable {
    /// `CGDisplayCreateUUIDFromDisplayID`, stable across reboots and ports.
    public var uuid: String
    /// Human name (EDID / `NSScreen.localizedName`) for the UI when the display is absent.
    public var name: String
    public init(uuid: String, name: String) {
        self.uuid = uuid
        self.name = name
    }
}

public struct DisplayModeConfig: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var hz: Double
    public init(width: Int, height: Int, hz: Double) {
        self.width = width
        self.height = height
        self.hz = hz
    }
}

/// Per-output colour (DESIGN.md §9.9), tuned by eye per projector like the black floor.
public struct OutputColor: Codable, Equatable, Sendable {
    /// Gain per channel (r, g, b), 0…2, on the code value.
    public var gain: [Double] = [1, 1, 1]
    /// Black offset, 0…0.2: the code value it gives on black; the output pass adds it in linear light, like the lift.
    public var black: Double = 0
    public init(gain: [Double] = [1, 1, 1], black: Double = 0) {
        self.gain = gain
        self.black = black
    }
}

public struct OutputConfig: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var display: DisplayIdentity? = nil
    /// Region on the display in pixels; nil = the whole display.
    public var region: PixelRect? = nil
    public var mode: DisplayModeConfig? = nil
    /// 0…1, multiplied with the Output fixture's intensity.
    public var intensity: Double = 1
    public var blend = BlendSettings()
    public var warp = WarpSettings()
    public var slices: [SliceConfig]
    /// Test pattern from the UI (the Output/Master fixtures can override it).
    public var testPattern: Int = 0
    /// Projects saved before it existed read as the default (gain 1, black 0).
    public var color = OutputColor()
    /// Stored mapping presets, by number (DESIGN.md §9.10 item 3); Output ch 6 or Compare shows one.
    public var presets: [MappingPreset] = []

    public init(id: Int, name: String? = nil) {
        self.id = id
        self.name = name ?? "Output \(id)"
        slices = [SliceConfig(id: 1)]
    }

    private enum CodingKeys: String, CodingKey { case id, name, display, region, mode, intensity, blend, warp, slices, testPattern, color, presets }

    /// As synthesized, but `presets` only when there are any: a project without presets saves byte for byte as before.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(display, forKey: .display)
        try c.encodeIfPresent(region, forKey: .region)
        try c.encodeIfPresent(mode, forKey: .mode)
        try c.encode(intensity, forKey: .intensity)
        try c.encode(blend, forKey: .blend)
        try c.encode(warp, forKey: .warp)
        try c.encode(slices, forKey: .slices)
        try c.encode(testPattern, forKey: .testPattern)
        try c.encode(color, forKey: .color)
        if !presets.isEmpty { try c.encode(presets, forKey: .presets) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        display = try c.decodeIfPresent(DisplayIdentity.self, forKey: .display)
        region = try c.decodeIfPresent(PixelRect.self, forKey: .region)
        mode = try c.decodeIfPresent(DisplayModeConfig.self, forKey: .mode)
        intensity = try c.decode(Double.self, forKey: .intensity)
        blend = try c.decode(BlendSettings.self, forKey: .blend)
        warp = try c.decode(WarpSettings.self, forKey: .warp)
        slices = try c.decode([SliceConfig].self, forKey: .slices)
        testPattern = try c.decode(Int.self, forKey: .testPattern)
        color = try c.decodeIfPresent(OutputColor.self, forKey: .color) ?? OutputColor()
        presets = try c.decodeIfPresent([MappingPreset].self, forKey: .presets) ?? []
    }

    public func preset(_ number: Int) -> MappingPreset? { presets.first { $0.number == number } }

    /// Snapshots the edited mapping (warp and slices, masks included) as preset `number`, kept in number order. Replaces
    /// one with that number, keeping its name unless `name` is given; returns whether it replaced one.
    @discardableResult public mutating func storePreset(_ number: Int, name: String?) -> Bool {
        let old = presets.firstIndex { $0.number == number }
        let preset = MappingPreset(number: number, name: name ?? old.map { presets[$0].name } ?? "Preset \(number)", warp: warp, slices: slices)
        if let old {
            presets[old] = preset
        } else {
            presets.insert(preset, at: presets.firstIndex { $0.number > number } ?? presets.endIndex)
        }
        return old != nil
    }

    /// Copies preset `number` into the edited mapping; false when the output has none.
    public mutating func recallPreset(_ number: Int) -> Bool {
        guard let preset = preset(number) else { return false }
        (warp, slices) = (preset.warp, preset.slices)
        return true
    }
}

/// What Warp & Slices edits, stored under a number (DESIGN.md §9.10 item 3). Blend, black floor, colour, intensity,
/// region and display are the projector's tuning and stay live; a later wall change does not touch a stored preset.
public struct MappingPreset: Codable, Equatable, Sendable {
    public var number: Int
    public var name: String
    public var warp: WarpSettings
    public var slices: [SliceConfig]
    public init(number: Int, name: String, warp: WarpSettings, slices: [SliceConfig]) {
        self.number = number
        self.name = name
        self.warp = warp
        self.slices = slices
    }

    /// Output ch 6: 0 shows the edited mapping, so presets are 1…255.
    public static let numbers = 1...255
    public static let maxNameLength = 64

    /// Why a preset number is refused; nil when it is fine.
    public static func numberProblem(_ number: Int?) -> String? { number.map(numbers.contains) == true ? nil : "number must be 1–255" }

    /// Why a (trimmed) name is refused; nil when it is fine.
    public static func nameProblem(_ name: String) -> String? {
        if name.isEmpty { return "name must not be empty" }
        if name.count > maxNameLength { return "name must be at most \(maxNameLength) characters" }
        return nil
    }
}

public struct CanvasConfig: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var width: Int
    public var height: Int
    /// Output whose display drives the compositor clock; nil = the first bound output.
    public var clockMaster: Int? = nil
    /// Canvas rate (B31); projects saved before it existed read as 60.
    public var fps: Double = 60
    public init(id: Int, name: String, width: Int, height: Int, fps: Double = 60) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.fps = fps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        clockMaster = try c.decodeIfPresent(Int.self, forKey: .clockMaster)
        fps = try c.decodeIfPresent(Double.self, forKey: .fps) ?? 60
    }
}
