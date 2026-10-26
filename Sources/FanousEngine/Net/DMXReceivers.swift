// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import Logging
import Network

/// Art-Net 4 on UDP 6454: ArtDmx into the store, ArtPoll answered with ArtPollReply (unicast to the poller).
public final class ArtNetReceiver: @unchecked Sendable {
    private let store: DMXStore
    private let logger: Logger
    private let nodeName: String
    private var listener: NWListener?
    private let port: UInt16

    public init(store: DMXStore, logger: Logger, nodeName: String, port: UInt16 = ArtNet.port) {
        self.store = store
        self.logger = logger
        self.nodeName = nodeName
        self.port = port
    }

    public func start() throws {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.stateUpdateHandler = { [logger, port] state in
            switch state {
            case .ready: logger.info("Art-Net listening", metadata: ["port": "\(port)"])
            case .failed(let error): logger.error("Art-Net listener failed", metadata: ["error": "\(error)"])
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            connection.start(queue: store.queue)
            receive(on: connection)
        }
        listener.start(queue: store.queue)
        self.listener = listener
    }

    public func stop() { listener?.cancel() }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [self] data, _, _, error in
            if let data, let packet = try? ArtNet.parse(Array(data)) {
                let source = Self.host(of: connection.endpoint)
                switch packet {
                case .dmx(let dmx): store.receive(artnet: dmx, from: source)
                case .poll: reply(to: connection)
                default: break
                }
            }
            if error != nil { return connection.cancel() }
            receive(on: connection)
        }
    }

    private func reply(to connection: NWConnection) {
        let ip = SystemInfo.ipv4Addresses.first.flatMap(Self.ipBytes) ?? [127, 0, 0, 1]
        let replies = ArtPollReply.replies(
            universes: store.universes, ipAddress: ip, shortName: nodeName, longName: "\(Attribution.projectName) Media Server",
            nodeReport: "#0001 [0000] \(Attribution.projectName) \(FanousVersion.string)")
        for reply in replies { connection.send(content: Data(reply.encoded()), completion: .idempotent) }
    }

    static func host(of endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint { return "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)" }
        return "\(endpoint)"
    }

    static func ipBytes(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 ? parts : nil
    }
}

/// sACN on UDP 5568: one socket on every interface (unicast always works) that joins each universe's multicast group
/// on the interface the universe asks for ("any": the default-route interface). Network.framework cannot do this: a
/// second `NWConnectionGroup` on the port fails with EADDRINUSE. Changing a universe adds or drops only its own
/// memberships; the socket is never rebound. Memberships are re-asserted on every path change and every 5 s, so an
/// adapter that is replugged (the kernel drops its memberships) or comes up later is joined again (B28).
public final class SACNReceiver: @unchecked Sendable {
    private let store: DMXStore
    private let logger: Logger
    private let port: UInt16
    private struct Membership: Hashable {
        var universe: Int
        /// in_addr of the interface, network order; 0 = the default-route interface.
        var interface: UInt32
    }
    /// Touched on the DMX queue.
    private var fd: Int32 = -1
    private var reader: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var wanted: [String: [Int]] = [:]
    private var joined: Set<Membership> = []
    /// Interfaces with universes but without their memberships (not present, or the join failed).
    private var failed: [String: [Int]] = [:]
    private let monitor = NWPathMonitor()
    static let reassertInterval: TimeInterval = 5

    public init(store: DMXStore, logger: Logger, port: UInt16 = SACN.port) {
        self.store = store
        self.logger = logger
        self.port = port
    }

