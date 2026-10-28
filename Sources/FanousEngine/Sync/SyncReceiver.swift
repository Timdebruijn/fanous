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
        /// CACurrentMediaTime of arrival (local clock only).
        var receivedAt: Double
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
    /// recorded as the group's conflict. A stale entry is replaced by anyone.
    mutating func offer(_ clock: SyncPacket.Layer, from machine: UUID, at now: Double) {
        let g = Int(clock.group) - 1
        guard entries.indices.contains(g) else { return }
        if let current = entries[g], current.machine != machine, now - current.receivedAt <= SlaveClock.freewheelSeconds
        {
            guard Self.precedes(machine, current.machine) else {
                conflicts[g] = Conflict(machine: machine, at: now)
                return
            }
            conflicts[g] = Conflict(machine: current.machine, at: now)
        }
        entries[g] = Entry(machine: machine, clock: clock, receivedAt: now)
    }

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
    private let queue = DispatchQueue(label: "org.fanous.sync")
    /// Queue only.
    private var reader: DispatchSourceRead?
    private var lastErrorLog = -Double.infinity

    init(machine: UUID, logger: Logger) {
        self.machine = machine
        self.logger = logger
    }

    /// Binds `port` on every interface, or on 127.0.0.1 only (`--no-network`).
    func start(port: UInt16, loopbackOnly: Bool) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = loopbackOnly ? inet_addr("127.0.0.1") : INADDR_ANY
        let bound = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            close(fd)
            throw error
        }
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in self?.read(fd) }
        reader.setCancelHandler { close(fd) }
        queue.sync { self.reader = reader }
        reader.resume()
        logger.info(
            "sync listening", metadata: ["port": "\(port)", "address": "\(loopbackOnly ? "127.0.0.1" : "any")"])
    }

    func stop() {
        queue.sync {
            reader?.cancel()
            reader = nil
        }
    }

    private func read(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 1500)
        for _ in 0..<256 {  // a flood cannot hold the queue: the source fires again
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { return }  // EAGAIN: drained
            receive(Array(buffer[0..<count]), at: CACurrentMediaTime())
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
            for clock in packet.layers { table.offer(clock, from: packet.machineID, at: now) }
        }
    }
}
