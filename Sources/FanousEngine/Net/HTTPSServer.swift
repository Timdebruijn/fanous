// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CryptoKit
import dnssd
import Foundation
import FanousCore
import Logging
import Network
import Synchronization

/// HTTPS/1.1 server on Network.framework. One listener; each connection parses request heads with
/// FanousCore's parser. Small bodies are buffered, large ones (uploads) streamed to a file, and an
/// upgrade request hands the connection to a `WebSocketSession` (DESIGN.md §11.1: one port for all).
public final class HTTPSServer: @unchecked Sendable {
    public typealias Route = @Sendable (HTTPRequest) -> HTTPResponse?
    /// A large request body (an upload): `sink` names where to stream it, an existing file it created for this request
    /// alone (nil = refuse the body), called with the request head only; `route` runs once the body is complete, with the
    /// request head and the file it was written to.
    public typealias Upload = (sink: @Sendable (HTTPRequest) -> URL?, route: @Sendable (HTTPRequest, URL) -> HTTPResponse)
    /// Decides whether a WebSocket upgrade request gets a session; nil refuses it (404).
    public typealias UpgradeRoute = @Sendable (HTTPRequest) -> StateServer.Connection?
    /// Bodies up to this size are buffered and handed to the route in `HTTPRequest.body`.
    public static let maxInlineBody = 1 << 20
    nonisolated(unsafe) public var upload: Upload?
    nonisolated(unsafe) public var upgradeRoute: UpgradeRoute?
    /// The port actually bound (differs from `port` when 0 was requested); set once the listener is ready.
    nonisolated(unsafe) public private(set) var boundPort: UInt16?

    /// How many connections an address may hold and how long a connection may wait on its client (B269). Tests shorten
    /// them; set before `start()`.
    struct Limits {
        /// Connections one network address holds at once; the next one is closed at accept and logged. Loopback is not
        /// counted, so the shell's `/healthz` and a UI on this Mac are never refused.
        /// One browser holds up to 6 HTTP connections plus a WebSocket per tab, and every device behind a NAT, a VPN or
        /// a reverse proxy shares one address; the global bound is the descriptor limit (B268).
        var perAddress = 64
        var countsLoopback = false
        /// The longest a connection waits, while the server is ready to read, for the next bytes of a request (its
        /// head, each chunk of its body), for the client to take the next slice of a response, or idle between requests.
        var request = 30.0
        /// From accept to the end of the TLS handshake, after which `request` counts. Tests keep it long while they
        /// shorten the others: a starved test runner can take seconds over a handshake.
        var handshake = 30.0
        /// From the upgrade to an accepted `hello`.
        var hello = 10.0
        /// A WebSocket is pinged this often (a browser answers by itself) and closed once nothing came from it for `silent`.
        var ping = 15.0
        var silent = 45.0
        /// How often a connection checks its deadlines.
        var tick = 1.0
    }
    nonisolated(unsafe) var limits = Limits()
    /// Open connections per address (loopback included, though not capped).
    private let open = Mutex<[String: Int]>([:])
    /// Refusals since start, and those since the last log line.
    private let refusals = Mutex((total: 0, log: RefusalLog()))
    /// Connections refused at the cap since start (`/metrics`).
    public var refusedConnections: Int { refusals.withLock { $0.total } }
    /// Connections open now (tests).
    var openConnections: Int { open.withLock { $0.values.reduce(0, +) } }

    /// Made again when it fails (B272).
    private var listener: RecoveringListener!
    /// `_fanous._tcp`, carried by the listener (`bonjour`).
    private var fanousService: NWListener.Service?
    /// `_https._tcp` for the same port: an NWListener carries one service, and a second NWListener on the port
    /// fails with EADDRINUSE on macOS 27 despite `allowLocalEndpointReuse`, so this one is registered with dns_sd.
    private var httpsService: NWListener.Service?
    private var httpsRegistration: DNSServiceRef?
    private let loopbackOnly: Bool
    private let queue = DispatchQueue(label: "org.fanous.https", qos: .userInitiated)
    fileprivate let logger: Logger
    private let webRoot: URL
    private let route: Route
    public let port: UInt16

