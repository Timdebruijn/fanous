// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Darwin
import FanousCore
import Foundation
import Logging
import QuartzCore
import Synchronization

/// The newest master clock per sync group (DESIGN.md §23.2). Fixed size: `copy(from:)` and `offer` never allocate,
/// so the compositor can keep a copy and add its own masters to it.
struct SyncTable: Sendable {
    struct Entry: Sendable, Equatable {
        var machine: UUID
        var clock: SyncPacket.Layer
        /// CACurrentMediaTime of arrival (local clock only): the kernel's receive time for a packet.
        var receivedAt: Double
        /// The packet's tick; nil for a master on this machine.
        var tick: UInt32? = nil
    }
    struct Conflict: Sendable, Equatable {
        var machine: UUID
        var at: Double
    }
    /// Index: group − 1.
    private(set) var entries = [Entry?](repeating: nil, count: LayerSync.groups)
    /// The machine whose clock was ignored (or replaced) last, per group.
    private(set) var conflicts = [Conflict?](repeating: nil, count: LayerSync.groups)

    /// The lowest machine id wins while its entry is fresh (younger than the freewheel time); the other machine is
    /// recorded as the group's conflict. A stale entry is replaced by anyone. From the same machine, a packet whose
    /// `tick` is the fresh entry's or up to `reorderWindow` behind it is a duplicate or arrived out of order: dropped,
    /// so it never replaces a newer clock (B317). A master that restarts (its ticks from 0) is normally further behind
    /// than that; one restarted within `reorderWindow` ticks of its previous start is dropped until the entry goes stale
    /// (at most the freewheel time, 2 s).
    mutating func offer(_ clock: SyncPacket.Layer, from machine: UUID, tick: UInt32? = nil, at now: Double) {
        let g = Int(clock.group) - 1
        guard entries.indices.contains(g) else { return }
        if let current = entries[g], now - current.receivedAt <= SlaveClock.freewheelSeconds {
            if current.machine != machine {
                guard Self.precedes(machine, current.machine) else {
                    conflicts[g] = Conflict(machine: machine, at: now)
                    return
                }
                conflicts[g] = Conflict(machine: current.machine, at: now)
            } else if let tick, let last = current.tick, (0...Self.reorderWindow).contains(Int32(bitPattern: last &- tick)) {
                return
            }
        }
        entries[g] = Entry(machine: machine, clock: clock, receivedAt: now, tick: tick)
    }

    /// Ticks: about a second at 240 Hz, far more than a LAN reorders.
    static let reorderWindow: Int32 = 256

    /// A second master seen in `group` within the freewheel time.
    func conflict(group: Int, now: Double) -> UUID? {
        guard let c = conflicts[group - 1], now - c.at <= SlaveClock.freewheelSeconds else { return nil }
        return c.machine
    }

    mutating func copy(from other: SyncTable) {
        for g in entries.indices {
            entries[g] = other.entries[g]
            conflicts[g] = other.conflicts[g]
        }
    }

    /// Byte order of the UUID, which is the order of its `uuidString`, without making a string.
    static func precedes(_ a: UUID, _ b: UUID) -> Bool {
        withUnsafeBytes(of: a.uuid) { a in withUnsafeBytes(of: b.uuid) { b in a.lexicographicallyPrecedes(b) } }
    }
}

/// Receives the clock packets of every master on the LAN into `table` (DESIGN.md §23.2): one UDP socket shared with
/// other engines on the Mac (SO_REUSEPORT), read on its own queue. The compositor reads the table once per tick.
final class SyncReceiver: @unchecked Sendable {
    let machine: UUID
    let table = Mutex(SyncTable())
    let packetsIn = Atomic<Int>(0)
    let decodeErrors = Atomic<Int>(0)
    private let logger: Logger
    /// The control plane's class, like `org.fanous.control` and `org.fanous.https` (B318): the handler decodes and
    /// allocates, so it is not one of ADR-0002's `.userInteractive` hot paths, and its delay no longer reaches the clock
    /// since the arrival time is the kernel's (B317).
    let queue = DispatchQueue(label: "org.fanous.sync", qos: .userInitiated)
    /// Queue only.
    private var reader: DispatchSourceRead?
    private var lastErrorLog = -Double.infinity

    init(machine: UUID, logger: Logger) {
        self.machine = machine
        self.logger = logger
    }