    /// Binds the port (shared with other receivers, SO_REUSEPORT) and joins `groups` (interface → universes).
    public func start(groups: [String: [Int]]) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            close(fd)
            throw error
        }
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: store.queue)
        reader.setEventHandler { [weak self] in self?.read() }
        reader.setCancelHandler { close(fd) }
        let timer = DispatchSource.makeTimerSource(queue: store.queue)
        timer.schedule(deadline: .now() + Self.reassertInterval, repeating: Self.reassertInterval)
        timer.setEventHandler { [weak self] in self?.apply() }
        store.queue.sync {
            self.fd = fd
            self.reader = reader
            self.timer = timer
        }
        reader.resume()
        timer.resume()
        monitor.pathUpdateHandler = { [weak self] _ in self?.apply() }
        monitor.start(queue: store.queue)
        logger.info("sACN listening", metadata: ["port": "\(port)"])
        update(groups: groups)
    }

    /// Patch or universe settings changed.
    public func update(groups: [String: [Int]]) {
        store.queue.async { [self] in
            wanted = groups
            apply()
        }
    }

    /// Named interfaces whose universes are not joined (readiness).
    public func unjoined() -> [String: [Int]] { store.queue.sync { failed } }

    /// A path update or the periodic re-assert (tests).
    func pathUpdated() { store.queue.sync { apply() } }

    /// Drops every membership behind the receiver's back, as the kernel does when an adapter goes away (tests).
    func dropMembershipsBehindItsBack() { store.queue.sync { for m in joined { _ = setMembership(m, IP_DROP_MEMBERSHIP) } } }

    /// Whether the socket is a member of `universe`'s group on `interface` (an IPv4 address, "0.0.0.0" = default), asked
    /// of the kernel: adding a membership it already has fails with EADDRINUSE (tests).
    func isMember(_ universe: Int, on interface: String) -> Bool {
        store.queue.sync {
            let m = Membership(universe: universe, interface: inet_addr(interface))
            let error = setMembership(m, IP_ADD_MEMBERSHIP)
            if error == 0 { _ = setMembership(m, IP_DROP_MEMBERSHIP) }
            return error == EADDRINUSE
        }
    }

    private func setMembership(_ m: Membership, _ option: Int32) -> Int32 {
        var request = ip_mreq()
        request.imr_multiaddr.s_addr = inet_addr(SACN.multicastAddress(universe: m.universe))
        request.imr_interface.s_addr = m.interface
        return setsockopt(fd, IPPROTO_IP, option, &request, socklen_t(MemoryLayout<ip_mreq>.size)) == 0 ? 0 : errno
    }

    /// On the DMX queue: drop memberships nobody wants, then (re)add every wanted one. Adding is idempotent
    /// (EADDRINUSE = already a member), so re-asserting also restores memberships the kernel dropped, and one a drop
    /// removed while another interface spec ("any" and the default interface's name) still needs it.
    private func apply() {
        guard fd >= 0 else { return }
        let interfaces = store.interfaceList()
        var desired: Set<Membership> = []
        var failed: [String: [Int]] = [:]
        for (interface, universes) in wanted {
            let address: UInt32?
            if interface == UniverseSettings.anyInterface {
                address = INADDR_ANY
            } else {
                let match = interfaces.first { $0.address == interface } ?? interfaces.first { $0.name == interface }
                address = match.map { inet_addr($0.address) }
            }
            guard let address else {
                failed[interface] = universes
                continue
            }
            for universe in universes {
                let m = Membership(universe: universe, interface: address)
                desired.insert(m)
                let error = setMembership(m, IP_ADD_MEMBERSHIP)
                if error != 0 && error != EADDRINUSE {
                    failed[interface, default: []].append(universe)
                    desired.remove(m)
                }
            }
        }
        for m in joined.subtracting(desired) { _ = setMembership(m, IP_DROP_MEMBERSHIP) }
        if !joined.subtracting(desired).isEmpty {
            for m in desired { _ = setMembership(m, IP_ADD_MEMBERSHIP) }
        }
        if failed != self.failed || desired != joined {
            if !failed.isEmpty { logger.warning("sACN multicast not joined; retrying", metadata: ["interfaces": "\(failed)"]) }
            if desired != joined { logger.info("sACN multicast joined", metadata: ["groups": "\(wanted)"]) }
        }
        self.failed = failed
        joined = desired
    }

    private func read() {
        var buffer = [UInt8](repeating: 0, count: 1500)
        var sender = sockaddr_in()
        while true {
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
            }
            guard count > 0 else { return }  // EAGAIN: drained
            guard case .data(let packet)? = try? SACN.parse(Array(buffer[0..<count])) else { continue }
            store.receive(sacn: packet, from: String(cString: inet_ntoa(sender.sin_addr)))
        }
    }

    public func stop() {
        monitor.cancel()
        store.queue.async { [self] in
            timer?.cancel()
            reader?.cancel()  // closes the socket, which drops its memberships
            fd = -1
        }
    }
}

