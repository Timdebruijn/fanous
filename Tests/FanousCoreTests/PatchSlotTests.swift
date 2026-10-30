// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Testing

@testable import FanousCore

/// The slot rule of DESIGN.md §6.6 item 2, from `Tests/Fixtures/patch-slots.json`, which the web tests read too so the
/// Swift and TypeScript rules cannot drift. Plain JSON, universes in the protocol's "artnet:0.0.4" / "sacn:3" form:
/// - `slots`: `start {universe, address}`, `footprint` and fixture `numbers` → `expected`, one `{universe, address}` per
///   number, or null where there is no slot (past the last universe, a start that is not an address);
/// - `blocks`: `footprint` and the group's patched required fixtures `placed [{number, universe, address}]` → the block's
///   `start {universe, address}`, or null when the group is Custom or nothing is placed.
@Suite struct PatchSlotTests {
    struct Address: Decodable {
        let universe: String
        let address: Int
        var slot: Patch.Slot { Patch.Slot(UniverseID(parsing: universe)!, address) }
    }
    struct Placed: Decodable {
        let number: Int
        let universe: String
        let address: Int
    }
    struct Vectors: Decodable {
        struct SlotCase: Decodable {
            let name: String
            let start: Address
            let footprint: Int
            let numbers: [Int]
            let expected: [Address?]
        }
        struct BlockCase: Decodable {
            let name: String
            let footprint: Int
            let placed: [Placed]
            let start: Address?
        }
        let slots: [SlotCase]
        let blocks: [BlockCase]
    }

    static let vectors: Vectors = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/patch-slots.json")
        return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }()

    @Test func slotsMatchTheSharedVectors() {
        #expect(Self.vectors.slots.count >= 10)
        for c in Self.vectors.slots {
            #expect(c.numbers.count == c.expected.count, Comment(rawValue: c.name))
            for (number, expected) in zip(c.numbers, c.expected) {
                let slot = Patch.slot(of: number, from: c.start.slot, footprint: c.footprint)
                #expect(slot == expected?.slot, Comment(rawValue: "\(c.name): number \(number)"))
            }
        }
    }

    @Test func blocksMatchTheSharedVectors() {
        #expect(Self.vectors.blocks.count >= 8)
        for c in Self.vectors.blocks {
            let placed = Dictionary(uniqueKeysWithValues: c.placed.map { ($0.number, Patch.Slot(UniverseID(parsing: $0.universe)!, $0.address)) })
            #expect(Patch.blockStart(of: placed, footprint: c.footprint) == c.start?.slot, Comment(rawValue: c.name))
        }
    }

    /// The standard patch is the block from A 0.0.0 1, so a new layer's slot on a standard patch is today's address.
    @Test func theStandardPatchIsABlock() {
        let standard = Patch.standard(layers: 32, outputs: 0)
        let start = Patch.Slot(.artnet(net: 0, subnet: 0, universe: 0), 1)
        for n in 1...32 {
            let entry = standard.entry(for: .layer(n))!
            #expect(Patch.slot(of: n, from: start, footprint: 64) == Patch.Slot(entry.universe, entry.address))
        }
    }
}
