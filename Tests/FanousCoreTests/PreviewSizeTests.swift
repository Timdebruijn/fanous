// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Testing

@testable import FanousCore

/// B32: the size class for a wanted width, the fallback to an existing class and the pixel size in a target's shape.
struct PreviewSizeTests {
    @Test func theSmallestClassAtLeastTheWantedWidth() {
        let cases: [(Int?, Int)] = [(nil, 640), (-5, 320), (160, 320), (320, 320), (321, 640), (640, 640), (641, 960), (1279, 1280), (5000, 1280)]
        for (wanted, expected) in cases { #expect(PreviewSize.sizeClass(wanted: wanted) == expected, "\(String(describing: wanted))") }
    }

    @Test func theNearestExistingClassPrefersTheLargerOnATie() {
        #expect(PreviewSize.nearest(960, in: [640, 1280]) == 1280)
        #expect(PreviewSize.nearest(320, in: [640, 1280]) == 640)
        #expect(PreviewSize.nearest(1280, in: [320, 960]) == 960)
        #expect(PreviewSize.nearest(640, in: []) == nil)
    }

    @Test func theSizeFollowsTheShapeAndIsEven() {
        #expect(PreviewSize.size(class: 640, shape: (1920, 1080)) == (640, 360))
        #expect(PreviewSize.size(class: 1280, shape: (5760, 1080)) == (1280, 240), "wider than 16:9: the full class width")
        #expect(PreviewSize.size(class: 1280, shape: (1000, 333)) == (1280, 426), "odd height rounded down to even")
        #expect(PreviewSize.size(class: 640, shape: (1024, 768)) == (554, 414), "4:3: no more pixels than 640×360")
        #expect(PreviewSize.size(class: 320, shape: (1920, 1200)) == (302, 188), "16:10")
        #expect(PreviewSize.size(class: 1280, shape: (1080, 1920)) == (720, 1280), "portrait 1280 class: 720p's pixels")
        #expect(PreviewSize.size(class: 320, shape: (0, 0)) == (240, 240), "a degenerate shape is square")
    }

    @Test func extremeStripsStayWithinBounds() {
        #expect(PreviewSize.size(class: 1280, shape: (1, 4000)) == (14, 2160), "at most 2160 lines")
        #expect(PreviewSize.size(class: 1280, shape: (4000, 1)) == (1280, 2), "at least 2 lines")
        for c in PreviewSize.classes {
            for shape in [(1, 4000), (4000, 1), (1080, 1920), (1024, 768), (1920, 1080), (3, 2)] {
                let s = PreviewSize.size(class: c, shape: shape)
                #expect(s.width * s.height <= c * c * 9 / 16 && s.height <= 2160 && s.width % 2 == 0 && s.height % 2 == 0, "\(c) \(shape) → \(s)")
            }
        }
    }
}
