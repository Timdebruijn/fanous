// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import Logging
import QuartzCore
import simd

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
    /// Internal (cue/OSC/UI/MIDI) values per fixture, including those the policy currently ignores.
    public var internalValues: [String: [InternalValueInfo]]
    /// Seconds until the UI values of a fixture are released, for fixtures whose console is being received (B27).
    public var uiExpiresIn: [String: Double]
}

/// Owns the universe table and one resolver per fixture that exists, patched or not (DESIGN.md §6.6). Everything
/// runs on `queue` (the DMX queue of ADR-0002); `snapshot()` is the only
/// cross-thread read and copies.
/// ponytail: per-packet array allocations in `resolve`; Phase 2 replaces them
/// with preallocated buffers when the render snapshot exists.
public final class DMXStore: @unchecked Sendable {
    public let queue = DispatchQueue(label: "org.fanous.dmx", qos: .userInteractive)
    private let logger: Logger
    private var table = UniverseTable()
    private var patch: Patch
    private var resolvers: [FixtureRef: FixtureResolver] = [:]
    /// The project's source policy: on every fixture, and on the fixtures a later `setPatch` adds.
    private var policy = SourcePolicy.dmx
    /// The cue list's last output and when it came: a resolver made later (a layer added, an undo) takes it at once, as
    /// the cue engine pushes values only while a fade runs. Stamped with that time, as the resolvers that existed got
    /// it, so a console fed to the new resolver now wins under latest wins.
    private var cue: (outputs: [CueOutput], at: TimeInterval) = ([], 0)
    private var announced: Set<String> = []
    private var lastAnnounced: (universe: UniverseID, source: String, priority: UInt8?)?
    private var timer: DispatchSourceTimer?
    /// Render-side parameters, one write per resolved DMX packet (ADR-0002 hand-off): the compositor reads them,
    /// every other thread takes the copy (`withLatest`, B71).
    public let snapshots = TripleBuffer({ ParameterSnapshotSlot(maxLayers: ParameterSnapshotSlot.maxLayers) }, copy: { $0.copy(from: $1) })
    private var sequence: UInt64 = 0
    /// Per fixture with UI values: seconds they have masked the console since the last UI change, and the tick that was counted to.
    private(set) var uiClock: [FixtureRef: (masked: TimeInterval, tick: TimeInterval)] = [:]
    /// DESIGN.md §7.2: UI values that mask a live console are released after masking it this long since the last UI change.
    static let uiExpiry: TimeInterval = 600
    /// Per output: the Keystone fixture's resolved raw values (empty: the identity, nothing received or set), the matrix
    /// they gave or the last valid one, and whether the latest values were refused (DESIGN.md §9.10 item 2). Recomputed
    /// only when the values change.
    private var keystones = [(raw: [UInt16], matrix: simd_float3x3, invalid: Bool)](
        repeating: ([], matrix_identity_float3x3, false), count: ParameterSnapshotSlot.maxOutputs)
    /// Per output, Compare's lease (`output.show`, DESIGN.md §9.10 items 3 and 4): the preset it shows over ch 6 and
    /// the host time it ends; preset 0 = none. One per output, the latest call wins; the tick lets it expire.
    private var shows = [(preset: UInt8, until: TimeInterval)](repeating: (0, 0), count: ParameterSnapshotSlot.maxOutputs)
    /// A lease runs this long after its last renewal (the UI renews every 2 s); it ends at the first tick after.
    static let showLease: TimeInterval = 5
    /// Per output, the preset it shows and whether Compare asks for it (as last published), and the morph into it
    /// (Output ch 7, DESIGN.md §9.10 item 3): `publish` records one when either changes.
    private var shown = [(preset: UInt8, compare: Bool)](repeating: (0, false), count: ParameterSnapshotSlot.maxOutputs)
    private var morphs = [PresetMorph](repeating: PresetMorph(), count: ParameterSnapshotSlot.maxOutputs)

