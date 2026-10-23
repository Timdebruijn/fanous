// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import LanthornCore
import Logging
import Network

/// HTTPS/1.1 server on Network.framework. One listener; each connection parses request heads with
/// LanthornCore's parser. Small bodies are buffered, large ones (uploads) streamed to a file, and an
/// upgrade request hands the connection to a `WebSocketSession` (DESIGN.md §11.1: one port for all).
public final class HTTPSServer: @unchecked Sendable {
    public typealias Route = @Sendable (HTTPRequest) -> HTTPResponse?
    /// Where to stream a large request body (an upload); nil = refuse the body. Called with the request head only.
    public typealias UploadSink = @Sendable (HTTPRequest) -> URL?
    /// Called once a streamed body is complete, with the request head and the file it was written to.
    public typealias UploadRoute = @Sendable (HTTPRequest, URL) -> HTTPResponse
    /// Decides whether a WebSocket upgrade request gets a session; nil refuses it (404).
    public typealias UpgradeRoute = @Sendable (HTTPRequest) -> WebSocketHandler?
    /// Bodies up to this size are buffered and handed to the route in `HTTPRequest.body`.
    public static let maxInlineBody = 1 << 20
    nonisolated(unsafe) public var uploadSink: UploadSink?
    nonisolated(unsafe) public var uploadRoute: UploadRoute?
    nonisolated(unsafe) public var upgradeRoute: UpgradeRoute?
    /// The port actually bound (differs from `port` when 0 was requested); set once the listener is ready.
    nonisolated(unsafe) public private(set) var boundPort: UInt16?

    private let listener: NWListener
    private let queue = DispatchQueue(label: "org.lanthorn.https", qos: .userInitiated)
    private let logger: Logger
    private let webRoot: URL
    private let route: Route
    public let port: UInt16

    public init(port: UInt16, identity: TLSIdentity, webRoot: URL, logger: Logger, route: @escaping Route) throws {
        self.port = port
        self.logger = logger
        self.webRoot = webRoot.standardizedFileURL
        self.route = route
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
        listener = try NWListener(using: parameters, on: nwPort)
    }

    public func start() {
        listener.stateUpdateHandler = { [weak self, logger, port] state in
            switch state {
            case .ready:
                self?.boundPort = self?.listener.port?.rawValue ?? port
                logger.info("HTTPS listening", metadata: ["port": "\(self?.boundPort ?? port)"])
            case .failed(let error): logger.error("HTTPS listener failed", metadata: ["error": "\(error)"])
            case .cancelled: logger.info("HTTPS listener stopped")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            ClientConnection(connection, server: self).start()
        }
        listener.start(queue: queue)
    }

    public func stop() { listener.cancel() }

    fileprivate func respond(to request: HTTPRequest) -> HTTPResponse {
        var response = route(request) ?? staticFile(for: request)
        response.headers.append(HTTPHeader("Server", "lanthornd/\(LanthornVersion.string)"))
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
                HTTPHeader("Cache-Control", relative == "index.html" ? "no-cache" : "max-age=3600"),
                HTTPHeader(
                    "Content-Security-Policy",
                    "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'"),
            ],
            body: Array(data))
    }

    fileprivate func log(_ request: HTTPRequest, _ response: HTTPResponse) {
        logger.debug("\(request.method) \(request.target) → \(response.status)")
    }
}

/// All state is touched only on `queue` (Network.framework delivers there).
private final class ClientConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let server: HTTPSServer
    private let queue = DispatchQueue(label: "org.lanthorn.https.client")
    private var buffer: [UInt8] = []
    /// An upload in progress: body bytes go to the file until `remaining` reaches 0.
    private var upload: (request: HTTPRequest, file: URL, handle: FileHandle, remaining: Int)?
    /// Set after a successful upgrade: every further byte is a WebSocket frame.
    private var websocket: WebSocketSession?
    private var remoteAddress: String {
        if case .hostPort(let host, _) = connection.endpoint { return "\(host)" }
        return "\(connection.endpoint)"
    }

    init(_ connection: NWConnection, server: HTTPSServer) {
        self.connection = connection
        self.server = server
    }

    func start() {
        connection.stateUpdateHandler = { [weak self, connection] state in
            if case .failed = state { connection.cancel() }
            if case .cancelled = state {
                connection.stateUpdateHandler = nil
                self?.websocket?.connectionDidEnd()
                self?.websocket = nil
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                buffer.append(contentsOf: data)
                guard process() else { return }
            }
            if isComplete || error != nil {
                websocket?.connectionDidEnd()
                connection.cancel()
                return
            }
            receive()
        }
    }

    /// Handles every complete request in the buffer. Returns false once the connection is being closed.
    private func process() -> Bool {
        while true {
            if let websocket { return websocket.feed(&buffer) }
            if upload != nil { return drainUpload() }
            let parsed: (request: HTTPRequest, headLength: Int)?
            do {
                parsed = try HTTPRequest.parse(buffer)
            } catch {
                send(.text(400, "bad request"), includeBody: true, close: true)
                return false
            }
            guard var (request, headLength) = parsed else { return true }
            request.remoteAddress = remoteAddress
            if WebSocketHandshake.isUpgrade(request) {
                buffer.removeFirst(headLength)
                guard let handler = server.upgradeRoute?(request), let response = WebSocketHandshake.response(for: request) else {
                    send(.text(404, "no such socket"), includeBody: true, close: true)
                    return false
                }
                server.log(request, response)
                send(response, includeBody: false, close: false)
                let session = WebSocketSession(connection: connection, remoteAddress: request.remoteAddress, handler: handler)
                websocket = session
                session.opened()
                return session.feed(&buffer)
            }
            if request.contentLength > HTTPSServer.maxInlineBody {
                // large body: stream it to the file the upload sink names, or refuse it
                guard let sink = server.uploadSink, let file = sink(request), server.uploadRoute != nil,
                    FileManager.default.createFile(atPath: file.path, contents: nil), let handle = try? FileHandle(forWritingTo: file)
                else {
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
            if request.wantsClose { return false }
        }
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
        let response = server.uploadRoute?(current.request, current.file) ?? .text(500, "no upload route")
        server.log(current.request, response)
        send(response, includeBody: true, close: current.request.wantsClose)
        return !current.request.wantsClose
    }

    private func send(_ response: HTTPResponse, includeBody: Bool, close: Bool) {
        let bytes = Data(response.serialized(includeBody: includeBody))
        connection.send(
            content: bytes,
            completion: .contentProcessed { [connection] _ in
                if close { connection.cancel() }
            })
    }
}
