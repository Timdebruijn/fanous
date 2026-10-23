// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import LanthornCore
import Logging
import QuartzCore

public struct ResolvedParameterInfo: Encodable, Sendable {
    public var key: String
    public var name: String
    public var raw: UInt16
    public var physical: Double
    public var label: String
    public var unit: String
    public var source: String
}

public struct UniverseInfo: Encodable, Sendable {
    public var id: String
    public var active: Bool
    public var packets: Int
    public var source: String
    public var ageSeconds: Double
}

public struct InternalValueInfo: Encodable, Sendable {
    public var key: String
    public var raw: UInt16
    public var source: String
}

public struct LiveSnapshot: Encodable, Sendable {
    public var universes: [UniverseInfo]
    public var fixtures: [String: [ResolvedParameterInfo]]
    public var policies: [String: String]
    /// Internal (cue/OSC/UI) values per fixture, including those the policy currently ignores.
    public var internalValues: [String: [InternalValueInfo]]
}

/// Owns the universe table and one resolver per patched fixture. Everything
/// runs on `queue` (the DMX queue of ADR-0002); `snapshot()` is the only
/// cross-thread read and copies.
/// ponytail: per-packet array allocations in `resolve`; Phase 2 replaces them
/// with preallocated buffers when the render snapshot exists.
public final class DMXStore: @unchecked Sendable {
    public let queue = DispatchQueue(label: "org.lanthorn.dmx", qos: .userInteractive)
    private let logger: Logger
    private var table = UniverseTable()
    private var patch: Patch
    private var resolvers: [FixtureRef: FixtureResolver] = [:]
    private var announced: Set<String> = []
    private var timer: DispatchSourceTimer?
    /// Render-side parameters, one write per resolved DMX packet (ADR-0002 hand-off).
    public let snapshots = TripleBuffer { ParameterSnapshotSlot(maxLayers: 32) }
    private var sequence: UInt64 = 0

    public init(patch: Patch, logger: Logger) {
        self.logger = logger
        self.patch = patch
        for entry in patch.entries { resolvers[entry.fixture] = FixtureResolver(mode: entry.fixture.mode) }
    }

    public var universes: [UniverseID] { patch.universes }

    public func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [self] in
            let now = Self.now
            table.expire(at: now)
            for entry in patch.entries where !table.status(for: entry.universe, at: now).active {
                resolvers[entry.fixture]?.markDMXLost()
            }
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() { timer?.cancel() }

    static var now: TimeInterval { CACurrentMediaTime() }

    // MARK: Called on `queue`

    func receive(artnet packet: ArtDmx, from source: String) {
        let now = Self.now
        guard let universe = table.apply(artnet: packet, from: source, at: now) else { return }
        announce("\(universe) from \(source)")
        resolve(universe: universe, at: now)
    }

    func receive(sacn packet: SACNData) {
        let now = Self.now
        guard let universe = table.apply(sacn: packet, at: now) else { return }
        announce("\(universe) from \(packet.sourceName) (priority \(packet.priority))")
        resolve(universe: universe, at: now)
    }

    func apply(_ command: OSCCommand) {
        let now = Self.now
        switch command {
        case .setParameter(let fixture, let parameter, let raw):
            resolvers[fixture]?.setInternal(parameter, raw: raw, source: .osc, at: now)
            publish(receivedAt: 0)
        case .setMedia(let layer, let folder, let file):
            resolvers[.layer(layer)]?.setInternal(.layer(.folder), raw: UInt16(clamping: folder), source: .osc, at: now)
            resolvers[.layer(layer)]?.setInternal(.layer(.file), raw: UInt16(clamping: file), source: .osc, at: now)
            publish(receivedAt: 0)
        default:
            logger.info("OSC command not wired yet", metadata: ["command": "\(command)"])
        }
    }