/// OSC on UDP and TCP (SLIP). Commands go to the store; cue/show commands are logged until Phase 5/7 wire them.
public final class OSCReceiver: @unchecked Sendable {
    private let store: DMXStore
    private let logger: Logger
    private let port: UInt16
    private var udp: NWListener?
    private var tcp: NWListener?

    public init(store: DMXStore, logger: Logger, port: UInt16 = 8000) {
        self.store = store
        self.logger = logger
        self.port = port
    }

    public func start() throws {
        let udpParameters = NWParameters.udp
        udpParameters.allowLocalEndpointReuse = true
        let udp = try NWListener(using: udpParameters, on: NWEndpoint.Port(rawValue: port)!)
        udp.stateUpdateHandler = { [logger, port] state in
            if case .ready = state { logger.info("OSC listening", metadata: ["udp": "\(port)", "tcp": "\(port)"]) }
            if case .failed(let error) = state { logger.error("OSC UDP failed", metadata: ["error": "\(error)"]) }
        }
        udp.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            connection.start(queue: store.queue)
            receiveDatagrams(on: connection)
        }
        udp.start(queue: store.queue)
        self.udp = udp

        let tcpParameters = NWParameters.tcp
        tcpParameters.allowLocalEndpointReuse = true
        let tcp = try NWListener(using: tcpParameters, on: NWEndpoint.Port(rawValue: port)!)
        tcp.stateUpdateHandler = { [logger] state in
            if case .failed(let error) = state { logger.error("OSC TCP failed", metadata: ["error": "\(error)"]) }
        }
        tcp.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            connection.start(queue: store.queue)
            receiveStream(on: connection, decoder: SLIPDecoder())
        }
        tcp.start(queue: store.queue)
        self.tcp = tcp
    }

    public func stop() {
        udp?.cancel()
        tcp?.cancel()
    }

    private func receiveDatagrams(on connection: NWConnection) {
        connection.receiveMessage { [self] data, _, _, error in
            if let data { handle(Array(data)) }
            if error != nil { return connection.cancel() }
            receiveDatagrams(on: connection)
        }
    }

    private func receiveStream(on connection: NWConnection, decoder: SLIPDecoder) {
        var decoder = decoder
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            if let data { for packet in decoder.feed(Array(data)) { handle(packet) } }
            if isComplete || error != nil { return connection.cancel() }
            receiveStream(on: connection, decoder: decoder)
        }
    }

    private func handle(_ bytes: [UInt8]) {
        guard let packet = try? OSCPacket.parse(bytes) else { return }
        dispatch(packet)
    }

    private func dispatch(_ packet: OSCPacket) {
        switch packet {
        case .message(let message):
            guard let command = OSCAddressMap.command(for: message) else { return }
            store.apply(command)
        case .bundle(let bundle):
            // NTP timetag: seconds since 1900 in the high word, fraction in the low word; 1 = immediately
            let delay = bundle.timetag <= 1 ? 0 : (Double(bundle.timetag >> 32) - 2_208_988_800 + Double(bundle.timetag & 0xFFFF_FFFF) / 4_294_967_296) - Date().timeIntervalSince1970
            if delay > 0.001, delay < 3600 {
                store.queue.asyncAfter(deadline: .now() + delay) { [self] in for element in bundle.elements { dispatch(element) } }
            } else {
                for element in bundle.elements { dispatch(element) }
            }
        }
    }
}
