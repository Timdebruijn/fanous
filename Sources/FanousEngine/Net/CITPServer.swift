// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import Logging
import Network
import Synchronization

/// CITP/MSEX media-server side (DESIGN.md §16.1): PLoc every 5 s on both multicast groups, one TCP listener
/// (ephemeral port, advertised in PLoc), per connection the MSEX version negotiated from CInf, SInf, layer
/// status at 4 Hz, element libraries (= numbered folders), media elements (= numbered files), JPEG thumbnails
/// from the library cache, video sources (the canvas and each layer) and JPEG streaming frames of a source from the
/// preview path (canvas) or the live thumbnails (layers, B29). Packets come from FanousCore.
public final class CITPServer: @unchecked Sendable {
    public struct LayerInfo: Sendable, Equatable {
        public var index: Int  // 1-based
        public var folder: Int
        public var file: Int
        public var name: String
        public var positionMs: UInt32
        public var lengthMs: UInt32
        public var fps: UInt8
        public var flags: UInt32
        public init(index: Int, folder: Int, file: Int, name: String, positionMs: UInt32, lengthMs: UInt32, fps: UInt8, flags: UInt32) {
            self.index = index
            self.folder = folder
            self.file = file
            self.name = name
            self.positionMs = positionMs
            self.lengthMs = lengthMs
            self.fps = fps
            self.flags = flags
        }
    }

    public struct Providers: Sendable {
        public var layers: @Sendable () -> [LayerInfo]
        public var library: @Sendable () -> LibrarySnapshot
        /// JPEG bytes of a library item's thumbnail by its cache file name.
        public var thumbnail: @Sendable (String) -> [UInt8]?
        /// The latest JPEG (bytes, width, height) of a stream source (`layer(ofSource:)`: the canvas or one layer), nil
        /// when none was produced yet.
        public var frame: @Sendable (UInt16) -> ([UInt8], Int, Int)?
        /// What `VSrc` lists: the canvas (source 0) and one source per layer.
        public var sources: @Sendable () -> [VideoSource]
        /// Render layers (layer stream sources 1…n), without reading the parameters (`layers` does).
        public var layerCount: @Sendable () -> Int
        public init(
            layers: @escaping @Sendable () -> [LayerInfo], library: @escaping @Sendable () -> LibrarySnapshot,
            thumbnail: @escaping @Sendable (String) -> [UInt8]?, frame: @escaping @Sendable (UInt16) -> ([UInt8], Int, Int)?,
            sources: @escaping @Sendable () -> [VideoSource] = { [] }, layerCount: @escaping @Sendable () -> Int = { 0 }
        ) {
            self.layers = layers
            self.library = library
            self.thumbnail = thumbnail
            self.frame = frame
            self.sources = sources
            self.layerCount = layerCount
        }
    }

    public struct Status: Sendable, Equatable {
        public var port: UInt16
        public var clients: [String]
        public var streams: Int
        /// PLoc datagrams dropped because the socket could not take them at once (B123).
        public var beaconsDropped = 0
    }

    public static let productName = "Fanous"
    /// "1.0.0-rc.1" → (1, 0, 0); MSEX has no room for a pre-release tag.
    static let productVersion: (UInt8, UInt8, UInt8) = {
        let parts = FanousVersion.string.split(separator: "-").first?.split(separator: ".").compactMap { UInt8($0) } ?? []
        return (parts.count > 0 ? parts[0] : 0, parts.count > 1 ? parts[1] : 0, parts.count > 2 ? parts[2] : 0)
    }()
    private let name: String
    private let uuid: String
    private let providers: Providers
    private let logger: Logger
    private let queue = DispatchQueue(label: "org.fanous.citp", qos: .utility)
    private var listener: NWListener?
    private var multicastSocket: Int32 = -1
    private var beaconReported = false
    private var lastDropLog = -Double.infinity
    /// `sendto` for the PLoc beacon; tests inject a full send buffer. Set before `start()`.
    var sendDatagram: UDPSend.Function = Darwin.sendto
    private var locationTimer: DispatchSourceTimer?
    private var statusTimer: DispatchSourceTimer?
    private var frameTimer: DispatchSourceTimer?
    private var connections: [ObjectIdentifier: Session] = [:]
    public let status = Mutex(Status(port: 0, clients: [], streams: 0))
    /// Set while any client streams the canvas, so the preview encoder produces JPEGs.
    public let wantsFrames = Atomic<Bool>(false)
    /// Set while any client streams a layer, so the live thumbnails (B29) are drawn.
    public let wantsLayerFrames = Atomic<Bool>(false)

