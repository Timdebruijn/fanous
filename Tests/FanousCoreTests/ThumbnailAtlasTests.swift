// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Testing

/// Live layer thumbnails (B29): cell sizes, the atlas grid and the `thumbs` frame header.
struct ThumbnailAtlasTests {
    @Test func cellsAre160WideInTheCanvasAspect() {
        #expect(ThumbnailAtlas.cellSize(canvas: (1920, 1080)) == (160, 90))
        #expect(ThumbnailAtlas.cellSize(canvas: (1024, 768)) == (160, 120))
        #expect(ThumbnailAtlas.cellSize(canvas: (1080, 1920)) == (160, 284), "portrait: even height")
        #expect(ThumbnailAtlas.cellSize(canvas: (10000, 10)) == (160, 2), "extreme strips are clamped")
        #expect(ThumbnailAtlas.cellSize(canvas: (10, 10000)) == (160, 480))
        #expect(ThumbnailAtlas.cellSize(canvas: (0, 0)) == (160, 160), "no division by zero")
    }

    @Test func atlasPassRateIsFourPerSecond() {
        #expect(ThumbnailAtlas.everyNth(fps: 60) == 15)
        #expect(ThumbnailAtlas.everyNth(fps: 30) == 8)
        #expect(ThumbnailAtlas.everyNth(fps: 25) == 6)
        #expect(ThumbnailAtlas.everyNth(fps: 2) == 1)
    }

    @Test func layerISitsInSlotIAndSlotsAreAsTallAsTheTallestCell() throws {
        let hd = (width: 1920, height: 1080), square = (width: 1000, height: 1000)
        #expect(ThumbnailAtlas.layout([nil, nil]) == nil, "nothing visible: no pass")
        #expect(ThumbnailAtlas.layout([]) == nil)
        let one = try #require(ThumbnailAtlas.layout([nil, hd]))
        #expect(one.width == 320 && one.height == 90)
        #expect(one.cells == [nil, ThumbnailAtlas.Cell(x: 160, y: 0, width: 160, height: 90)])
        // six layers: two rows of four slots; a square canvas makes every slot 160 tall, cells keep their own height
        let six = try #require(ThumbnailAtlas.layout([hd, nil, hd, hd, square, hd]))
        #expect(six.width == 640 && six.height == 320)
        #expect(six.cells[4] == ThumbnailAtlas.Cell(x: 0, y: 160, width: 160, height: 160))
        #expect(six.cells[5] == ThumbnailAtlas.Cell(x: 160, y: 160, width: 160, height: 90))
        #expect(six.cells[3] == ThumbnailAtlas.Cell(x: 480, y: 0, width: 160, height: 90))
        #expect(six.cells[1] == nil)
        let full = try #require(ThumbnailAtlas.layout(Array(repeating: hd, count: 32)))
        #expect(full.width == 640 && full.height == 720, "32 layers: 4 × 8 cells of 160×90")
    }

    @Test func frameHeaderIsLayerNumberWidthHeightBigEndian() {
        #expect(ThumbnailAtlas.frame(layer: 3, width: 160, height: 284, jpeg: [0xFF, 0xD8, 0xFF, 0xD9]) == [3, 0, 160, 1, 28, 0xFF, 0xD8, 0xFF, 0xD9])
        #expect(ThumbnailAtlas.frame(layer: 32, width: 0, height: 0, jpeg: []) == [32, 0, 0, 0, 0], "an empty layer: zero size, no JPEG")
    }
}