    /// `fixtures`: the fixtures that exist (`ProjectDocument.fixtures`); nil, the patched ones.
    public init(patch: Patch, fixtures: Set<FixtureRef>? = nil, logger: Logger) {
        self.logger = logger
        self.patch = patch
        for fixture in fixtures ?? Set(patch.entries.map(\.fixture)) { resolvers[fixture] = FixtureResolver(mode: fixture.mode) }
    }

    /// The IPv4 interfaces a universe's `interface` setting is matched against; injectable for tests.
    nonisolated(unsafe) var interfaceList: @Sendable () -> [NetworkInterface] = { SystemInfo.ipv4Interfaces }

    /// Art-Net port-addresses the patch listens on (ArtPollReply): own universes and the pairs of sACN ones (B28).
    public var universes: [UniverseID] {
        Set(UniverseSettings.wire(patch.universes, over: .artnet, settings: table.settings).values.joined()).sorted().map { UniverseID(.artnet, $0) }
    }

    public func start() {
        timer = DispatchSource.repeating(every: 0.5, on: queue) { [self] in tick(at: Self.now) }
    }

    public func stop() { timer?.cancel() }

    static var now: TimeInterval { CACurrentMediaTime() }

    // MARK: Called on `queue`

    /// The 0.5 s housekeeping tick: signal loss (by each universe's hold-on-loss setting), interfaces, then the UI
    /// expiry clock.
    func tick(at now: TimeInterval) {
        table.expire(at: now)
        var expired = false
        for i in shows.indices where shows[i].preset != 0 && now >= shows[i].until { (shows[i], expired) = ((0, 0), true) }
        if applyLoss(at: now, settingsChanged: false) || expired { publish(receivedAt: 0, at: now) }
        if table.settings.values.contains(where: { $0.interface != UniverseSettings.anyInterface }) { refreshInterfaces() }
        expireUI(at: now)
    }

    func receive(artnet packet: ArtDmx, from source: String, at now: TimeInterval = DMXStore.now) {
        for universe in table.apply(artnet: packet, from: source, at: now) {
            announce(universe, source: source)
            resolve(universe: universe, at: now)
        }
    }

    func receive(sacn packet: SACNData, from sender: String = "", at now: TimeInterval = DMXStore.now) {
        for universe in table.apply(sacn: packet, from: sender, at: now) {
            announce(universe, source: packet.sourceName, priority: packet.priority)
            resolve(universe: universe, at: now)
        }
    }

    /// Per-universe settings (B28): routing, loss timeout and priority mode in the table, interface filters, and the
    /// internal fallback of the fixtures on universes that use it.
    func configure(_ settings: [UniverseID: UniverseSettings], at now: TimeInterval) {
        table.configure(settings, at: now)
        refreshInterfaces()
        applyLossModes()
        _ = applyLoss(at: now, settingsChanged: true)
        publish(receivedAt: 0, at: now)
    }

    /// Hold on loss for the fixtures of silent universes: on the transition (tick), and at once when the settings
    /// change while a universe that has been received is silent (switching to `zero` while lost). `zero` feeds a frame
    /// of zeros stamped now, so under LTP/HTP it wins over older UI or cue values. Returns whether anything changed.
    private func applyLoss(at now: TimeInterval, settingsChanged: Bool) -> Bool {
        var changed = false
        for entry in patch.entries {
            guard let resolver = resolvers[entry.fixture] else { continue }
            let status = table.status(for: entry.universe, at: now)
            guard !status.active, resolver.hasDMX || (settingsChanged && status.lastSeen > 0) else { continue }
            switch table.settings(for: entry.universe).holdOnLoss {
            case .hold: break
            case .zero:
                // zero for a geometry offset is no offset: a keystone universe that drops alone must not shift a lit picture
                let zeros = entry.fixture.mode == .keystone
                    ? ChannelMap.defaults(for: .keystone)
                    : ChannelMap.rawValues(mode: entry.fixture.mode, slots: [UInt8](repeating: 0, count: 512), address: entry.address)
                if let zeros, resolvers[entry.fixture]?.updateDMX(zeros, at: now) == true { changed = true }
            case .internal: changed = true
            }
            resolvers[entry.fixture]?.markDMXLost()
        }
        return changed
    }