    /// Stream source ids (as `VSrc` lists them): n in 1…`layerCount` is layer n (the 0-based index is returned); 0 and
    /// anything else is the canvas, also for a console that streams without asking for the sources.
    public static func layer(ofSource source: UInt16, layerCount: Int) -> Int? { source >= 1 && Int(source) <= layerCount ? Int(source) - 1 : nil }

    public init(name: String, uuid: String, providers: Providers, logger: Logger) {
        self.name = name
        self.uuid = uuid
        self.providers = providers
        self.logger = logger
    }

    // MARK: Lifecycle

    public func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let port = listener.port?.rawValue ?? 0
                status.withLock { $0.port = port }
                logger.info("CITP listening", metadata: ["tcp": "\(port)"])
                startMulticast()
            case .failed(let error): logger.error("CITP listener failed", metadata: ["error": "\(error)"])
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            let session = Session(connection: connection, server: self)
            connections[ObjectIdentifier(session)] = session
            session.start()
            publishStatus()
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// Layer status (4 Hz) runs while a console has negotiated a version, stream frames (10 Hz) while one streams;
    /// a server nobody talks to has only the 5 s beacon. Server queue only.
    private func updateTimers() {
        let negotiated = connections.values.contains { $0.version != nil }
        let streaming = connections.values.contains { !$0.streams.isEmpty }
        func sync(_ timer: inout DispatchSourceTimer?, wanted: Bool, interval: Double, _ tick: @escaping @Sendable (CITPServer) -> Void) {
            if wanted, timer == nil {
                let new = DispatchSource.makeTimerSource(queue: queue)
                new.schedule(deadline: .now() + interval, repeating: interval)
                new.setEventHandler { [weak self] in if let self { tick(self) } }
                new.resume()
                timer = new
            } else if !wanted, let running = timer {
                running.cancel()
                timer = nil
            }
        }
        sync(&statusTimer, wanted: negotiated, interval: 0.25) { $0.sendLayerStatus() }
        sync(&frameTimer, wanted: streaming, interval: 0.1) { $0.sendFrames() }
    }

    /// Which periodic timers run (tests).
    var activeTimers: (status: Bool, frames: Bool) { queue.sync { (statusTimer != nil, frameTimer != nil) } }

    public func stop() {
        queue.sync {
            locationTimer?.cancel()
            statusTimer?.cancel()
            frameTimer?.cancel()
            statusTimer = nil
            frameTimer = nil
            listener?.cancel()
            if multicastSocket >= 0 { close(multicastSocket) }
            multicastSocket = -1
            for (_, session) in connections { session.connection.cancel() }
            connections.removeAll()
        }
    }

    private func startMulticast() {
        // A plain BSD socket: Network.framework's NWConnection does not deliver to multicast groups (an
        // NWConnectionGroup would, but PLoc is one datagram every 5 s). Default TTL 1 = this subnet. Non-blocking
        // (B123): `stop()` joins this queue, so a send must never wait on the network.
        multicastSocket = UDPSend.socket()
        guard multicastSocket >= 0 else {
            logger.warning("CITP multicast socket failed", metadata: ["errno": "\(errno)"])
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.sendLocation() }
        timer.resume()
        locationTimer = timer
    }

    private func sendLocation() {
        let port = status.withLock { $0.port }
        guard port > 0 else { return }
        let packet = CITPPacket.peerLocation(PeerLocation(listeningTCPPort: port, type: "MediaServer", name: name, state: "Running")).encoded()
        for group in [CITPMulticast.address, CITPMulticast.addressSince2014] {
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            sin.sin_port = CITPMulticast.port.bigEndian
            sin.sin_addr.s_addr = inet_addr(group)
            switch UDPSend.send(multicastSocket, packet, to: sin, using: sendDatagram) {
            case .sent:
                if !beaconReported {
                    beaconReported = true
                    logger.info("CITP PLoc beacon every 5 s", metadata: ["groups": "\(CITPMulticast.address), \(CITPMulticast.addressSince2014)", "tcp": "\(port)"])
                }
            case .dropped:
                let dropped = status.withLock {
                    $0.beaconsDropped += 1
                    return $0.beaconsDropped
                }
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastDropLog >= 60 {
                    lastDropLog = now
                    logger.warning("CITP PLoc beacon dropped (send buffer full)", metadata: ["to": "\(group):\(CITPMulticast.port)", "dropped": "\(dropped)"])
                }
            case .failed(let error):
                if !beaconReported {
                    beaconReported = true
                    logger.warning("CITP PLoc beacon failed (firewall?)", metadata: ["to": "\(group):\(CITPMulticast.port)", "errno": "\(error)", "error": "\(String(cString: strerror(error)))"])
                }
            }
        }
    }

    fileprivate func forget(_ session: Session) {
        connections.removeValue(forKey: ObjectIdentifier(session))
        publishStatus()
    }

