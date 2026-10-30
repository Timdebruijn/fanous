// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

public enum FixtureRef: Hashable, Codable, Sendable, CustomStringConvertible {
    case layer(Int)  // 1-based
    case master
    case output(Int)  // 1-based
    /// The Keystone fixture of output n (DESIGN.md §6.4a), patched next to its Output fixture.
    case keystone(Int)  // 1-based

    public var mode: FixtureMode {
        switch self {
        case .layer: .layer
        case .master: .master
        case .output: .output
        case .keystone: .keystone
        }
    }

    public var description: String {
        switch self {
        case .layer(let n): "Layer \(n)"
        case .master: "Master"
        case .output(let n): "Output \(n)"
        case .keystone(let n): "Keystone \(n)"
        }
    }
}

public struct UniverseID: Hashable, Codable, Sendable, CustomStringConvertible, Comparable {
    public enum Transport: String, Codable, Sendable { case artnet, sacn }
    public let transport: Transport
    /// Art-Net: 15-bit port-address (0–32767). sACN: 1–63999.
    public let number: Int

    public init(_ transport: Transport, _ number: Int) {
        self.transport = transport
        self.number = number
    }

    public static func artnet(net: Int, subnet: Int, universe: Int) -> UniverseID {
        UniverseID(.artnet, (net & 0x7F) << 8 | (subnet & 0xF) << 4 | (universe & 0xF))
    }

    public var description: String {
        switch transport {
        case .artnet: "artnet:\(number >> 8).\(number >> 4 & 0xF).\(number & 0xF)"
        case .sacn: "sacn:\(number)"
        }
    }

    public static func < (a: UniverseID, b: UniverseID) -> Bool {
        a.transport.rawValue == b.transport.rawValue ? a.number < b.number : a.transport.rawValue < b.transport.rawValue
    }

    /// Parses the `description` form: "artnet:net.subnet.universe" or "sacn:n".
    public init?(parsing text: String) {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let transport = text[..<colon].lowercased()
        let rest = text[text.index(after: colon)...]
        switch transport {
        case "artnet":
            let parts = rest.split(separator: ".").map { Int($0) }
            guard parts.count == 3, let net = parts[0], let subnet = parts[1], let universe = parts[2],
                (0...127).contains(net), (0...15).contains(subnet), (0...15).contains(universe)
            else { return nil }
            self = .artnet(net: net, subnet: subnet, universe: universe)
        case "sacn":
            guard let n = Int(rest), (1...63999).contains(n) else { return nil }
            self = UniverseID(.sacn, n)
        default:
            return nil
        }
    }

    /// `n` universes on, where a block's slots go once they run past channel 512 (DESIGN.md §6.6 item 2): Art-Net
    /// port-address + n (A 0.0.15 + 1 = A 0.1.0), sACN universe + n; nil past the last one (32767, 63999).
    public func advanced(by n: Int) -> UniverseID? {
        let next = number + n
        return next <= (transport == .artnet ? 32767 : 63999) ? UniverseID(transport, next) : nil
    }
}

public struct PatchEntry: Hashable, Codable, Sendable {
    public let fixture: FixtureRef
    public let universe: UniverseID
    /// 1-based start address.
    public let address: Int

    public init(fixture: FixtureRef, universe: UniverseID, address: Int) {
        self.fixture = fixture
        self.universe = universe
        self.address = address
    }

    public var channels: ClosedRange<Int> { address...(address + fixture.mode.footprint - 1) }
    public var fitsInUniverse: Bool { address >= 1 && channels.upperBound <= 512 }
}

public struct Patch: Codable, Sendable, Equatable {
    public var entries: [PatchEntry]

    public init(entries: [PatchEntry] = []) { self.entries = entries }

    public func entry(for fixture: FixtureRef) -> PatchEntry? { entries.first { $0.fixture == fixture } }

    public var universes: [UniverseID] { Array(Set(entries.map(\.universe))).sorted() }

    /// Pairs of entries that share a universe and overlap in channels.
    public func collisions() -> [(PatchEntry, PatchEntry)] {
        var result: [(PatchEntry, PatchEntry)] = []
        for (i, a) in entries.enumerated() {
            for b in entries[(i + 1)...] where a.universe == b.universe && a.channels.overlaps(b.channels) {
                result.append((a, b))
            }
        }
        return result
    }

    /// 8 layers per Art-Net universe starting at 0.0.0, master and outputs on the universe after the layers. A project
    /// starts with `outputs: 0`: `output.add` patches each Output fixture next to the Master.
    public static func standard(layers: Int = 16, outputs: Int = 4, transport: UniverseID.Transport = .artnet) -> Patch {
        func universe(_ index: Int) -> UniverseID { UniverseID(transport, transport == .artnet ? index : index + 1) }
        var entries: [PatchEntry] = []
        for layer in 1...max(1, layers) {
            entries.append(PatchEntry(fixture: .layer(layer), universe: universe((layer - 1) / 8), address: ((layer - 1) % 8) * 64 + 1))
        }
        let control = universe((max(1, layers) + 7) / 8)
        entries.append(PatchEntry(fixture: .master, universe: control, address: 1))
        for output in 1...max(1, outputs) where output <= outputs {
            entries.append(PatchEntry(fixture: .output(output), universe: control, address: 9 + (output - 1) * 8))
        }
        return Patch(entries: entries)
    }

    /// A universe and an address: where a block starts, or where one of its fixtures sits.
    public struct Slot: Hashable, Sendable {
        public var universe: UniverseID
        public var address: Int
        public init(_ universe: UniverseID, _ address: Int) {
            self.universe = universe
            self.address = address
        }
    }

    /// Where fixture number `number` of a block from `start` sits (DESIGN.md §6.6 item 2): on slot `number − 1`, at
    /// `start + (number − 1) × footprint`. A slot that would run past channel 512 moves to address 1 of the next
    /// universe, and so does every slot after it. Nil for a start outside 1…512 or a slot past the last universe.
    public static func slot(of number: Int, from start: Slot, footprint: Int) -> Slot? {
        guard number >= 1, (1...512).contains(start.address), (1...512).contains(footprint) else { return nil }
        let index = number - 1
        let first = (513 - start.address) / footprint  // the slots that fit in the start universe
        if index < first { return Slot(start.universe, start.address + index * footprint) }
        let rest = index - first, perUniverse = 512 / footprint
        return start.universe.advanced(by: 1 + rest / perUniverse).map { Slot($0, 1 + rest % perUniverse * footprint) }
    }

    /// The start of a group's block (DESIGN.md §6.6 item 2), or nil when the group is Custom or nothing of it is
    /// patched. `placed`: the group's patched required fixtures by number. The anchor, the lowest number k, gives the
    /// start: its address − (k − 1) × footprint in its universe, never rolled back across a universe. Block when every
    /// placed fixture sits on its slot from there; a number that is not placed does not break it.
    public static func blockStart(of placed: [Int: Slot], footprint: Int) -> Slot? {
        guard let anchor = placed.min(by: { $0.key < $1.key }) else { return nil }
        let start = Slot(anchor.value.universe, anchor.value.address - (anchor.key - 1) * footprint)
        return placed.allSatisfy { slot(of: $0.key, from: start, footprint: footprint) == $0.value } ? start : nil
    }
}
