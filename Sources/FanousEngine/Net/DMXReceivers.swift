// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import Logging
import Network
import Synchronization

/// Art-Net 4 on UDP 6454: ArtDmx into the store, ArtPoll answered with ArtPollReply (unicast to the poller).
public final class ArtNetReceiver: @unchecked Sendable {
    private let store: DMXStore
    private let logger: Logger
    private let nodeName: String
    private var listener: NWListener?
    private let port: UInt16
    private let failed = Mutex<String?>(nil)
    let flows: UDPFlows

    public init(store: DMXStore, logger: Logger, nodeName: String, port: UInt16 = ArtNet.port) {
        self.store = store
        self.logger = logger
        self.nodeName = nodeName
        self.port = port
        flows = UDPFlows(queue: store.queue, logger: logger, name: "Art-Net")
    }

    /// The port listened on, once the listener is ready (nil or 0 before). Differs from the one given only for port 0
    /// (tests only: the kernel picks one).
    public var boundPort: UInt16? { listener?.port?.rawValue }

    /// Why the listener failed (a program that holds UDP 6454 exclusively), for readiness (B167); nil while it runs.
    public var failure: String? { failed.withLock { $0 } }

    public func start() throws {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.stateUpdateHandler = { [logger, port, weak self, weak listener] state in
            switch state {
            case .ready: logger.info("Art-Net listening", metadata: ["port": "\(listener?.port?.rawValue ?? port)"])
            case .failed(let error):
                logger.error("Art-Net listener failed", metadata: ["error": "\(error)"])
                self?.failed.withLock { $0 = "\(error)" }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            connection.start(queue: store.queue)
            receive(on: flows.adopt(connection))
        }
        listener.start(queue: store.queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        flows.stop()
    }

    private func receive(on flow: UDPFlows.Flow) {
        let connection = flow.connection
        connection.receiveMessage { [self] data, _, _, error in
            flows.touch(flow)
            if let data, let packet = try? ArtNet.parse(Array(data)) {
                let source = Self.host(of: connection.endpoint)
                switch packet {
                case .dmx(let dmx): store.receive(artnet: dmx, from: source)
                case .poll: reply(to: connection)
                default: break
                }
            }
            if error != nil { return flows.release(flow) }
            receive(on: flow)
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

/// sACN on UDP 5568: one BSD socket bound on every interface (unicast always works) that joins each universe's
/// multicast group on the interface the universe asks for ("any": every up, multicast, non-loopback interface). It
/// replaces `NWConnectionGroup`s, which cannot share the port per interface (the second fails with EADDRINUSE).
/// Changing a universe adds or drops only its own memberships; the socket is never rebound. Memberships are re-asserted
/// on every path change and every 5 s, so an adapter that is replugged (the kernel drops its memberships) or comes up
/// later is joined again (B28). SO_REUSEPORT lets another receiver (sACNView, a second Fanous) bind the port too: both
/// get multicast, but unicast goes to only one of them, the later one.
public final class SACNReceiver: @unchecked Sendable {
    private let store: DMXStore
    private let logger: Logger
    private let port: UInt16
    private struct Membership: Hashable {
        var universe: Int
        /// in_addr of the interface, network order.
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
    /// Universe 1 joined only because no universe asks for sACN: not worth a readiness warning.
    private var placeholder = false
    private let monitor = NWPathMonitor()
    static let reassertInterval: TimeInterval = 5

    public init(store: DMXStore, logger: Logger, port: UInt16 = SACN.port) {
        self.store = store
        self.logger = logger
        self.port = port
    }

    /// Binds the port (shared with other receivers, SO_REUSEPORT) and joins `groups` (interface → universes); returns
    /// the port bound, which differs only for port 0 (tests only: the kernel picks one).
    @discardableResult
    public func start(groups: [String: [Int]]) throws -> UInt16 {
        // 32 universes at 44 Hz while the DMX queue is busy for a moment: 4 MB holds several seconds of packets
        let fd = try UDPSend.bound(port: port, address: INADDR_ANY, receiveBuffer: 4 << 20)
        let port = UDPSend.localPort(fd) ?? port
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
        return port
    }

    /// Patch or universe settings changed. Without sACN universes, universe 1 is joined on any interface (as before B28).
    public func update(groups: [String: [Int]]) {
        store.queue.async { [self] in
            placeholder = groups.isEmpty
            wanted = placeholder ? [UniverseSettings.anyInterface: [1]] : groups
            apply()
        }
    }

    /// Interfaces whose universes are not joined, for readiness: a named interface, "any" (no multicast interface at
    /// all), or "any via en5" (the join failed on that interface, e.g. EADDRNOTAVAIL on an isolated LAN).
    public func unjoined() -> [String: [Int]] { store.queue.sync { placeholder ? [:] : failed } }

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
    /// removed while another interface spec ("any" and an interface name) still needs it.
    private func apply() {
        guard fd >= 0 else { return }
        let interfaces = store.interfaceList()
        var desired: Set<Membership> = []
        var failed: [String: [Int]] = [:]
        for (interface, universes) in wanted {
            // "any": every up, multicast, non-loopback interface (a console on a NIC without a gateway must work)
            let targets: [(label: String, address: String)]
            if interface == UniverseSettings.anyInterface {
                targets = interfaces.filter(\.multicast).map { ("\(interface) via \($0.name)", $0.address) }
            } else {
                let match = interfaces.first { $0.address == interface } ?? interfaces.first { $0.name == interface }
                targets = match.map { [(interface, $0.address)] } ?? []
            }
            if targets.isEmpty { failed[interface] = universes }
            for target in targets {
                for universe in universes {
                    let m = Membership(universe: universe, interface: inet_addr(target.address))
                    let error = setMembership(m, IP_ADD_MEMBERSHIP)
                    // EADDRINUSE: already a member (a second address of the interface, or another spec wants it too)
                    if error == 0 || error == EADDRINUSE {
                        desired.insert(m)
                    } else {
                        failed[target.label, default: []].append(universe)
                    }
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

    /// At most `drainLimit` packets per read event, so a flood cannot hold the DMX queue (the source fires again).
    static let drainLimit = 256

    private func read() {
        var buffer = [UInt8](repeating: 0, count: 1500)
        var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var sender = sockaddr_in()
        for _ in 0..<Self.drainLimit {
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
            }
            guard count > 0 else { return }  // EAGAIN: drained
            guard case .data(let packet)? = try? SACN.parse(Array(buffer[0..<count])) else { continue }
            let from = inet_ntop(AF_INET, &sender.sin_addr, &host, socklen_t(host.count)) != nil ? String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
            store.receive(sacn: packet, from: from)
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

/// OSC on UDP and TCP (SLIP). Commands go to the store, which hands cue/show commands to the engine (`onCommand`).
public final class OSCReceiver: @unchecked Sendable {
    private let store: DMXStore
    private let logger: Logger
    private let port: UInt16
    private var udp: NWListener?
    private var tcp: NWListener?
    /// B36: `get`, `subscribe`, `unsubscribe` and `ping`; nil ignores them.
    private let feedback: OSCFeedbackServer?
    let flows: UDPFlows

    /// OSC in; 8001 next to it is reserved for OSC out (DESIGN.md OPEN-24).
    public static let defaultPort: UInt16 = 8000

    public init(store: DMXStore, logger: Logger, port: UInt16 = defaultPort, feedback: OSCFeedbackServer? = nil) {
        self.store = store
        self.logger = logger
        self.port = port
        self.feedback = feedback
        flows = UDPFlows(queue: store.queue, logger: logger, name: "OSC")
        // a live subscription keeps its flow: a hop to the DMX queue per change of the subscriber set (subscribe, ack,
        // unsubscribe, expiry), never per datagram
        feedback?.onPins = { [flows, queue = store.queue] keys in queue.async { flows.pinnedKeys = keys } }
    }

    /// The UDP port listened on, once the listener is ready (nil or 0 before). Differs from the one given only for port 0
    /// (tests only), where the kernel picks one for UDP and another for TCP.
    public var boundUDPPort: UInt16? { udp?.port?.rawValue }

    public func start() throws {
        let udpParameters = NWParameters.udp
        udpParameters.allowLocalEndpointReuse = true
        let udp = try NWListener(using: udpParameters, on: NWEndpoint.Port(rawValue: port)!)
        udp.stateUpdateHandler = { [logger, port, weak udp] state in
            if case .ready = state { logger.info("OSC listening", metadata: ["udp": "\(udp?.port?.rawValue ?? port)", "tcp": "\(port)"]) }
            if case .failed(let error) = state { logger.error("OSC UDP failed", metadata: ["error": "\(error)"]) }
        }
        udp.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            connection.start(queue: store.queue)
            let source = Self.source(connection) { connection.send(content: Data($0), completion: .idempotent) }
            // the fixed feedback target's own flow carries its feedback: kept however long it is silent (B268); a
            // cancelled flow is no longer a subscriber's reply path
            let fixed = feedback?.adopt(source) ?? false
            let flow = flows.adopt(connection, pinned: fixed, key: .init(host: source.host, port: source.port)) { [feedback] in
                feedback?.release(source)
            }
            receiveDatagrams(on: flow, from: source)
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
            receiveStream(
                on: connection, decoder: SLIPDecoder(), from: Self.source(connection) { connection.send(content: Data(SLIPDecoder.encode($0)), completion: .idempotent) })
        }
        tcp.start(queue: store.queue)
        self.tcp = tcp
    }

    public func stop() {
        udp?.cancel()
        tcp?.cancel()
        flows.stop()
    }

    private func receiveDatagrams(on flow: UDPFlows.Flow, from source: OSCSource) {
        flow.connection.receiveMessage { [self] data, _, _, error in
            flows.touch(flow)
            if let data { handle(Array(data), from: source) }
            if error != nil { return flows.release(flow) }
            receiveDatagrams(on: flow, from: source)
        }
    }

    private func receiveStream(on connection: NWConnection, decoder: SLIPDecoder, from source: OSCSource) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            var decoder = decoder
            let dropped = decoder.dropped
            if let data { for packet in decoder.feed(Array(data)) { handle(packet, from: source) } }
            if decoder.dropped > dropped {
                logger.warning(
                    "OSC TCP packet dropped: longer than \(SLIPDecoder.maxPacketBytes) bytes",
                    metadata: ["peer": "\(connection.endpoint)", "dropped": "\(decoder.dropped)"])
            }
            if isComplete || error != nil { return connection.cancel() }
            receiveStream(on: connection, decoder: decoder, from: source)
        }
    }

    private static func source(_ connection: NWConnection, reply: @escaping @Sendable ([UInt8]) -> Void) -> OSCSource {
        // the IPv6 scope stays (fe80::…%en0): feedback connections to a link-local host need it
        guard case .hostPort(let host, let port) = connection.endpoint else {
            return OSCSource(host: "\(connection.endpoint)", port: 0, reply: reply)
        }
        return OSCSource(host: "\(host)", port: port.rawValue, reply: reply)
    }

    private func handle(_ bytes: [UInt8], from source: OSCSource) {
        guard let packet = try? OSCPacket.parse(bytes) else { return }
        dispatch(packet, from: source)
    }

    private func dispatch(_ packet: OSCPacket, from source: OSCSource) {
        switch packet {
        case .message(let message):
            if let request = OSCFeedback.request(for: message) {
                feedback?.handle(request, from: source)
                return
            }
            guard let command = OSCAddressMap.command(for: message) else { return }
            store.apply(command, from: message)
        case .bundle(let bundle):
            // NTP timetag: seconds since 1900 in the high word, fraction in the low word; 1 = immediately
            let delay = bundle.timetag <= 1 ? 0 : (Double(bundle.timetag >> 32) - 2_208_988_800 + Double(bundle.timetag & 0xFFFF_FFFF) / 4_294_967_296) - Date().timeIntervalSince1970
            if delay > 0.001, delay < 3600 {
                store.queue.asyncAfter(deadline: .now() + delay) { [self] in for element in bundle.elements { dispatch(element, from: source) } }
            } else {
                for element in bundle.elements { dispatch(element, from: source) }
            }
        }
    }
}

/// The inbound UDP flows of one `NWListener` (B268): it gives every source address and port an `NWConnection`, and a
/// descriptor, that stays until it is cancelled, so senders that come and go (an OSC app that rebinds its socket, a
/// flood of source ports) would use up the process's open-file limit. A flow silent for `idle` seconds is cancelled
/// (its sender's next datagram makes a new one). Above `cap` live flows the one silent longest goes, among those that
/// have delivered a datagram and been silent for at least `floor`; when none qualifies the table runs over the cap, up
/// to `ceiling`, above which the one silent longest goes at once.
/// A pinned flow (the fixed OSC feedback target's, or one whose key is in `pinnedKeys`: a live OSC subscription) is
/// never cancelled. DMX queue only: a datagram costs a store of the time into its flow, no lookup,
/// no lock, no allocation.
final class UDPFlows: @unchecked Sendable {
    final class Flow: @unchecked Sendable {
        let connection: NWConnection
        fileprivate let pinned: Bool
        /// The sender's host and port as OSC feedback keys them (OSC only).
        fileprivate let key: OSCSubscriptions.Key?
        fileprivate let released: (() -> Void)?
        /// Uptime nanoseconds of the last datagram (tests set it back).
        var lastSeen = DispatchTime.now().uptimeNanoseconds
        fileprivate var read = false
        fileprivate var live = true

        fileprivate init(_ connection: NWConnection, pinned: Bool, key: OSCSubscriptions.Key?, released: (() -> Void)?) {
            self.connection = connection
            self.pinned = pinned
            self.key = key
            self.released = released
        }
    }

    /// Senders do not stay silent this long in a show: a console sends Art-Net continuously or at least every few
    /// seconds. One that does comes back on a new flow. A subscribed OSC sender's flow is pinned meanwhile.
    static let idle: Double = 2 * OSCSubscriptions.lifetime
    /// Per receiver; two receivers hold at most 2048 of the 10240 descriptors the engine sets at start. A sender that
    /// uses a new port per message at 10 Hz makes 1200 flows in the idle time: the oldest go.
    static let cap = 1024
    /// Only a flow silent this long may go for the cap: a sender that just delivered keeps its flow.
    static let floor: Double = 5
    /// Above this the flow silent longest goes at once, inside the floor too (a source-port flood: a datagram of it can
    /// be lost); pinned flows never. Two receivers: 8192 descriptors at most, under the 10240 the engine sets.
    static let ceiling = 4096

    private let queue: DispatchQueue
    private let logger: Logger
    private let name: String
    /// Nanoseconds; tests set them and `cap` before the receiver starts.
    var idle = UInt64(UDPFlows.idle * 1e9)
    var floor = UInt64(UDPFlows.floor * 1e9)
    var cap = UDPFlows.cap
    var ceiling = UDPFlows.ceiling
    private var timer: DispatchSourceTimer?
    private var lastCapWarning: UInt64 = 0
    /// DMX queue only.
    private(set) var flows: [Flow] = []
    /// Keys of live OSC subscriptions, at most `OSCSubscriptions.limit` and the fixed target (DMX queue only; set from
    /// the feedback queue by a hop when the set changes). Read by the sweep and the cap, not per datagram.
    var pinnedKeys: Set<OSCSubscriptions.Key> = []

    init(queue: DispatchQueue, logger: Logger, name: String) {
        self.queue = queue
        self.logger = logger
        self.name = name
    }

    deinit { timer?.cancel() }

    /// A new flow (DMX queue); `released` runs on the DMX queue when it is cancelled.
    func adopt(_ connection: NWConnection, pinned: Bool = false, key: OSCSubscriptions.Key? = nil, released: (() -> Void)? = nil) -> Flow {
        let flow = Flow(connection, pinned: pinned, key: key, released: released)
        flows.append(flow)
        if flows.count > ceiling { trim() }
        if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let interval = DispatchTimeInterval.nanoseconds(Int(idle / 4))
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [weak self] in self?.sweep() }
            timer.resume()
            self.timer = timer
        }
        return flow
    }

    /// A datagram arrived on `flow` (DMX queue, every datagram).
    func touch(_ flow: Flow) {
        flow.lastSeen = DispatchTime.now().uptimeNanoseconds
        if !flow.read {
            flow.read = true
            if flows.count > cap { trim() }
        }
    }

    /// Cancels the flow and forgets it (DMX queue); a second call does nothing.
    func release(_ flow: Flow) {
        guard cancel(flow) else { return }
        flows.removeAll { $0 === flow }
    }

    /// Cancels the flow but leaves it in `flows` for one `removeAll` after a batch; false if it was cancelled already.
    private func cancel(_ flow: Flow) -> Bool {
        guard flow.live else { return false }
        flow.live = false
        flow.connection.cancel()
        flow.released?()
        return true
    }

    /// Down to `cap` flows, the one silent longest first, as far as flows outside the floor allow; then down to
    /// `ceiling` among every unpinned flow. One pass removes them all.
    private func trim() {
        let now = DispatchTime.now().uptimeNanoseconds
        var count = flows.count
        func oldest(_ eligible: (Flow) -> Bool) -> Flow? {
            var best: Flow?
            for flow in flows where flow.live && !isPinned(flow) && eligible(flow) && flow.lastSeen < best?.lastSeen ?? .max { best = flow }
            return best
        }
        while count > cap, let flow = oldest({ $0.read && now - $0.lastSeen >= self.floor }) {
            _ = cancel(flow)
            count -= 1
        }
        while count > ceiling, let flow = oldest({ _ in true }) {
            _ = cancel(flow)
            count -= 1
        }
        guard count < flows.count else { return }
        if now - lastCapWarning > 60_000_000_000 {
            lastCapWarning = now
            logger.warning("\(name): more than \(cap) UDP senders at once; those silent longest are dropped", metadata: ["dropped": "\(flows.count - count)"])
        }
        flows.removeAll { !$0.live }
    }

    private func isPinned(_ flow: Flow) -> Bool { flow.pinned || flow.key.map(pinnedKeys.contains) == true }

    private func sweep() {
        let now = DispatchTime.now().uptimeNanoseconds
        var swept = false
        for flow in flows where !isPinned(flow) && now - flow.lastSeen > idle { swept = cancel(flow) || swept }
        if swept { flows.removeAll { !$0.live } }
        if flows.count > cap { trim() }
    }

    /// The listener stopped: every flow goes (from any thread).
    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            for flow in flows { _ = cancel(flow) }
            flows = []
        }
    }
}
