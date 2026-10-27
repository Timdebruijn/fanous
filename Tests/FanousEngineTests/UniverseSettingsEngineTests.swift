// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import Logging
import Testing

@testable import FanousEngine

/// B28: `universe.set` in the project, and the receivers applying hold on loss, protocol and interface live. Packets go
/// to loopback on random high ports, never 6454/5568.
struct UniverseSettingsEngineTests {
    static let logger = Logger(label: "test")
    static let a0 = UniverseID(.artnet, 0)

    static func makeStore() -> StateStore {
        let auth = RoleAuth(settingsURL: nil, shellTokenURL: nil, iterations: 1000, logger: logger)
        let project = ProjectDocument.initial(patch: .standard(layers: 1, outputs: 1), layerCount: 1, libraryRoot: "/tmp/lib", policy: .dmx)
        let store = StateStore(project: project, logger: logger)
        ProjectDocument.registerCommands(on: store, auth: auth)
        return store
    }

    static func set(_ store: StateStore, _ path: String, _ value: JSONValue, id: String = "artnet:0.0.0", role: Role = .programmer) -> Result<CommandResult, CommandError> {
        store.execute("universe.set", args: ["id": .string(id), "path": .string(path), "value": value], role: role)
    }

    // MARK: project model and command

    @Test func defaultsChangeNothingAndResettingRemovesTheEntry() throws {
        let store = Self.makeStore()
        #expect(store.project["universes"] == nil)
        #expect(ProjectDocument.universeSettings(from: store.project).isEmpty)
        #expect(try Self.set(store, "/holdOnLoss", "hold").get().rev == 0)  // the default: nothing to store

        _ = try Self.set(store, "/holdOnLoss", "zero").get()
        let entry = try #require(store.project["universes"]?.array?.first)
        #expect(entry == ["id": "artnet:0.0.0", "protocol": "artnet", "interface": "any", "holdOnLoss": "zero", "lossTimeout": 2.5, "sacnPriorityMode": "highest", "pair": "sacn:1"])
        #expect(ProjectDocument.universeSettings(from: store.project)[Self.a0]?.holdOnLoss == .zero)

        _ = try Self.set(store, "/lossTimeout", 5).get()
        _ = try Self.set(store, "/protocol", "both", id: "sacn:3").get()
        #expect(store.project["universes"]?.array?.compactMap { $0["id"]?.string } == ["artnet:0.0.0", "sacn:3"])
        _ = try Self.set(store, "/holdOnLoss", "hold").get()
        _ = try Self.set(store, "/lossTimeout", 2.5).get()
        #expect(store.project["universes"]?.array?.compactMap { $0["id"]?.string } == ["sacn:3"])
        _ = try store.execute("undo", role: .programmer).get()
        #expect(ProjectDocument.universeSettings(from: store.project)[Self.a0]?.lossTimeout == 5)
    }

    @Test func validationAndRefusals() throws {
        let store = Self.makeStore()
        let bad: [(String, String, JSONValue)] = [
            ("artnet:0.0.0", "/protocol", "dmx"), ("artnet:0.0.0", "/holdOnLoss", "release"), ("artnet:0.0.0", "/sacnPriorityMode", "lowest"),
            ("artnet:0.0.0", "/interface", "eth 0"), ("artnet:0.0.0", "/interface", 3), ("artnet:0.0.0", "/lossTimeout", 0.1), ("artnet:0.0.0", "/lossTimeout", 0.5),
            ("artnet:0.0.0", "/lossTimeout", 61), ("artnet:0.0.0", "/lossTimeout", "2"), ("artnet:0.0.0", "/pair", "artnet:0.0.1"),
            ("artnet:0.0.0", "/pair", "sacn:0"), ("sacn:1", "/pair", "sacn:2"), ("artnet:0.0.0", "/name", "x"), ("artnet:0.0.0", "/id", "sacn:1"),
            ("artnet:0.0.0", "", "x"), ("sacn:64000", "/protocol", "sacn"), ("dmx:1", "/protocol", "sacn"),
        ]
        for (id, path, value) in bad {
            #expect(Self.set(store, path, value, id: id).failureCode == "invalidArgs", "\(id) \(path) \(value)")
        }
        #expect(store.project["universes"] == nil)
        // an interface that is not on this Mac is accepted (projects travel); readiness warns
        _ = try Self.set(store, "/interface", "en42").get()
        _ = try Self.set(store, "/interface", "10.1.2.3").get()
        _ = try Self.set(store, "/pair", "sacn:7").get()
        _ = try Self.set(store, "/pair", .null).get()
        #expect(ProjectDocument.universeSettings(from: store.project)[Self.a0]?.pair == UniverseID(.sacn, 1))
        #expect(Self.set(store, "/holdOnLoss", "zero", role: .operator).failureCode == "forbidden")
        _ = try store.execute("show.lock", role: .programmer).get()
        #expect(Self.set(store, "/holdOnLoss", "zero") == .failure(.showLocked))
    }