    private func applyLossModes() {
        for entry in patch.entries { resolvers[entry.fixture]?.internalWithoutDMX = table.settings(for: entry.universe).holdOnLoss == .internal }
    }

    /// Interfaces come and go (USB adapters): re-matched on every tick while a universe names one.
    private func refreshInterfaces() {
        let named = table.settings.filter { $0.value.interface != UniverseSettings.anyInterface }
        let list = named.isEmpty ? [] : interfaceList()
        table.setFilters(named.compactMapValues { $0.subnets(in: list) })
    }

    /// Cue, show and timecode commands from OSC go to the engine (Phase 7); set on the DMX queue's behalf by the engine.
    nonisolated(unsafe) public var onCommand: (@Sendable (OSCCommand) -> Void)?

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
        case .retrigger(let layer):
            // Control 8–15 = Retrigger; the compositor latches the edge, so the value returns to idle right after
            resolvers[.layer(layer)]?.setInternal(.layer(.control), raw: 8, source: .osc, at: now)
            publish(receivedAt: 0)
            queue.asyncAfter(deadline: .now() + 0.1) { [self] in
                resolvers[.layer(layer)]?.setInternal(.layer(.control), raw: 0, source: .osc, at: Self.now)
                publish(receivedAt: 0)
            }
        default:
            if let onCommand { onCommand(command) } else { logger.info("OSC command not wired", metadata: ["command": "\(command)"]) }
        }
    }

    /// Hand-operated sources, which can be left holding a value: the UI and a MIDI controller (B27, B36).
    static func isController(_ source: ValueSource) -> Bool { source == .ui || source == .midi }

    /// UI (and MIDI) values mask the console when the fixture's universe has traffic and at least one parameter resolves
    /// to them: never under policy `dmx` (not shown), under `htp` only where that value is the higher one, under `ltp`
    /// until the desk moves that parameter again.
    private static func masksConsole(_ resolver: FixtureResolver) -> Bool {
        resolver.hasDMX && resolver.resolvedAll().contains { isController($0.source) }
    }

    /// Seconds left for a fixture whose UI values mask the console right now; nil otherwise (no countdown shown).
    private func uiExpiresIn(_ fixture: FixtureRef, at now: TimeInterval) -> TimeInterval? {
        guard let clock = uiClock[fixture], let resolver = resolvers[fixture], Self.masksConsole(resolver) else { return nil }
        return max(0, Self.uiExpiry - clock.masked - (now - clock.tick))
    }

    /// UI values expire only after masking a live console for 10 minutes since the last UI change. Time without console
    /// traffic (or with the console winning) pauses the clock, so testing before the desk is on site keeps the values
    /// until Release. ponytail: a tick interval counts whole when the fixture masks at its end (≤ 0.5 s error, and up
    /// to the 2.5 s loss timeout after a dropout).
    func expireUI(at now: TimeInterval) {
        var changed = false
        for (fixture, clock) in uiClock {
            // released, or every UI/MIDI value overwritten (OSC, cue): nothing left to expire
            guard let resolver = resolvers[fixture], resolver.internalValues().contains(where: { Self.isController($0.source) }) else {
                uiClock[fixture] = nil
                continue
            }
            let masked = clock.masked + (Self.masksConsole(resolver) ? now - clock.tick : 0)
            if masked >= Self.uiExpiry {
                resolvers[fixture]?.clearInternal(source: .ui)
                resolvers[fixture]?.clearInternal(source: .midi)
                uiClock[fixture] = nil
                changed = true
                logger.warning("UI and MIDI values released: they masked the console for 10 minutes", metadata: ["fixture": "\(fixture)"])
            } else {
                uiClock[fixture] = (masked, now)
            }
        }
        if changed { publish(receivedAt: 0, at: now) }
    }

    func applyUI(_ fixture: FixtureRef, _ parameter: ParameterID, raw: UInt16, at now: TimeInterval, source: ValueSource = .ui) {
        guard resolvers[fixture] != nil else { return }
        resolvers[fixture]?.setInternal(parameter, raw: raw, source: source, at: now)
        uiClock[fixture] = (0, now)
        publish(receivedAt: 0, at: now)
    }

    func keepUI(_ fixture: FixtureRef, at now: TimeInterval) {
        if uiClock[fixture] != nil { uiClock[fixture] = (0, now) }
    }

    /// Logs a universe/source pair once; the string is only built when the pair differs from the previous packet's.
    private func announce(_ universe: UniverseID, source: String, priority: UInt8? = nil) {
        if let last = lastAnnounced, last.universe == universe, last.source == source, last.priority == priority { return }
        lastAnnounced = (universe, source, priority)
        let what = priority.map { "\(universe) from \(source) (priority \($0))" } ?? "\(universe) from \(source)"
        guard announced.insert(what).inserted else { return }
        logger.info("DMX receiving", metadata: ["universe": "\(what)"])
    }

    private func resolve(universe: UniverseID, at time: TimeInterval) {
        guard let slots = table.slots(for: universe) else { return }
        var changed = false
        for entry in patch.entries where entry.universe == universe {
            guard let raw = ChannelMap.rawValues(mode: entry.fixture.mode, slots: slots, address: entry.address) else { continue }
            if resolvers[entry.fixture]?.updateDMX(raw, at: time) == true { changed = true }
        }
        // an identical refresh (most packets in a steady show) rebuilds nothing; the render side keeps the last snapshot
        if changed { publish(receivedAt: time, at: time) }
    }

    /// ponytail: iterates the resolver dictionary per packet; a fixed layer array comes with projects (Phase 5).
    /// `now` starts a preset morph.
    func publish(receivedAt: TimeInterval, at now: TimeInterval = DMXStore.now) {
        sequence += 1
        let sequence = self.sequence
        snapshots.write { slot in
            slot.sequence = sequence
            slot.receivedAt = receivedAt
            // a fixture without a resolver (Remove last layer, Remove output, beyond the layer count) is not held at its
            // last values: no source reaches it, so nothing could change them
            if let master = resolvers[.master] { ParameterSnapshotSlot.from(master, into: slot) } else { slot.resetMaster() }
            for i in slot.layers.indices where resolvers.index(forKey: .layer(i + 1)) == nil { slot.layers[i] = LayerParameters() }
            for i in slot.outputs.indices where resolvers.index(forKey: .output(i + 1)) == nil { slot.outputs[i] = OutputParameters() }
            for (fixture, resolver) in resolvers {
                if case .layer(let n) = fixture, n >= 1, n <= slot.layers.count { slot.layers[n - 1] = LayerParameters.from(resolver) }
                if case .output(let n) = fixture, n >= 1, n <= slot.outputs.count { slot.outputs[n - 1] = OutputParameters.from(resolver) }
            }
            for i in keystones.indices {
                // every output has a Keystone resolver; one with neither DMX nor an internal value is the identity, and
                // skipping it keeps a typical project's publish free of the two arrays per output
                var raw: [UInt16] = []
                if let keystone = resolvers[.keystone(i + 1)], keystone.dmxReceived || keystone.internalCount > 0 {
                    raw = keystone.resolvedAll().map(\.raw)
                }
                if raw != keystones[i].raw {
                    keystones[i].raw = raw
                    // a refused quad keeps the last valid matrix and says so
                    if let m = raw.isEmpty ? [1, 0, 0, 0, 1, 0, 0, 0, 1] : WarpMath.keystone(raw: raw) {
                        keystones[i].matrix = simd_float3x3(rowMajor: m)
                        keystones[i].invalid = false
                    } else {
                        keystones[i].invalid = true
                    }
                }
                (slot.keystones[i], slot.keystoneInvalid[i]) = (keystones[i].matrix, keystones[i].invalid)
                // Compare wins over ch 6 while its lease runs
                let output = resolvers[.output(i + 1)]
                let console = output.map { UInt8(clamping: Int($0.physical(.output(.preset)))) } ?? 0
                let next: (preset: UInt8, compare: Bool) = shows[i].preset != 0 ? (shows[i].preset, true) : (console, false)
                if next != shown[i] {
                    // a console change morphs over ch 7 as it is now, from the target of a running morph (which ends at
                    // once); Compare starting, ending or changing its preset cuts
                    let fade = next.compare || shown[i].compare ? 0 : output.map { $0.physical(.output(.fade)) } ?? 0
                    (morphs[i], shown[i]) = (PresetMorph(from: shown[i].preset, start: now, fade: fade), next)
                }
                (slot.presets[i], slot.presetCompare[i], slot.morphs[i]) = (next.preset, next.compare, morphs[i])
            }
        }
    }

    /// `output.show`: outputs (ids 1–8) show `preset` until `now` + `showLease`; preset 0 ends their lease.
    /// A renewal only moves the end: nothing to publish.
    func show(_ ids: [Int], preset: Int, at now: TimeInterval) {
        var changed = false
        for id in ids where id >= 1 && id <= shows.count {
            let next: (preset: UInt8, until: TimeInterval) = preset > 0 ? (UInt8(clamping: preset), now + Self.showLease) : (0, 0)
            if next.preset != shows[id - 1].preset { changed = true }
            shows[id - 1] = next
        }
        if changed { publish(receivedAt: 0, at: now) }
    }

    // MARK: Cross-thread

    /// Cue list output (DESIGN.md §15.2): every value the cue engine asserts, as the cue source.
    public func setCue(_ outputs: [CueOutput]) {
        queue.async { [self] in
            let now = Self.now
            cue = (outputs, now)
            // values the list no longer asserts (removed cue) are released
            for key in resolvers.keys { resolvers[key]?.clearInternal(source: .cue) }
            for output in outputs { resolvers[output.fixture]?.setInternal(output.parameter, raw: output.raw, source: .cue, at: now) }
            publish(receivedAt: 0)
        }
    }

    /// A value from the UI (`fixture.set`): the `ui` internal source.
    public func setUI(_ fixture: FixtureRef, _ parameter: ParameterID, raw: UInt16) {
        queue.async { [self] in applyUI(fixture, parameter, raw: raw, at: Self.now) }
    }

    /// A value from the MIDI map (B36): the `midi` internal source, a controller like the UI (same expiry, Keep, Release).
    public func setMIDI(_ fixture: FixtureRef, _ parameter: ParameterID, raw: UInt16) {
        queue.async { [self] in applyUI(fixture, parameter, raw: raw, at: Self.now, source: .midi) }
    }

    /// Drops MIDI values whose mapping went away or whose source disconnected.
    public func releaseMIDI(_ targets: [(FixtureRef, ParameterID)]) {
        guard !targets.isEmpty else { return }
        queue.async { [self] in
            for (fixture, parameter) in targets { resolvers[fixture]?.clearInternal(parameter, source: .midi) }
            publish(receivedAt: 0)
        }
    }

    /// The value a parameter shows now (MIDI pickup); nil when the fixture does not exist.
    public func resolvedRaw(_ fixture: FixtureRef, _ parameter: ParameterID) -> UInt16? {
        queue.sync { resolvers[fixture]?.resolved(parameter).raw }
    }

    /// Compare (`output.show`): `preset` on outputs `ids` for 5 s from now, or 0 to end it.
    public func show(_ ids: [Int], preset: Int) {
        queue.async { [self] in show(ids, preset: preset, at: Self.now) }
    }

    /// `fixture.keep`: restart the expiry clock of a fixture's UI values.
    public func keepUI(_ fixture: FixtureRef) {
        queue.async { [self] in keepUI(fixture, at: Self.now) }
    }

    /// `fixture.release`: drop UI and MIDI values of one fixture (nil = all).
    public func releaseUI(_ fixture: FixtureRef?) {
        queue.async { [self] in
            for key in resolvers.keys where fixture == nil || key == fixture {
                resolvers[key]?.clearInternal(source: .ui)
                resolvers[key]?.clearInternal(source: .midi)
                uiClock[key] = nil
            }
            publish(receivedAt: 0)
        }
    }

    /// Replaces the patch and the fixtures that exist (`patch.set`, `layers.setCount`, `output.add`, undo, project load;
    /// `fixtures` nil: the patched ones).
    public func setPatch(_ patch: Patch, fixtures: Set<FixtureRef>? = nil) {
        let fixtures = fixtures ?? Set(patch.entries.map(\.fixture))
        queue.async { [self] in applyPatch(patch, fixtures: fixtures, at: Self.now) }
    }

    /// Resolvers of fixtures that stay keep their state, but one that lost its patch entry or moved to another universe
    /// drops the console's values; a new one takes the policy and the cue's values. A new or changed entry on a universe
    /// that is being received takes that universe's values now, not at its next packet (a console that sends only
    /// changes may wait a second).
    func applyPatch(_ patch: Patch, fixtures: Set<FixtureRef>, at now: TimeInterval) {
        let previous = self.patch
        self.patch = patch
        var kept: [FixtureRef: FixtureResolver] = [:]
        for fixture in fixtures {
            let was = previous.entry(for: fixture), entry = patch.entry(for: fixture), isNew = resolvers[fixture] == nil
            var resolver = resolvers[fixture] ?? FixtureResolver(mode: fixture.mode, policy: policy)
            if isNew {
                for output in cue.outputs where output.fixture == fixture {
                    resolver.setInternal(output.parameter, raw: output.raw, source: .cue, at: cue.at)
                }
            } else if let was, was.universe != entry?.universe {
                resolver.clearDMX()
            }
            if let entry, entry != was || isNew, table.status(for: entry.universe, at: now).active,
                let slots = table.slots(for: entry.universe), let raw = ChannelMap.rawValues(mode: fixture.mode, slots: slots, address: entry.address)
            {
                resolver.updateDMX(raw, at: now)
            }
            kept[fixture] = resolver
        }
        resolvers = kept
        applyLossModes()
        publish(receivedAt: 0, at: now)
    }

    public var currentPatch: Patch { queue.sync { patch } }

    /// `universe.set`, undo, project load (B28).
    public func setUniverseSettings(_ settings: [UniverseID: UniverseSettings]) {
        queue.async { [self] in configure(settings, at: Self.now) }
    }

    /// Patched universes set to an interface this Mac does not have, as "A 0.0.1: en5" (readiness).
    public func missingInterfaces() -> [String] {
        queue.sync {
            let list = interfaceList()
            return patch.universes.compactMap { id in
                let s = table.settings(for: id)
                return s.subnets(in: list)?.isEmpty == true ? "\(id): \(s.interface)" : nil
            }
        }
    }

    /// Resolved raw values of every fixture, in channel-map order (OSC feedback, B36). Only copies on the DMX
    /// queue; the addresses are built by the caller on its own queue.
    public func resolvedRaw() -> [FixtureRef: [UInt16]] {
        queue.sync { resolvers.mapValues { $0.resolvedAll().map(\.raw) } }
    }

    /// The merged 512 slots of a universe for the DMX monitor stream; nil until a packet arrived.
    public func slots(for universe: UniverseID) -> [UInt8]? { queue.sync { table.slots(for: universe) } }

    public func setPolicy(_ policy: SourcePolicy, for fixture: FixtureRef) {
        queue.async { [self] in resolvers[fixture]?.policy = policy }
    }

    /// The project's source policy for every fixture, also those a later `setPatch` adds.
    public func setPolicy(_ policy: SourcePolicy) {
        queue.async { [self] in
            self.policy = policy
            for key in resolvers.keys { resolvers[key]?.policy = policy }
            publish(receivedAt: 0)  // the output follows at once, not at the next DMX change
        }
    }

    public func snapshot() -> LiveSnapshot { snapshot(at: Self.now) }

    func snapshot(at now: TimeInterval) -> LiveSnapshot {
        queue.sync {
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
            var uiExpiresIn: [String: Double] = [:]
            for fixture in uiClock.keys {
                if let left = self.uiExpiresIn(fixture, at: now) { uiExpiresIn[fixture.description] = left.rounded(.up) }
            }
            return LiveSnapshot(universes: universes, fixtures: fixtures, policies: policies, internalValues: internalValues, uiExpiresIn: uiExpiresIn)
        }
    }
}