    /// Binds `port` on every interface, or on 127.0.0.1 only (`--no-network`); returns the port bound, which differs
    /// only for port 0 (tests only: the kernel picks one).
    @discardableResult
    func start(port: UInt16, loopbackOnly: Bool) throws -> UInt16 {
        let fd = try UDPSend.bound(port: port, address: loopbackOnly ? inet_addr("127.0.0.1") : INADDR_ANY)
        var on: Int32 = 1  // each datagram carries the mach time the kernel queued it at (SCM_TIMESTAMP_MONOTONIC)
        setsockopt(fd, SOL_SOCKET, SO_TIMESTAMP_MONOTONIC, &on, socklen_t(MemoryLayout<Int32>.size))
        let port = UDPSend.localPort(fd) ?? port
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in self?.read(fd) }
        reader.setCancelHandler { close(fd) }
        queue.sync { self.reader = reader }
        reader.resume()
        logger.info(
            "sync listening", metadata: ["port": "\(port)", "address": "\(loopbackOnly ? "127.0.0.1" : "any")"])
        return port
    }

    /// What the engine binds (`startSync`, `sync.set`): `port` on 127.0.0.1 only without the network, and with
    /// `--no-network` never the default port (B337). false = not bound for that reason.
    func start(port: UInt16, network: Bool) throws -> Bool {
        guard SyncSettings.usable(port, network: network) else { return false }
        try start(port: port, loopbackOnly: !network)
        return true
    }

    /// A socket is bound and read.
    var listening: Bool { queue.sync { reader != nil } }

    func stop() {
        queue.sync {
            reader?.cancel()
            reader = nil
        }
    }

    private func read(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 1500)
        var control = [UInt8](repeating: 0, count: 64)
        for _ in 0..<256 {  // a flood cannot hold the queue: the source fires again
            var stamp: UInt64 = 0
            let count = Self.receive(fd, into: &buffer, control: &control, stamp: &stamp)
            guard count > 0 else { return }  // EAGAIN: drained
            // the kernel's time, not this handler's: the queue's delay is not the master's (B317)
            receive(Array(buffer[0..<count]), at: stamp > 0 ? Double(stamp) / PacedThread.ticksPerSecond : CACurrentMediaTime())
        }
    }

    /// `recvmsg` with the datagram's SCM_TIMESTAMP_MONOTONIC (mach absolute time, CACurrentMediaTime's clock) in
    /// `stamp`, left 0 when the kernel gave none.
    private static func receive(_ fd: Int32, into buffer: inout [UInt8], control: inout [UInt8], stamp: inout UInt64) -> Int {
        buffer.withUnsafeMutableBytes { data in
            control.withUnsafeMutableBytes { control in
                var iov = iovec(iov_base: data.baseAddress, iov_len: data.count)
                return withUnsafeMutablePointer(to: &iov) { iov in
                    var message = msghdr(
                        msg_name: nil, msg_namelen: 0, msg_iov: iov, msg_iovlen: 1, msg_control: control.baseAddress,
                        msg_controllen: socklen_t(control.count), msg_flags: 0)
                    let count = recvmsg(fd, &message, 0)
                    let header = MemoryLayout<cmsghdr>.size  // 12: CMSG_DATA's offset (4-byte alignment on Darwin)
                    // the only control message: no other option asks for one
                    if count > 0, Int(message.msg_controllen) >= header + 8 {
                        let h = control.loadUnaligned(as: cmsghdr.self)
                        if h.cmsg_level == SOL_SOCKET, h.cmsg_type == SCM_TIMESTAMP_MONOTONIC, Int(h.cmsg_len) >= header + 8 {
                            stamp = control.loadUnaligned(fromByteOffset: header, as: UInt64.self)
                        }
                    }
                    return count
                }
            }
        }
    }

    private func receive(_ bytes: [UInt8], at now: Double) {
        let packet: SyncPacket
        do {
            packet = try SyncPacket.decode(bytes)
        } catch {
            let errors = decodeErrors.wrappingAdd(1, ordering: .relaxed).newValue
            if now - lastErrorLog >= 60 {
                lastErrorLog = now
                logger.warning("sync packet not understood", metadata: ["error": "\(error)", "count": "\(errors)"])
            }
            return
        }
        guard packet.machineID != machine else { return }  // our own broadcast; local groups use the table directly
        packetsIn.wrappingAdd(1, ordering: .relaxed)
        guard !packet.layers.isEmpty else { return }  // keepalive
        table.withLock { table in
            // reversed: two masters of one group in one packet share its tick, and the last must win, as it does for
            // local slaves (the compositor offers its masters in layer order)
            for clock in packet.layers.reversed() { table.offer(clock, from: packet.machineID, tick: packet.tick, at: now) }
        }
    }
}
