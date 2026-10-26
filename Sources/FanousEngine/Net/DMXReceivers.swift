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

/// sACN on UDP 5568: one multicast group per interface the universes ask for ("any": the default-route interface),
/// plus unicast on the same port. Changing one interface's universes recreates only that group (B28).
public final class SACNReceiver: @unchecked Sendable {
    private let store: DMXStore
    private let logger: Logger
    private let port: UInt16
    /// Interface ("any" or a BSD name / address) → joined universes and the group; touched on the DMX queue.
    private var groups: [String: (universes: [Int], group: NWConnectionGroup?)] = [:]
    private var wanted: [String: [Int]] = [:]
    private let monitor = NWPathMonitor()

    public init(store: DMXStore, logger: Logger, port: UInt16 = SACN.port) {
        self.store = store
        self.logger = logger
        self.port = port
    }

    /// Joins `groups` (interface → universes). There is always a group on any interface (universe 1 when nothing asks
    /// for one), so unicast keeps working. Interfaces not present yet are joined when they appear.
    public func start(groups: [String: [Int]]) {
        monitor.pathUpdateHandler = { [weak self] _ in self?.apply() }
        monitor.start(queue: store.queue)
        update(groups: groups)
    }

    /// Patch or universe settings changed; groups whose universes stay the same keep running.
    public func update(groups: [String: [Int]]) {
        store.queue.async { [self] in
            wanted = groups
            if wanted[UniverseSettings.anyInterface] == nil { wanted[UniverseSettings.anyInterface] = [1] }
            apply()
        }
    }

    /// On the DMX queue.
    private func apply() {
        for (interface, entry) in groups where wanted[interface] == nil {
            entry.group?.cancel()
            groups[interface] = nil
        }
        for (interface, universes) in wanted where groups[interface]?.universes != universes || groups[interface]?.group == nil {
            groups[interface]?.group?.cancel()
            groups[interface] = (universes, makeGroup(universes: universes, interface: interface))
        }
    }

    private func makeGroup(universes: [Int], interface: String) -> NWConnectionGroup? {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        if interface != UniverseSettings.anyInterface {
            // a name, or an address: the interface that carries it
            let name = store.interfaceList().first { $0.name == interface || $0.address == interface }?.name ?? interface
            guard let nw = monitor.currentPath.availableInterfaces.first(where: { $0.name == name }) else {
                logger.warning("sACN interface not present; joining when it appears", metadata: ["interface": "\(interface)"])
                return nil
            }
            parameters.requiredInterface = nw
        }
        do {
            let endpoints = universes.map { NWEndpoint.hostPort(host: NWEndpoint.Host(SACN.multicastAddress(universe: $0)), port: NWEndpoint.Port(rawValue: port)!) }
            let group = NWConnectionGroup(with: try NWMulticastGroup(for: endpoints, disableUnicast: false), using: parameters)
            group.stateUpdateHandler = { [logger] state in
                switch state {
                case .ready: logger.info("sACN listening", metadata: ["universes": "\(universes)", "interface": "\(interface)"])
                case .failed(let error): logger.error("sACN group failed", metadata: ["error": "\(error)", "interface": "\(interface)"])
                default: break
                }
            }
            group.setReceiveHandler(maximumMessageSize: 1500, rejectOversizedMessages: true) { [store] message, content, _ in
                guard let content, case .data(let packet)? = try? SACN.parse(Array(content)) else { return }
                store.receive(sacn: packet, from: message.remoteEndpoint.map(ArtNetReceiver.host(of:)) ?? "")
            }
            group.start(queue: store.queue)
            return group
        } catch {
            logger.error("sACN join failed", metadata: ["error": "\(error)", "interface": "\(interface)"])
            return nil
        }
    }

    public func stop() {
        monitor.cancel()
        store.queue.async { [self] in
            wanted = [:]
            apply()
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