    /// `loopbackOnly`: bound to 127.0.0.1, unreachable from the network (`--no-network`).
    public init(port: UInt16, identity: TLSIdentity, webRoot: URL, loopbackOnly: Bool = false, logger: Logger, route: @escaping Route) throws {
        self.port = port
        self.logger = logger
        self.webRoot = webRoot.standardizedFileURL
        self.route = route
        self.loopbackOnly = loopbackOnly
        let tls = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity.identity) else {
            throw TLSIdentityError.security(errSecInternalError, "sec_identity_create")
        }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw TLSIdentityError.security(errSecParam, "port") }
        if loopbackOnly { parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort) }
        let make = { [weak self] () throws -> NWListener in
            let listener = try loopbackOnly ? NWListener(using: parameters) : NWListener(using: parameters, on: nwPort)
            listener.service = self?.fanousService
            listener.newConnectionHandler = { [weak self] connection in
                // every listener made again counts against the same per-address table (B269)
                let peer = Self.peer(connection.endpoint)
                guard let self, admit(peer) else { return connection.cancel() }
                ClientConnection(connection, server: self, peer: peer.host).start()
            }
            return listener
        }
        _ = try make()  // invalid parameters throw here, as before, not at the first attempt
        listener = RecoveringListener(name: "HTTPS listener", queue: queue, logger: logger, make: make) { [weak self, logger, port] state, listener in
            switch state {
            case .ready:
                self?.boundPort = listener.port?.rawValue ?? port
                logger.info("HTTPS listening", metadata: ["port": "\(self?.boundPort ?? port)"])
                self?.registerHTTPS()
            case .failed, .waiting: self?.deregisterHTTPS()
            case .cancelled: logger.info("HTTPS listener stopped")
            default: break
            }
        }
    }

    /// The Bonjour services for `name` on `port`: `_fanous._tcp` for Fanous clients, `_https._tcp` so generic
    /// Bonjour browsers find `https://<host>.local:<port>` (DESIGN.md §11.1).
    static func services(name: String, port: UInt16) -> [NWListener.Service] {
        [NWListener.Service(name: name, type: "_fanous._tcp", txtRecord: NWTXTRecord(["port": "\(port)", "v": FanousVersion.string])),
         NWListener.Service(name: name, type: "_https._tcp", txtRecord: NWTXTRecord(["path": "/", "port": "\(port)"]))]
    }

    /// Advertises both services once `start()` runs. Does nothing on a loopback-only server (`--no-network`) or on
    /// port 0 (the advertised port would be wrong). Call before `start()`.
    public func bonjour(name: String) {
        guard !loopbackOnly, port != 0 else { return }
        let services = Self.services(name: name, port: port)
        fanousService = services[0]
        httpsService = services[1]
    }

    /// What `start()` advertises (tests).
    var advertisedServices: [NWListener.Service] { [fanousService, httpsService].compactMap { $0 } }

    public func start() {
        do { try listener.start() } catch { logger.error("HTTPS listener failed", metadata: ["error": "\(error)"]) }
    }

    /// Synchronous, so a start right after (Restart Engine) does not collide with its own old `_https._tcp` name.
    public func stop() {
        listener.stop()
        queue.sync { deregisterHTTPS() }
    }

    /// On `queue`, while the listener is ready, like the listener's own `_fanous._tcp`. Advertisement only, no
    /// socket: connections all arrive at `listener`. No callback (mDNSResponder renames on a conflict by itself).
    private func registerHTTPS() {
        guard let service = httpsService, httpsRegistration == nil else { return }
        let txt = service.txtRecordObject?.data ?? Data()
        let error = txt.withUnsafeBytes { bytes in
            DNSServiceRegister(&httpsRegistration, 0, 0, service.name, service.type, nil, nil, port.bigEndian,
                               UInt16(bytes.count), bytes.baseAddress, nil, nil)
        }
        if error != kDNSServiceErr_NoError {
            httpsRegistration = nil
            logger.error("Bonjour _https._tcp registration failed", metadata: ["error": "\(error)"])
        }
    }

    private func deregisterHTTPS() {
        if let registration = httpsRegistration { DNSServiceRefDeallocate(registration) }
        httpsRegistration = nil
    }

    /// The address of a connection's client, and whether it is this Mac.
    static func peer(_ endpoint: NWEndpoint) -> (host: String, loopback: Bool) {
        guard case .hostPort(let host, _) = endpoint else { return ("\(endpoint)", false) }
        switch host {
        case .ipv4(let address): return ("\(host)", address.isLoopback)
        case .ipv6(let address): return ("\(host)", address.isLoopback || address.asIPv4?.isLoopback == true)
        default: return ("\(host)", false)
        }
    }

    /// Counts a new connection against its address; false when the address already holds `limits.perAddress`.
    private func admit(_ peer: (host: String, loopback: Bool)) -> Bool {
        let limits = limits
        let counted = !peer.loopback || limits.countsLoopback
        let admitted = open.withLock { open in
            if counted, open[peer.host, default: 0] >= limits.perAddress { return false }
            open[peer.host, default: 0] += 1
            return true
        }
        if admitted { return true }
        let refused = refusals.withLock { r -> Int? in
            r.total += 1
            return r.log.add()
        }
        if let refused { RefusalLog.warn(logger, "HTTPS", peer: peer.host, limit: limits.perAddress, refused: refused) }
        return false
    }

    /// The end of a connection `admit` let in.
    fileprivate func release(_ host: String) {
        open.withLock { open in
            open[host, default: 1] -= 1
            if open[host] == 0 { open[host] = nil }
        }
    }

    fileprivate func respond(to request: HTTPRequest) -> HTTPResponse {
        var response = route(request) ?? staticFile(for: request)
        response.headers.append(HTTPHeader("Server", "fanousd/\(FanousVersion.string)"))
        response.headers.append(HTTPHeader("X-Content-Type-Options", "nosniff"))
        return response
    }

    private func staticFile(for request: HTTPRequest) -> HTTPResponse {
        guard request.method == "GET" || request.method == "HEAD" else {
            return HTTPResponse(status: 405, headers: [HTTPHeader("Allow", "GET, HEAD")])
        }
        guard let relative = StaticFiles.relativePath(forRequestPath: request.path) else { return .text(404, "not found") }
        let file = webRoot.appending(path: relative).standardizedFileURL
        guard file.path.hasPrefix(webRoot.path + "/"),
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true,
            let data = try? Data(contentsOf: file)
        else { return .text(404, "not found") }
        return HTTPResponse(
            status: 200,
            headers: [
                HTTPHeader("Content-Type", MIMEType.forPath(relative)),
                // index.html no-store: the shell's first request carries its token in the query, and a cached copy would keep
                // that address on disk (WebKit's network cache)
                HTTPHeader("Cache-Control", relative == "index.html" ? "no-store" : "max-age=3600"),
                HTTPHeader(
                    "Content-Security-Policy",
                    "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'"),
            ],
            body: Array(data))
    }

    fileprivate func log(_ request: HTTPRequest, _ response: HTTPResponse) {
        logger.debug("\(request.method) \(request.path) → \(response.status)")  // the path only: the web UI takes a token as ?token=
    }
}