    private func announce(_ what: String) {
        guard !announced.contains(what) else { return }
        announced.insert(what)
        logger.info("DMX receiving", metadata: ["universe": "\(what)"])
    }

    private func resolve(universe: UniverseID, at time: TimeInterval) {
        guard let slots = table.slots(for: universe) else { return }
        for entry in patch.entries where entry.universe == universe {
            guard let raw = ChannelMap.rawValues(mode: entry.fixture.mode, slots: slots, address: entry.address) else { continue }
            resolvers[entry.fixture]?.updateDMX(raw, at: time)
        }
        publish(receivedAt: time)
    }

    /// ponytail: iterates the resolver dictionary per packet; a fixed layer array comes with projects (Phase 5).
    private func publish(receivedAt: TimeInterval) {
        sequence += 1
        let sequence = self.sequence
        snapshots.write { slot in
            slot.sequence = sequence
            slot.receivedAt = receivedAt
            if let master = resolvers[.master] { ParameterSnapshotSlot.from(master, into: slot) }
            for (fixture, resolver) in resolvers {
                if case .layer(let n) = fixture, n >= 1, n <= slot.layers.count { slot.layers[n - 1] = LayerParameters.from(resolver) }
                if case .output(let n) = fixture, n >= 1, n <= slot.outputs.count { slot.outputs[n - 1] = OutputParameters.from(resolver) }
            }
        }
    }

    // MARK: Cross-thread

    /// Replaces the patch (Phase 5 `patch.set`, undo, project load); resolvers of fixtures that stay keep their state.
    public func setPatch(_ patch: Patch) {
        queue.async { [self] in
            self.patch = patch
            var kept: [FixtureRef: FixtureResolver] = [:]
            for entry in patch.entries { kept[entry.fixture] = resolvers[entry.fixture] ?? FixtureResolver(mode: entry.fixture.mode) }
            resolvers = kept
            publish(receivedAt: 0)
        }
    }

    public var currentPatch: Patch { queue.sync { patch } }

    /// The merged 512 slots of a universe for the DMX monitor stream; nil until a packet arrived.
    public func slots(for universe: UniverseID) -> [UInt8]? { queue.sync { table.slots(for: universe) } }

    public func setPolicy(_ policy: SourcePolicy, for fixture: FixtureRef) {
        queue.async { [self] in resolvers[fixture]?.policy = policy }
    }

    public func snapshot() -> LiveSnapshot {
        queue.sync {
            let now = Self.now
            let ids = Set(table.knownUniverses + patch.universes).sorted()
            let universes = ids.map { id -> UniverseInfo in
                let status = table.status(for: id, at: now)
                return UniverseInfo(
                    id: id.description, active: status.active, packets: status.packets, source: status.source,
                    ageSeconds: status.lastSeen > 0 ? ((now - status.lastSeen) * 1000).rounded() / 1000 : -1)
            }
            var fixtures: [String: [ResolvedParameterInfo]] = [:]
            var policies: [String: String] = [:]
            var internalValues: [String: [InternalValueInfo]] = [:]
            for (fixture, resolver) in resolvers {
                let internals = resolver.internalValues()
                if !internals.isEmpty {
                    internalValues[fixture.description] = internals.map { InternalValueInfo(key: $0.parameter.key, raw: $0.raw, source: $0.source.rawValue) }
                }
                let specs = ChannelMap.specs(for: fixture.mode)
                fixtures[fixture.description] = zip(specs, resolver.resolvedAll()).map { spec, value in
                    ResolvedParameterInfo(
                        key: spec.oscKey, name: spec.name, raw: value.raw, physical: spec.physical(fromRaw: value.raw),
                        label: spec.label(forRaw: value.raw), unit: spec.unit, source: value.source.rawValue)
                }
                policies[fixture.description] = resolver.policy.rawValue
            }
            return LiveSnapshot(universes: universes, fixtures: fixtures, policies: policies, internalValues: internalValues)
        }
    }
}
