// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Testing

@testable import FanousCore

/// Phase 5 acceptance: the labels the UI shows (`/api/channel-map.json`) are byte for byte the ones in
/// `docs/channel-map.md`; both come from `ChannelMap.specs`, and this pins that down.
struct ChannelMapJSONTests {
    @Test func jsonNamesEqualTheMarkdownTable() throws {
        let markdown = ChannelMapDocument.markdown()
        let json = ChannelMapDocument.json()
        for mode in FixtureMode.allCases {
            let section = try #require(markdown.components(separatedBy: "\n## ").first { $0.lowercased().hasPrefix("\(mode.rawValue) mode") })
            let rows = section.split(separator: "\n").filter { $0.hasPrefix("| ") && !$0.hasPrefix("| Ch ") }
            // the markdown adds one "Reserved" row for the unused channels; the JSON lists only real parameters
            let markdownNames = rows.map { String($0.split(separator: "|", omittingEmptySubsequences: false)[2]).trimmingCharacters(in: .whitespaces) }
                .filter { $0 != "Reserved" }
            let jsonNames = try #require(json["modes"]?[mode.rawValue]?.array).compactMap { $0["name"]?.string }
            #expect(markdownNames == jsonNames, "mode \(mode.rawValue): markdown \(markdownNames) json \(jsonNames)")
            #expect(json["footprints"]?[mode.rawValue]?.int == mode.footprint)
        }
        let layer = try #require(json["modes"]?["layer"]?.array)
        let playMode = try #require(layer.first { $0["name"]?.string == "Play mode" })
        #expect(playMode["channel"]?.int == 5)
        #expect(playMode["bands"]?.array?.first?["name"]?.string == "Loop fwd")
    }
}
