// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

// The output / mapping model of DESIGN.md §9.1, as stored in the project document. Coordinates of warp, slice
// and mask points are normalized to the output region (0,0 = top-left, 1,1 = bottom-right); overlaps and
// feathers are in output pixels. Everything here is plain data; the engine compiles it into textures.

public struct MapPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

/// A rectangle in normalized coordinates (slice source on the canvas).
public struct MapRect: Codable, Equatable, Sendable {
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

public struct BlendEdge: Codable, Equatable, Sendable {
    /// Overlap width in output pixels; 0 = no blend on this edge.
    public var overlap: Double = 0
    /// S-curve power (DESIGN.md §9.2).
    public var power: Double = 2
    /// Projector gamma the factor is pre-compensated for.
    public var gamma: Double = 2.2
    public init(overlap: Double = 0, power: Double = 2, gamma: Double = 2.2) {
        self.overlap = overlap
        self.power = power
        self.gamma = gamma
    }
}

public struct BlendSettings: Codable, Equatable, Sendable {
    public var left = BlendEdge()
    public var right = BlendEdge()
    public var top = BlendEdge()
    public var bottom = BlendEdge()
    /// Black lift outside the overlap zones, 0…1 of full scale.
    public var lift: Double = 0
    /// Feather of the lift transition at the zone boundary, output pixels.
    public var liftFeather: Double = 0
    public init() {}
    public var isIdentity: Bool { left.overlap <= 0 && right.overlap <= 0 && top.overlap <= 0 && bottom.overlap <= 0 && lift <= 0 }
}

public struct MeshWarp: Codable, Equatable, Sendable {
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

public struct WarpSettings: Codable, Equatable, Sendable {
    /// Four corners: top-left, top-right, bottom-right, bottom-left.
    public var cornerPin: [MapPoint] = [MapPoint(0, 0), MapPoint(1, 0), MapPoint(1, 1), MapPoint(0, 1)]
    /// Optional mesh on top of the corner pin (2×2 … 33×33).
    public var mesh: MeshWarp? = nil
    public init() {}
    public var isIdentity: Bool { cornerPin == WarpSettings().cornerPin && (mesh?.isIdentity ?? true) }
}

public struct MaskSettings: Codable, Equatable, Sendable {
    /// Polygon in normalized output coordinates (≥ 3 points); the inside is visible.
    public var path: [MapPoint]
    /// Soft edge width in output pixels.
    public var feather: Double = 0
    public init(path: [MapPoint], feather: Double = 0) {
        self.path = path
        self.feather = feather
    }
}

public struct SliceConfig: Codable, Equatable, Sendable {
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

    public init(id: Int, name: String? = nil) {
        self.id = id
        self.name = name ?? "Output \(id)"
        slices = [SliceConfig(id: 1)]
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
