// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

/// Live per-layer thumbnails (DESIGN.md §11.3, B29): every 250 ms each visible layer is drawn alone into its cell of one
/// atlas texture; one JPEG per layer is cut from its cell and sent on the `thumbs` stream (and to CITP consoles).
public enum ThumbnailAtlas {
    public static let cellWidth = 160
    /// Cells per atlas row; layer i sits in slot i (row i / columns), visible or not, so a slot never moves.
    public static let columns = 4
    public static let interval = 0.25

    public struct Cell: Equatable, Sendable {
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int
        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// Atlas passes every `n`-th compositor tick at `fps`: 4 per second (every 15th tick at 60 fps).
    public static func everyNth(fps: Double) -> Int { max(1, Int((fps * interval).rounded())) }

    /// Even cell size of a layer on a canvas of `canvas` pixels: 160 wide in the canvas aspect, 2…480 lines.
    public static func cellSize(canvas: (width: Int, height: Int)) -> (width: Int, height: Int) {
        let h = cellWidth * max(1, canvas.height) / max(1, canvas.width)
        return (cellWidth, min(480, max(2, h & ~1)))
    }

    /// Atlas size and cells for the layers' canvases (nil = the layer shows nothing and gets no cell). Slots are
    /// `cellWidth` × the tallest cell; nil when no layer shows anything (no pass at all).
    public static func layout(_ canvases: [(width: Int, height: Int)?]) -> (width: Int, height: Int, cells: [Cell?])? {
        let sizes = canvases.map { $0.map(cellSize) }
        guard let slot = sizes.compactMap({ $0?.height }).max() else { return nil }
        let cells = sizes.enumerated().map { i, size in
            size.map { Cell(x: (i % columns) * cellWidth, y: (i / columns) * slot, width: $0.width, height: $0.height) }
        }
        let rows = (canvases.count + columns - 1) / columns
        return (min(canvases.count, columns) * cellWidth, rows * slot, cells)
    }

    /// One `thumbs` frame (binary kind 2 payload after the stream header): `[u8 layer number, 1-based][u16 width][u16
    /// height][JPEG]`, big-endian like the stream header. Width and height 0 without JPEG bytes: the layer shows
    /// nothing (the UI falls back to the library thumbnail).
    public static func frame(layer: Int, width: Int, height: Int, jpeg: [UInt8]) -> [UInt8] {
        let w = UInt16(clamping: width), h = UInt16(clamping: height)
        return [UInt8(clamping: layer), UInt8(w >> 8), UInt8(w & 0xFF), UInt8(h >> 8), UInt8(h & 0xFF)] + jpeg
    }
}