    private func publishStatus() {
        updateTimers()
        let clients = connections.values.map(\.label)
        let streams = connections.values.reduce(0) { $0 + $1.streams.count }
        status.withLock {
            $0.clients = clients
            $0.streams = streams
        }
        let sources = connections.values.flatMap { $0.streams.map(\.source) }
        let layerCount = sources.isEmpty ? 0 : providers.layerCount()
        wantsFrames.store(sources.contains { Self.layer(ofSource: $0, layerCount: layerCount) == nil }, ordering: .relaxed)
        wantsLayerFrames.store(sources.contains { Self.layer(ofSource: $0, layerCount: layerCount) != nil }, ordering: .relaxed)
    }

    // MARK: Periodic

    private func sendLayerStatus() {
        let ready = connections.values.filter { $0.version != nil }
        guard !ready.isEmpty else { return }
        let layers = providers.layers().map { l in
            LayerStatus(
                layerNumber: UInt8(clamping: l.index - 1), physicalOutput: 0, mediaLibraryType: 1,
                mediaLibraryID: MSEXLibraryID(level: 1, level1: UInt8(clamping: l.folder)), mediaNumber: UInt8(clamping: l.file), mediaName: l.name,
                mediaPosition: l.positionMs, mediaLength: l.lengthMs, mediaFPS: l.fps, statusFlags: l.flags)
        }
        for session in ready { session.send(.layerStatus(layers)) }
    }

    private func sendFrames() {
        let now = Date().timeIntervalSince1970
        var expired = false
        for session in connections.values where !session.streams.isEmpty {
            let before = session.streams.count
            session.streams.removeAll { $0.expires < now }
            if session.streams.count != before { expired = true }
            for i in session.streams.indices where now - session.streams[i].lastSent >= 1 / Double(max(1, session.streams[i].fps)) {
                guard let (jpeg, width, height) = providers.frame(session.streams[i].source) else { continue }
                session.streams[i].lastSent = now
                session.send(
                    .streamFrame(
                        StreamFrame(
                            version: session.version ?? .v1_0, mediaServerUUID: uuid, sourceIdentifier: session.streams[i].source, frameFormat: "JPEG",
                            frameWidth: UInt16(clamping: width), frameHeight: UInt16(clamping: height), buffer: jpeg)))
            }
        }
        if expired { publishStatus() }  // the status strings are only rebuilt when the set of streams changed
    }

    // MARK: Requests