/// All state is touched only on `queue` (Network.framework delivers there).
private final class ClientConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let server: HTTPSServer
    private let queue = DispatchQueue(label: "org.fanous.https.client", qos: .userInitiated)  // the listener's class: an iPad's GO arrives here (B318)
    private var buffer: [UInt8] = []
    /// An upload in progress: body bytes go to the file until `remaining` reaches 0.
    private var upload: (request: HTTPRequest, file: URL, handle: FileHandle, remaining: Int)?
    /// Set after a successful upgrade: every further byte is a WebSocket frame.
    private var websocket: WebSocketSession?
    /// A response the transport has not taken yet: no request is parsed and no receive armed until it has.
    private var sending = false
    /// The peer finished sending, or the receive failed: the connection ends once the buffer is served.
    private var receiveEnded = false
    /// The client's address, as `HTTPSServer.admit` counted it.
    private let remoteAddress: String
    /// After an upgrade: the state connection, which knows whether `hello` was accepted.
    private var handler: StateServer.Connection?
    /// Checks the deadlines (B269).
    private var timer: DispatchSourceTimer?
    /// Uptimes of the last time a receive was armed (so a deadline counts only time the server was ready to read and
    /// the client sent nothing, not a slow upload write or command before it), of the last slice of a response the
    /// transport took (or the start of a response), of the upgrade and of the last ping.
    private var lastReceived = 0.0
    private var lastSent = 0.0
    private var upgraded = 0.0
    private var lastPing = 0.0
    /// The connection is ready (TLS done); before, `limits.handshake` applies instead of `limits.request`.
    private var handshakeDone = false
    /// A response goes out in slices of this size, so each slice the client takes counts as progress.
    static let slice = 256 * 1024

    init(_ connection: NWConnection, server: HTTPSServer, peer: String) {
        self.connection = connection
        self.server = server
        remoteAddress = peer
    }

    /// Called on the listener's queue; the rest runs on the connection's own queue, where the timer reads the clocks.
    func start() { queue.async { [self] in begin() } }

    private func begin() {
        // strong: this handler and the timer keep the object until `.cancelled`, which every end of the connection
        // reaches (a deadline cancels a connection nothing else ends), so the address's count is always released
        connection.stateUpdateHandler = { [self] state in
            if case .failed = state { connection.cancel() }
            if case .ready = state {
                // TLS is done: from here `request` counts, from now (the handshake had its own deadline)
                handshakeDone = true
                lastReceived = Self.now
            }
            if case .cancelled = state {
                connection.stateUpdateHandler = nil
                websocket?.connectionDidEnd()
                websocket = nil
                abandonUpload()
                stopTimer()
                server.release(remoteAddress)
            }
        }
        lastSent = Self.now
        // a leeway, so the kernel can coalesce the timers of thousands of connections
        let tick = server.limits.tick
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + tick, repeating: tick, leeway: .milliseconds(Int(min(tick, 0.25) * 1000)))
        timer.setEventHandler { [self] in checkDeadlines() }
        timer.resume()
        self.timer = timer
        connection.start(queue: queue)
        receive()
    }

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    /// Ends a connection whose client stopped making progress: before an upgrade no part of a request arrived and no
    /// slice of a response left within `request`; after it no `hello` within `hello`, or nothing at all (not even a pong)
    /// within `silent`. The cancel ends the pending receive or send, whose completion cleans up as for any other end.
    private func checkDeadlines() {
        let limits = server.limits
        let now = Self.now
        if let websocket {
            let reason: String
            if handler?.isAuthenticated == false, now - upgraded > limits.hello {
                reason = "no hello"
            } else if now - lastReceived > limits.silent {
                reason = "client silent"
            } else {
                if now - lastPing >= limits.ping {
                    lastPing = now
                    websocket.ping()
                }
                return
            }
            server.logger.info("WebSocket closed: \(reason)", metadata: ["peer": "\(remoteAddress)", "seconds": "\(Int(now - max(lastReceived, upgraded)))"])
        } else {
            guard now - max(lastReceived, lastSent) > (handshakeDone ? limits.request : limits.handshake) else { return }
            if upload != nil {
                abandonUpload(silentFor: Int(now - lastReceived))
            } else {
                server.logger.debug("HTTPS connection closed: no progress", metadata: ["peer": "\(remoteAddress)"])
            }
        }
        stopTimer()
        connection.cancel()
    }

    private func receive() {
        lastReceived = Self.now
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty { buffer.append(contentsOf: data) }
            receiveEnded = isComplete || error != nil
            serve()
        }
    }

    /// Handles the next request in the buffer, then waits for its response to leave, reads more, or ends the connection.
    private func serve() {
        guard process(), !sending else { return }
        if receiveEnded {
            websocket?.connectionDidEnd()
            abandonUpload()
            connection.cancel()
            return
        }
        receive()
    }

    /// Handles at most one complete request: the next waits until the transport has taken its response (B270), so a
    /// client that pipelines requests and never reads holds one response here, not one per request. Returns false once
    /// the connection is being closed.
    private func process() -> Bool {
        // a session that closed while the 101 was still leaving gets no frame that came after its close
        if let websocket { return !websocket.isClosed && websocket.feed(&buffer) }
        if upload != nil { return drainUpload() }
        let parsed: (request: HTTPRequest, headLength: Int)?
        do {
            parsed = try HTTPRequest.parse(buffer)
        } catch {
            send(.text(400, "bad request"), includeBody: true, close: true)
            return false
        }
        guard let (head, headLength) = parsed else { return true }
        var request = head
        request.remoteAddress = remoteAddress
        if WebSocketHandshake.isUpgrade(request) {
            buffer.removeFirst(headLength)
            guard let handler = server.upgradeRoute?(request), let response = WebSocketHandshake.response(for: request) else {
                send(.text(404, "no such socket"), includeBody: true, close: true)
                return false
            }
            server.log(request, response)
            send(response, includeBody: false, close: false)
            self.handler = handler
            upgraded = Self.now
            lastPing = upgraded
            let session = WebSocketSession(connection: connection, remoteAddress: request.remoteAddress, handler: handler)
            websocket = session
            session.opened()
            return session.feed(&buffer)
        }
        if request.contentLength > HTTPSServer.maxInlineBody {
            // large body: stream it to the file the upload sink names, or refuse it
            let file = server.upload?.sink(request)
            guard let file, let handle = try? FileHandle(forWritingTo: file) else {
                if let file { try? FileManager.default.removeItem(at: file) }
                send(.text(413, "body too large"), includeBody: true, close: true)
                return false
            }
            buffer.removeFirst(headLength)
            upload = (request, file, handle, request.contentLength)
            return drainUpload()
        }
        let total = headLength + request.contentLength
        guard buffer.count >= total else { return true }  // body still arriving
        request.body = Array(buffer[headLength..<total])
        buffer.removeFirst(total)
        let response = server.respond(to: request)
        server.log(request, response)
        send(response, includeBody: request.method != "HEAD", close: request.wantsClose)
        return !request.wantsClose
    }

    /// Moves buffered bytes into the upload file; finishes the request when the body is complete.
    private func drainUpload() -> Bool {
        guard var current = upload else { return true }
        let take = min(current.remaining, buffer.count)
        if take > 0 {
            do {
                try current.handle.write(contentsOf: Data(buffer[0..<take]))
            } catch {
                try? current.handle.close()
                try? FileManager.default.removeItem(at: current.file)
                upload = nil
                send(.text(500, "cannot write upload"), includeBody: true, close: true)
                return false
            }
            buffer.removeFirst(take)
            current.remaining -= take
            upload = current
        }
        guard current.remaining == 0 else { return true }
        try? current.handle.close()
        upload = nil
        let response = server.upload?.route(current.request, current.file) ?? .text(500, "no upload route")
        server.log(current.request, response)
        send(response, includeBody: true, close: current.request.wantsClose)
        return !current.request.wantsClose
    }

    /// A client that went away mid-upload leaves no partial file in `_incoming` (B156). A finished upload cleared
    /// `upload` before its response was sent, so the end of the connection that follows never gets here with it.
    /// `silentFor`: the request deadline cut it (B269), logged as such; the end that follows finds `upload` cleared.
    private func abandonUpload(silentFor seconds: Int? = nil) {
        guard let current = upload else { return }
        upload = nil
        try? current.handle.close()
        try? FileManager.default.removeItem(at: current.file)
        var metadata: Logger.Metadata = [
            "peer": "\(remoteAddress)", "file": "\(current.file.lastPathComponent)", "received": "\(current.request.contentLength - current.remaining)",
        ]
        if let seconds {
            metadata["seconds"] = "\(seconds)"
            server.logger.warning("upload cut: no data from the client; partial file removed", metadata: metadata)
        } else {
            server.logger.info("upload abandoned by the client", metadata: metadata)
        }
    }

    private func send(_ response: HTTPResponse, includeBody: Bool, close: Bool) {
        sending = true
        send(Data(response.serialized(includeBody: includeBody)), close: close)
    }

    /// One slice at a time: each slice the transport takes is progress, so a long response to a slow client is not cut
    /// by the deadline, and a client that takes nothing more is (B269).
    private func send(_ bytes: Data, close: Bool) {
        lastSent = Self.now
        let slice = bytes.prefix(Self.slice)
        connection.send(
            content: slice,
            completion: .contentProcessed { [self] error in
                if error == nil, slice.count < bytes.count { return send(bytes.dropFirst(slice.count), close: close) }
                lastSent = Self.now
                if close { return connection.cancel() }
                sending = false
                if error != nil {  // the connection is gone: answer nothing more, end it
                    buffer.removeAll()
                    receiveEnded = true
                }
                serve()
            })
    }
}

