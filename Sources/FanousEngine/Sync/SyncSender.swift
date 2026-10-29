// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Darwin
import FanousCore
import Foundation
import Logging
import QuartzCore
import Synchronization

/// `settings.json` › `sync` (DESIGN.md §23.2); read at start, changed with `sync.set`.
public struct SyncSettings: Codable, Sendable, Equatable {
    /// "any" (the first up, non-loopback interface) or an interface name or address; where broadcasts go out.
    public var interface = "any"
    public var port: UInt16 = 8002
    /// "broadcast", or an IPv4 address with an optional ":port" (two engines on one Mac listen on different ports).
    public var target = "broadcast"

    /// Fields that could not be read and kept their default; never written back.
    public private(set) var problems: [String] = []

    enum CodingKeys: String, CodingKey { case interface, port, target }

    public init() {}

    /// "broadcast", or an IPv4 address with an optional ":port" (1–65535): what the sender can send to.
    static func isValidTarget(_ target: String) -> Bool {
        if target == "broadcast" { return true }
        let parts = target.split(separator: ":", omittingEmptySubsequences: false)
        var address = in_addr()
        guard parts.count <= 2, inet_pton(AF_INET, String(parts[0]), &address) == 1 else { return false }
        return parts.count == 1 || (UInt16(parts[1]) ?? 0) > 0
    }

    /// Field by field: a bad field keeps its default, the others are still read.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        do { interface = try c.decodeIfPresent(String.self, forKey: .interface) ?? interface } catch {
            problems.append("interface: \(error)")
        }
        do {
            let value = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? port
            if value == 0 { problems.append("port: 0 is not a port") } else { port = value }
        } catch { problems.append("port: \(error)") }
        do { target = try c.decodeIfPresent(String.self, forKey: .target) ?? target } catch {
            problems.append("target: \(error)")
        }
    }
}

/// One slot of the sender's triple buffer: the packet the compositor fills in place at the end of a tick.
final class SyncSlot: @unchecked Sendable {
    var packet: SyncPacket
    init(machine: UUID) {
        packet = SyncPacket(machineID: machine, tick: 0, sendTime: 0, layers: [])
        packet.layers.reserveCapacity(SyncPacket.maxLayers)
    }
}

/// Sends the newest master clocks (DESIGN.md §23.2) from a thread of its own: the compositor fills a slot and
/// signals `wake`; a packet goes out for each new tick with master layers, and a count-0 keepalive after 1 s without
/// one (no master, or masters whose tick did not change).
final class SyncSender: @unchecked Sendable {
    let machine: UUID
    var settings: SyncSettings { current.withLock { $0 } }
    let slots: TripleBuffer<SyncSlot>
    let wake = DispatchSemaphore(value: 0)
    let packetsOut = Atomic<Int>(0)
    private let network: Bool
    private let logger: Logger
    private let running = Atomic<Bool>(false)
    private let current: Mutex<SyncSettings>
    /// Set by `apply`: the sender thread resolves the target again before its next packet.
    private let changed = Atomic<Bool>(false)

    /// `network` false (`--no-network`): only a unicast target on 127.0.0.1 is sent to.
    init(machine: UUID, settings: SyncSettings, network: Bool, logger: Logger) {
        self.machine = machine
        current = Mutex(settings)
        self.network = network
        self.logger = logger
        slots = TripleBuffer { SyncSlot(machine: machine) }
    }

    /// Once; a second call does nothing (the slot has one reader).
    func start() {
        guard running.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged else { return }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return logger.error("sync socket failed; not sending", metadata: ["errno": "\(errno)"]) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        let thread = Thread { [self] in loop(fd) }
        thread.name = "org.fanous.sync.send"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        running.store(false, ordering: .relaxed)
        wake.signal()
    }

    /// New interface, port or target (`sync.set`): the next packet goes to the new destination.
    func apply(_ settings: SyncSettings) {
        current.withLock { $0 = settings }
        changed.store(true, ordering: .relaxed)
        wake.signal()
    }

    private func loop(_ fd: Int32) {
        defer { close(fd) }
        var buffer: [UInt8] = []
        buffer.reserveCapacity(SyncPacket.maxSize)
        var lastTick: UInt32?
        var lastSent = 0.0
        var destination: sockaddr_in?
        var resolvedAt = -Double.infinity
        var lastError: Int32 = 0
        while running.load(ordering: .relaxed) {
            _ = wake.wait(timeout: .now() + .seconds(1))
            let now = CACurrentMediaTime()
            let slot = slots.read()
            if !slot.packet.layers.isEmpty, slot.packet.tick != lastTick {
                lastTick = slot.packet.tick
                slot.packet.encode(into: &buffer)
            } else if now - lastSent >= 1 {
                SyncPacket(machineID: machine, tick: slot.packet.tick, sendTime: now, layers: []).encode(into: &buffer)
            } else {
                continue
            }
            lastSent = now
            if changed.exchange(false, ordering: .relaxed) || now - resolvedAt >= 5 {  // new settings, an interface that comes up later, or a new address
                resolvedAt = now
                destination = resolve()
            }
            guard var address = destination else { continue }
            let sent = withUnsafePointer(to: &address) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buffer, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if sent == buffer.count {
                packetsOut.wrappingAdd(1, ordering: .relaxed)
                lastError = 0
            } else if errno != lastError {
                lastError = errno
                logger.warning("sync packet not sent", metadata: ["errno": "\(errno)", "target": "\(settings.target)"])
            }
        }
    }

    /// The target's address: the sync interface's subnet broadcast, or the unicast address (127.0.0.1 only without
    /// the network). nil = nowhere, logged when it changes to that.
    private func resolve() -> sockaddr_in? {
        let settings = self.settings
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = settings.port.bigEndian
        if settings.target == "broadcast" {
            guard network else {
                return nowhere("broadcast is not sent with --no-network; set sync.target to 127.0.0.1:<port>")
            }
            let interfaces = SystemInfo.ipv4Interfaces.filter { $0.multicast && $0.broadcast }
            let match =
                settings.interface == "any"
                ? interfaces.first
                : interfaces.first { $0.name == settings.interface || $0.address == settings.interface }
            guard let match else {
                return nowhere("sync interface \(settings.interface) not found or without broadcast")
            }
            address.sin_addr.s_addr = inet_addr(match.address) | ~inet_addr(match.netmask)
        } else {
            let parts = settings.target.split(separator: ":", omittingEmptySubsequences: false)
            guard let host = parts.first, parts.count <= 2, inet_pton(AF_INET, String(host), &address.sin_addr) == 1
            else {
                return nowhere("sync target \(settings.target) is not an IPv4 address with an optional :port")
            }
            if parts.count == 2 {
                guard let port = UInt16(parts[1]), port > 0 else {
                    return nowhere("sync target \(settings.target) has no valid port")
                }
                address.sin_port = port.bigEndian
            }
            guard network || host == "127.0.0.1" else {
                return nowhere("sync target \(host) is not sent to with --no-network; only 127.0.0.1")
            }
        }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let to =
            "\(String(cString: inet_ntop(AF_INET, &address.sin_addr, &text, socklen_t(text.count))!)):\(UInt16(bigEndian: address.sin_port))"
        if to != lastHost { logger.info("sync sending", metadata: ["to": "\(to)"]) }
        lastHost = to
        return address
    }

    /// Sender thread only.
    private var lastHost = ""

    private func nowhere(_ reason: String) -> sockaddr_in? {
        if lastHost != reason { logger.warning("sync not sent", metadata: ["reason": "\(reason)"]) }
        lastHost = reason
        return nil
    }
}