    fileprivate func handle(_ packet: CITPClientMessage, requestIndex: UInt16, from session: Session) {
        switch packet {
        case .clientInformation(let info):
            let version = info.supportedVersions.filter { $0 <= .v1_2 }.max() ?? .v1_0
            session.version = version
            updateTimers()
            let library = providers.library()
            session.send(
                .serverInformation(
                    ServerInformation(
                        version: version, uuid: uuid, productName: Self.productName, productVersionMajor: Self.productVersion.0, productVersionMinor: Self.productVersion.1,
                        productVersionBugfix: Self.productVersion.2,
                        supportedVersions: [.v1_0, .v1_1, .v1_2], supportedLibraryTypes: 1 << 0, thumbnailFormats: ["JPEG", "RGB8"], streamFormats: ["JPEG"],
                        layerDMXSources: providers.layers().map { "Layer \($0.index)" })), requestIndex: requestIndex)
            logger.info("CITP client", metadata: ["peer": "\(session.connection.endpoint)", "msex": "\(version.major).\(version.minor)", "folders": "\(library.folders.count)"])
        case .getElementLibraryInformation(let request):
            let library = providers.library()
            let folders = library.folders.filter { $0.number != nil && (request.libraryNumbers.isEmpty || request.libraryNumbers.contains(UInt8(clamping: $0.number!))) }
            let libraries = folders.map { folder in
                ElementLibrary(
                    id: MSEXLibraryID(level: 1, level1: UInt8(clamping: folder.number ?? 0)), serialNumber: UInt32(folder.items.count), dmxRangeMin: UInt8(clamping: folder.number ?? 0),
                    dmxRangeMax: UInt8(clamping: folder.number ?? 0), name: folder.name, libraryCount: 0, elementCount: UInt16(folder.items.filter { $0.file != nil }.count))
            }
            session.send(.elementLibraryInformation(ElementLibraryInformation(version: session.version ?? .v1_0, libraryType: 1, libraries: libraries)), requestIndex: requestIndex)
        case .getElementInformation(let request):
            let library = providers.library()
            let folder = library.folders.first { $0.number == Int(request.libraryID.level1) }
            let items = (folder?.items ?? []).filter { $0.file != nil && (request.elementNumbers.isEmpty || request.elementNumbers.contains(UInt8(clamping: $0.file!))) }
            let elements = items.map { item in
                let meta = item.metadata
                return MediaElement(
                    number: UInt8(clamping: item.file ?? 0), serialNumber: 0, dmxRangeMin: UInt8(clamping: item.file ?? 0), dmxRangeMax: UInt8(clamping: item.file ?? 0),
                    name: item.name, versionTimestamp: 0, width: UInt16(clamping: meta?.width ?? 0), height: UInt16(clamping: meta?.height ?? 0),
                    length: UInt32(clamping: meta?.frameCount ?? 0), fps: UInt8(clamping: Int((meta?.frameRate ?? 0).rounded())))
            }
            session.send(.mediaElementInformation(MediaElementInformation(version: session.version ?? .v1_0, libraryID: request.libraryID, elements: elements)), requestIndex: requestIndex)
        case .getElementThumbnail(let request):
            let library = providers.library()
            let folder = library.folders.first { $0.number == Int(request.libraryID.level1) }
            for item in folder?.items ?? [] where item.file != nil && (request.elementNumbers.isEmpty || request.elementNumbers.contains(UInt8(clamping: item.file!))) {
                guard let name = item.thumbnail, let jpeg = providers.thumbnail(name) else { continue }
                session.send(
                    .elementThumbnail(
                        ElementThumbnail(
                            version: session.version ?? .v1_0, libraryType: 1, libraryID: request.libraryID, elementNumber: UInt8(clamping: item.file!),
                            format: "JPEG", width: UInt16(clamping: Thumbnailer.width), height: UInt16(clamping: item.metadata.map { Thumbnailer.width * $0.height / max(1, $0.width) } ?? 180),
                            buffer: jpeg)), requestIndex: requestIndex)
            }
        case .getVideoSources:
            session.send(.videoSources(providers.sources()), requestIndex: requestIndex)
        case .requestStream(let request):
            session.streams.removeAll { $0.source == request.sourceIdentifier }
            if request.fps > 0 {
                session.streams.append(Session.Stream(source: request.sourceIdentifier, fps: min(10, request.fps), expires: Date().timeIntervalSince1970 + Double(max(1, request.timeout)), lastSent: 0))
            }
            publishStatus()
        case .peerName:
            break
        case .unknown(let contentType, let body):
            // an MSEX message we do not model: the Nack names its MSEX content type (bytes 2..<6 after the version)
            let received = contentType == "MSEX" && body.count >= 6 ? String(decoding: body[2..<6], as: UTF8.self) : contentType
            session.send(.nack(Nack(version: session.version ?? .v1_0, receivedContentType: received)), requestIndex: requestIndex)
        }
    }

    /// One TCP peer: CITP framing on the server queue; the negotiated MSEX version; its stream subscriptions.
    final class Session: @unchecked Sendable {
        struct Stream {
            var source: UInt16
            var fps: UInt8
            var expires: TimeInterval
            var lastSent: TimeInterval
        }
        let connection: NWConnection
        /// The peer as shown in the status, built once.
        let label: String
        private unowned let server: CITPServer
        var version: MSEXVersion?
        var streams: [Stream] = []
        private var buffer: [UInt8] = []

        init(connection: NWConnection, server: CITPServer) {
            self.connection = connection
            label = "\(connection.endpoint)"
            self.server = server
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .failed = state { connection.cancel() }
                if case .cancelled = state { server.forget(self) }
            }
            connection.start(queue: server.queue)
            receive()
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
                if let data { buffer.append(contentsOf: data) }
                process()
                if isComplete || error != nil { return connection.cancel() }
                receive()
            }
        }

        private func process() {
            while buffer.count >= CITPHeader.size {
                guard let header = try? CITPHeader.parse(buffer) else {
                    server.logger.warning("CITP: bad header; closing", metadata: ["peer": "\(connection.endpoint)"])
                    connection.cancel()
                    return
                }
                let size = Int(header.messageSize)
                guard size >= CITPHeader.size, size <= 1 << 24 else {
                    connection.cancel()
                    return
                }
                guard buffer.count >= size else { return }
                let message = Array(buffer[0..<size])
                buffer.removeFirst(size)
                do {
                    let packet = try CITPClientMessage.parse(message)
                    server.handle(packet, requestIndex: header.requestIndex, from: self)
                } catch {
                    server.logger.debug("CITP: unparsable \(header.contentType): \(error)")
                }
            }
        }

        func send(_ packet: CITPPacket, requestIndex: UInt16 = 0) {
            let bytes = packet.encoded(version: version ?? .v1_0, requestIndex: requestIndex)
            connection.send(content: Data(bytes), completion: .contentProcessed { _ in })
        }
    }
}
