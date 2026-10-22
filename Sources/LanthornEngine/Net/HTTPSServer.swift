// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import LanthornCore
import Logging
import Network

/// HTTPS/1.1 static-file server on Network.framework. One listener; each
/// connection parses request heads with LanthornCore's parser. GET/HEAD only
/// in Phase 0; WebSocket and uploads arrive in Phase 5.
public final class HTTPSServer: @unchecked Sendable {
    public typealias Route = @Sendable (HTTPRequest) -> HTTPResponse?

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
        listener.stateUpdateHandler = { [logger, port] state in
            switch state {
            case .ready: logger.info("HTTPS listening", metadata: ["port": "\(port)"])
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

    init(_ connection: NWConnection, server: HTTPSServer) {
        self.connection = connection
        self.server = server
    }

    func start() {
        connection.stateUpdateHandler = { [connection] state in
            if case .failed = state { connection.cancel() }
            if case .cancelled = state { connection.stateUpdateHandler = nil }
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
                connection.cancel()
                return
            }
            receive()
        }
    }

    /// Handles every complete request in the buffer. Returns false once the connection is being closed.
    private func process() -> Bool {
        while true {
            let parsed: (request: HTTPRequest, headLength: Int)?
            do {
                parsed = try HTTPRequest.parse(buffer)
            } catch {
                send(.text(400, "bad request"), includeBody: true, close: true)
                return false
            }
            guard let (request, headLength) = parsed else { return true }
            let total = headLength + request.contentLength
            guard buffer.count >= total else { return true }  // body still arriving; it is ignored
            buffer.removeFirst(total)
            let response = server.respond(to: request)
            server.log(request, response)
            send(response, includeBody: request.method != "HEAD", close: request.wantsClose)
            if request.wantsClose { return false }
        }
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