    @Test func invalidAndDuplicateEntriesAreReportedAndEditedAsTheEngineRunsThem() throws {
        let entries: JSONValue = [
            ["id": "artnet:0.0.0", "holdOnLoss": "nope"], ["id": "sacn:2", "lossTimeout": 10], ["holdOnLoss": "zero"],
            ["id": "sacn:2", "lossTimeout": 20], ["id": "SACN:2", "holdOnLoss": "zero"],
        ]
        let project: JSONValue = ["universes": entries]
        let (settings, issues) = ProjectDocument.universeEntries(from: project)
        #expect(settings.keys.sorted() == [UniverseID(.sacn, 2)])
        #expect(settings[UniverseID(.sacn, 2)]?.lossTimeout == 10 && settings[UniverseID(.sacn, 2)]?.holdOnLoss == .hold)  // the first entry
        #expect(issues == [
            "artnet:0.0.0: holdOnLoss must be hold, zero or internal; runs the defaults",
            "universes[2]: id must be artnet:net.subnet.universe or sacn:n; entry ignored",
            "sacn:2: duplicate entry ignored; the first one applies", "sacn:2: duplicate entry ignored; the first one applies",
        ])

        // universe.set starts from what the engine runs and leaves one entry per universe
        let store = Self.makeStore()
        var document = store.project
        try document.set(entries, at: "/universes")
        store.replaceProject(document)
        _ = try Self.set(store, "/protocol", "both", id: "sacn:2").get()
        _ = try Self.set(store, "/sacnPriorityMode", "htp").get()
        let list = try #require(store.project["universes"]?.array)
        #expect(list.filter { $0["id"]?.string?.lowercased() == "sacn:2" }.count == 1)
        #expect(ProjectDocument.universeSettings(from: store.project)[UniverseID(.sacn, 2)] == {
            var s = UniverseSettings(for: UniverseID(.sacn, 2))
            s.lossTimeout = 10
            s.protocols = .both
            return s
        }())
        let a0 = try #require(list.first { $0["id"]?.string == "artnet:0.0.0" })
        #expect(a0["holdOnLoss"]?.string == "hold" && a0["sacnPriorityMode"]?.string == "htp")  // the invalid field is gone
        let left = ProjectDocument.universeEntries(from: store.project).issues
        #expect(left.count == 1 && left.first?.hasSuffix("id must be artnet:net.subnet.universe or sacn:n; entry ignored") == true)  // not ours to delete
    }

    // MARK: receivers

    struct PortInUse: Error, CustomStringConvertible {
        var port: UInt16
        var description: String { "UDP port \(port) is in use (another engine or test?); refusing to share it" }
    }

    /// A random high UDP port, checked by binding it exclusively (no SO_REUSEADDR/SO_REUSEPORT) and releasing it.
    /// Network.framework listeners share ports, so a port another process holds would cross-talk silently: fail instead.
    static func freePort() throws -> UInt16 {
        let port = UInt16.random(in: 40_000..<60_000)
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw PortInUse(port: port) }
        return port
    }

    static func send(_ bytes: [UInt8], to port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        _ = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }

    static func intensity(_ store: DMXStore, at now: Double = DMXStore.now) -> ResolvedParameterInfo? {
        store.snapshot(at: now).fixtures["Layer 1"]?.first { $0.key == "intensity" }
    }

    /// Waits (≤ 3 s) until Layer 1's intensity is `raw`.
    static func wait(_ store: DMXStore, for raw: UInt16) async throws -> Bool {
        for _ in 0..<60 {
            if intensity(store)?.raw == raw { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    static func artnet(_ level: UInt8, sequence: UInt8 = 0) -> [UInt8] { ArtDmx(sequence: sequence, portAddress: 0, data: [UInt8](repeating: level, count: 512)).encoded() }

    func receiving(_ loss: UniverseSettings.Loss) async throws -> (DMXStore, ArtNetReceiver, UInt16) {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: Self.logger)
        var settings = UniverseSettings(for: Self.a0)
        settings.holdOnLoss = loss
        store.setUniverseSettings([Self.a0: settings])
        let port = try Self.freePort()
        let receiver = ArtNetReceiver(store: store, logger: Self.logger, nodeName: "test", port: port)
        try receiver.start()
        try await Task.sleep(for: .milliseconds(300))
        Self.send(Self.artnet(255), to: port)
        #expect(try await Self.wait(store, for: 65535))
        return (store, receiver, port)
    }

    /// The tick a full loss timeout after the last packet.
    func lose(_ store: DMXStore) -> Double {
        let later = DMXStore.now + 10
        store.queue.sync { store.tick(at: later) }
        return later
    }

    @Test func holdKeepsTheLastValues() async throws {
        let (store, receiver, _) = try await receiving(.hold)
        defer { receiver.stop() }
        let later = lose(store)
        #expect(Self.intensity(store, at: later)?.raw == 65535 && Self.intensity(store, at: later)?.source == "dmx")
        #expect(store.snapshot(at: later).universes.first { $0.id == "artnet:0.0.0" }?.active == false)
    }

    @Test func zeroDropsToZeroAndPacketsBringItBack() async throws {
        let (store, receiver, port) = try await receiving(.zero)
        defer { receiver.stop() }
        let later = lose(store)
        #expect(Self.intensity(store, at: later)?.raw == 0)
        Self.send(Self.artnet(128), to: port)
        #expect(try await Self.wait(store, for: 0x8080))
    }

    @Test func internalFallsBackToTheUIAndCues() async throws {
        let (store, receiver, port) = try await receiving(.internal)
        defer { receiver.stop() }
        store.setUI(.layer(1), .layer(.intensity), raw: 1000)
        #expect(Self.intensity(store)?.source == "dmx")  // policy dmx while the console is received
        let later = lose(store)
        #expect(Self.intensity(store, at: later)?.raw == 1000 && Self.intensity(store, at: later)?.source == "ui")
        Self.send(Self.artnet(255), to: port)
        #expect(try await Self.wait(store, for: 65535))
    }

    /// Switching to `zero` (or `internal`) while the universe is already lost applies at once, not at the next loss.
    @Test func switchingWhileLostAppliesAtOnce() async throws {
        let (store, receiver, _) = try await receiving(.hold)
        defer { receiver.stop() }
        store.setUI(.layer(1), .layer(.intensity), raw: 1000)
        let later = lose(store)
        #expect(Self.intensity(store, at: later)?.raw == 65535)
        var settings = UniverseSettings(for: Self.a0)
        settings.holdOnLoss = .internal
        store.queue.sync { store.configure([Self.a0: settings], at: later + 1) }
        #expect(Self.intensity(store, at: later + 1)?.source == "ui")
        settings.holdOnLoss = .zero
        store.queue.sync { store.configure([Self.a0: settings], at: later + 2) }
        #expect(Self.intensity(store, at: later + 2)?.raw == 0)
        store.setPolicy(.ltp, for: .layer(1))  // the zeros are stamped now: they win over the older UI value
        #expect(Self.intensity(store, at: later + 2)?.raw == 0 && Self.intensity(store, at: later + 2)?.source == "dmx")
    }

    /// Memberships on a named interface (lo0) are joined, re-joined after the kernel drops them (adapter replugged) at
    /// the next path update or re-assert, and dropped when no universe wants them; an absent interface is reported.
    /// Asked of the kernel (multicast delivery itself needs the Local Network permission, which a test run lacks).
    @Test func sacnMembershipsFollowSettingsAndSurviveReplug() async throws {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: Self.logger)
        let sacn = SACNReceiver(store: store, logger: Self.logger, port: try Self.freePort())
        try sacn.start(groups: ["lo0": [7], "en42": [8]])
        defer { sacn.stop() }
        sacn.pathUpdated()
        #expect(sacn.unjoined() == ["en42": [8]])
        #expect(sacn.isMember(7, on: "127.0.0.1"))
        sacn.dropMembershipsBehindItsBack()
        #expect(!sacn.isMember(7, on: "127.0.0.1"))
        sacn.pathUpdated()
        #expect(sacn.isMember(7, on: "127.0.0.1"))
        sacn.update(groups: ["127.0.0.1": [7, 9]])  // by address; universe 7 stays joined throughout
        sacn.pathUpdated()
        #expect(sacn.isMember(7, on: "127.0.0.1") && sacn.isMember(9, on: "127.0.0.1") && sacn.unjoined().isEmpty)
        sacn.update(groups: [:])
        sacn.pathUpdated()
        #expect(!sacn.isMember(7, on: "127.0.0.1") && !sacn.isMember(9, on: "127.0.0.1"))
    }

    /// "any" joins on every up, multicast, non-loopback interface, reports a failed join per interface, and is not
    /// a warning for the universe-1 placeholder joined when no universe asks for sACN.
    @Test func sacnAnyJoinsEveryMulticastInterface() throws {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: Self.logger)
        let real = SystemInfo.ipv4Interfaces.filter(\.multicast)
        store.interfaceList = { real + [NetworkInterface(name: "en99", address: "10.99.0.1", netmask: "255.255.0.0", multicast: true)] }
        let sacn = SACNReceiver(store: store, logger: Self.logger, port: try Self.freePort())
        try sacn.start(groups: ["any": [3]])
        defer { sacn.stop() }
        sacn.pathUpdated()
        for interface in real { #expect(sacn.isMember(3, on: interface.address), "\(interface.name)") }
        #expect(sacn.unjoined() == ["any via en99": [3]])  // EADDRNOTAVAIL: not an address of this Mac
        sacn.update(groups: [:])
        sacn.pathUpdated()
        #expect(sacn.unjoined().isEmpty)
        for interface in real { #expect(sacn.isMember(1, on: interface.address) && !sacn.isMember(3, on: interface.address)) }
        store.interfaceList = { [] }  // offline
        sacn.update(groups: ["any": [3]])
        sacn.pathUpdated()
        #expect(sacn.unjoined() == ["any": [3]])
    }

    /// A port someone holds without SO_REUSEPORT (nc -u -l 5568) fails the bind: the engine catches it and runs on.
    @Test func sacnBindFailureThrowsAndReadinessWarns() throws {
        let port = try Self.freePort()
        let holder = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(holder) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_ANY
        let held = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(holder, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(held == 0)
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: Self.logger)
        #expect(throws: POSIXError.self) { try SACNReceiver(store: store, logger: Self.logger, port: port).start(groups: [:]) }

        var context = ReadinessContext()
        context.sacnError = "Address already in use"
        let item = try #require(Readiness.check(context, acknowledged: []).first { $0.id == "sacnport" })
        #expect(item.state == .warn && !item.blocks && item.detail == "in use, running without sACN: Address already in use")
    }

    @Test func protocolSwitchesLiveToSACNOnThePair() async throws {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: Self.logger)
        let artPort = try Self.freePort(), sacnPort = try Self.freePort()
        let artnet = ArtNetReceiver(store: store, logger: Self.logger, nodeName: "test", port: artPort)
        try artnet.start()
        let sacn = SACNReceiver(store: store, logger: Self.logger, port: sacnPort)
        try sacn.start(groups: ["any": [1]])
        defer {
            artnet.stop()
            sacn.stop()
        }
        try await Task.sleep(for: .milliseconds(300))
        let cid: [UInt8] = (1...16).map { UInt8($0) }
        Self.send(SACNData(cid: cid, sourceName: "Desk", sequence: 1, universe: 1, slots: [UInt8](repeating: 64, count: 512)).encoded(), to: sacnPort)
        try await Task.sleep(for: .milliseconds(200))
        #expect(Self.intensity(store)?.raw != 0x4040)  // A 0.0.0 does not listen to sACN yet

        var settings = UniverseSettings(for: Self.a0)
        settings.protocols = .sacn
        store.setUniverseSettings([Self.a0: settings])
        sacn.update(groups: UniverseSettings.wire([Self.a0], over: .sacn, settings: [Self.a0: settings]))
        Self.send(SACNData(cid: cid, sourceName: "Desk", sequence: 2, universe: 1, slots: [UInt8](repeating: 64, count: 512)).encoded(), to: sacnPort)
        #expect(try await Self.wait(store, for: 0x4040))
        Self.send(Self.artnet(255), to: artPort)  // Art-Net no longer reaches A 0.0.0
        try await Task.sleep(for: .milliseconds(200))
        #expect(Self.intensity(store)?.raw == 0x4040)
        #expect(store.queue.sync { store.universes } == [UniverseID(.artnet, 1)])  // ArtPollReply: Master and Output only
    }

    @Test func interfaceFiltersSendersAndReportsMissingOnes() async throws {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: Self.logger)
        store.interfaceList = {
            [NetworkInterface(name: "lo0", address: "127.0.0.1", netmask: "255.0.0.0"), NetworkInterface(name: "en9", address: "10.9.0.1", netmask: "255.255.0.0")]
        }
        let port = try Self.freePort()
        let receiver = ArtNetReceiver(store: store, logger: Self.logger, nodeName: "test", port: port)
        try receiver.start()
        defer { receiver.stop() }
        try await Task.sleep(for: .milliseconds(300))

        var settings = UniverseSettings(for: Self.a0)
        settings.interface = "en9"
        store.setUniverseSettings([Self.a0: settings])
        Self.send(Self.artnet(255), to: port)
        try await Task.sleep(for: .milliseconds(200))
        #expect(Self.intensity(store)?.raw != 65535)  // loopback is not en9
        #expect(store.missingInterfaces().isEmpty)

        settings.interface = "127.0.0.1"  // by address: lo0
        store.setUniverseSettings([Self.a0: settings])
        Self.send(Self.artnet(255), to: port)
        #expect(try await Self.wait(store, for: 65535))

        settings.interface = "en5"
        store.setUniverseSettings([Self.a0: settings])
        #expect(store.missingInterfaces() == ["artnet:0.0.0: en5"])
    }
}