extension WebSocketHandshake {
    private static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// `Sec-WebSocket-Accept` for a client's `Sec-WebSocket-Key` (RFC 6455 §4.2.2). SHA-1 is a protocol constant here.
    static func acceptKey(for clientKey: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((clientKey + guid).utf8))).base64EncodedString()
    }

    /// The 101 response, or nil when `request` is not a WebSocket upgrade.
    static func response(for request: HTTPRequest) -> HTTPResponse? {
        guard isUpgrade(request), let key = request.header("Sec-WebSocket-Key") else { return nil }
        return HTTPResponse(
            status: 101,
            headers: [
                HTTPHeader("Upgrade", "websocket"),
                HTTPHeader("Connection", "Upgrade"),
                HTTPHeader("Sec-WebSocket-Accept", acceptKey(for: key)),
            ])
    }
}

/// Connections refused at a per-address cap (HTTPS, CITP; B269): at most one log line a minute, with the count since the
/// last line.
struct RefusalLog {
    private var count = 0
    private var logged = -Double.infinity

    /// Counts one refusal; the count to log when a line is due.
    mutating func add(now: Double = ProcessInfo.processInfo.systemUptime) -> Int? {
        count += 1
        guard now - logged >= 60 else { return nil }
        defer { (count, logged) = (0, now) }
        return count
    }

    /// `peer` is the address refused as the line is written; `refused` counts every address since the last line.
    static func warn(_ logger: Logger, _ server: String, peer: String, limit: Int, refused: Int) {
        logger.warning(
            "\(server) connection refused: too many open from one address (one line a minute, refused counts every address)",
            metadata: ["peer": "\(peer)", "limit": "\(limit)", "refused": "\(refused)"])
    }
}
