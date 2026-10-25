// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

public enum FixtureRef: Hashable, Codable, Sendable, CustomStringConvertible {
    case layer(Int)  // 1-based
    case master
    case output(Int)  // 1-based

    public var mode: FixtureMode {
        switch self {
        case .layer: .layer
        case .master: .master
        case .output: .output
        }
    }

    public var description: String {
        switch self {
        case .layer(let n): "Layer \(n)"
        case .master: "Master"
        case .output(let n): "Output \(n)"
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

    /// 8 layers per Art-Net universe starting at 0.0.0, master and outputs on the universe after the layers.
    public static func standard(layers: Int = 16, outputs: Int = 4, transport: UniverseID.Transport = .artnet) -> Patch {
        func universe(_ index: Int) -> UniverseID { UniverseID(transport, transport == .artnet ? index : index + 1) }
        var entries: [PatchEntry] = []
        for layer in 1...max(1, layers) {
            entries.append(PatchEntry(fixture: .layer(layer), universe: universe((layer - 1) / 8), address: ((layer - 1) % 8) * 64 + 1))
        }
        let control = universe((max(1, layers) + 7) / 8)
        entries.append(PatchEntry(fixture: .master, universe: control, address: 1))
        for output in 1...max(1, outputs) {
            entries.append(PatchEntry(fixture: .output(output), universe: control, address: 9 + (output - 1) * 8))
        }
        return Patch(entries: entries)
    }
}
