// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import Logging
import Synchronization

/// The `/ws` endpoint (DESIGN.md §11.2): hello/welcome, commands with acks, project and live patches,
/// snapshots for lagging clients and stream subscriptions. One `Connection` per socket.
public final class StateServer: @unchecked Sendable {
    public static let schema = 1
    public static let path = "/ws"
    /// Binary frame kinds: `[u8 kind][u32 stream id][payload]`.
    public enum StreamKind: UInt8 { case h264 = 1, jpeg = 2, dmx = 3, metrics = 4 }

    public let store: StateStore
    public let auth: RoleAuth
    /// Installed by the engine when it renders; nil → preview subscriptions are refused.
    nonisolated(unsafe) public var preview: PreviewHub?
    private let caps: JSONValue
    private let logger: Logger
    private let connections = Mutex<[ObjectIdentifier: Connection]>([:])
    private let nextStream = Atomic<UInt32>(1)

    public init(store: StateStore, auth: RoleAuth, caps: JSONValue, logger: Logger) {
        self.store = store
        self.auth = auth
        self.caps = caps
        self.logger = logger
    }

    /// `HTTPSServer.upgradeRoute`: same-origin check, then a connection pre-authenticated from the session cookie.
    public func upgrade(_ request: HTTPRequest) -> WebSocketHandler? {
        guard request.path == Self.path else { return nil }
        if let origin = request.header("Origin"), let host = request.header("Host") {
            guard let url = URL(string: origin), let originHost = url.host(percentEncoded: false) else { return nil }
            let originAuthority = url.port.map { "\(originHost):\($0)" } ?? originHost
            guard originAuthority.caseInsensitiveCompare(host) == .orderedSame else {
                logger.warning("WebSocket origin refused", metadata: ["origin": "\(origin)", "host": "\(host)"])
                return nil
            }
        }
        let connection = Connection(server: self, cookieRole: auth.role(forCookie: RoleAuth.cookie(in: request)))
        connections.withLock { $0[ObjectIdentifier(connection)] = connection }
        return connection
    }

    /// Every DMX subscription: (connection, stream id, universe description).
    public func dmxSubscriptions() -> [(connection: Connection, stream: UInt32, universe: String)] {
        connections.withLock { all in
            all.values.flatMap { c in
                c.subscriptions.withLock { subs in subs.compactMap { id, sub -> (Connection, UInt32, String)? in if case .dmx(let u) = sub { (c, id, u) } else { nil } } }
            }
        }
    }

    fileprivate func forget(_ connection: Connection) { connections.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(connection)) } }

    /// Called with true when the first DMX monitor subscription appears and false when the last one is gone,
    /// so the engine only runs its 20 Hz monitor timer while somebody watches.
    nonisolated(unsafe) public var onDMXActive: (@Sendable (Bool) -> Void)?
    private let dmxActive = Mutex(false)

    fileprivate func dmxSubscriptionsChanged() {
        let now = !dmxSubscriptions().isEmpty
        let changed = dmxActive.withLock { was -> Bool in
            defer { was = now }
            return was != now
        }
        if changed { onDMXActive?(now) }
    }

    public enum Subscription: Equatable, Sendable {
        case dmx(String)
        case preview
    }

    public final class Connection: WebSocketHandler, StateClient, @unchecked Sendable {
        private let server: StateServer
        private let cookieRole: Role?
        private let session = Mutex<WebSocketSession?>(nil)
        private let grantedRole = Mutex<Role?>(nil)
        public let clientId = Mutex<String>("")
        let subscriptions = Mutex<[UInt32: Subscription]>([:])

        init(server: StateServer, cookieRole: Role?) {
            self.server = server
            self.cookieRole = cookieRole
        }

        public var role: Role { grantedRole.withLock { $0 ?? .monitor } }
        public var isAuthenticated: Bool { grantedRole.withLock { $0 != nil } }

        // MARK: StateClient

        public func send(text: String, droppable: Bool) -> Bool {
            session.withLock { $0?.send(text: text, droppable: droppable) ?? false }
        }

        public func send(stream: UInt32, kind: StreamKind, payload: [UInt8]) -> Bool {
            var frame = [kind.rawValue, UInt8(stream >> 24), UInt8((stream >> 16) & 0xFF), UInt8((stream >> 8) & 0xFF), UInt8(stream & 0xFF)]
            frame.append(contentsOf: payload)
            return session.withLock { $0?.send(binary: frame, droppable: true) ?? false }
        }

        public func disconnect(reason: String) {
            session.withLock { $0?.close(code: 1008, reason: reason) }
        }

        // MARK: WebSocketHandler

        public func sessionDidOpen(_ session: WebSocketSession) { self.session.withLock { $0 = session } }

        public func session(_ session: WebSocketSession, didReceiveBinary data: [UInt8]) {
            // no client → server binary streams in v1
        }

        public func sessionDidClose(_ session: WebSocketSession) {
            if isAuthenticated { server.store.detach(self) }
            server.preview?.remove(connection: self)
            server.forget(self)
            server.dmxSubscriptionsChanged()
            server.logger.debug("client left", metadata: ["client": "\(clientId.withLock { $0 })"])
        }

        public func session(_ session: WebSocketSession, didReceiveText text: String) {
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)), let type = message["t"]?.string else {
                session.send(text: server.store.encode(["t": "error", "code": "badMessage", "message": "expected a JSON object with t"]), droppable: false)
                return
            }
            if type == "hello" { return hello(message, on: session) }
            guard isAuthenticated else {
                session.send(text: server.store.encode(["t": "error", "code": "helloFirst", "message": "send hello before anything else"]), droppable: false)
                return
            }
            switch type {
            case "cmd":
                let id = message["id"] ?? .null
                guard let name = message["name"]?.string else {
                    session.send(text: server.store.encode(["t": "ack", "id": id, "ok": false, "error": ["code": "badMessage", "message": "cmd needs a name"]]), droppable: false)
                    return
                }
                let result = server.store.execute(name, args: message["args"] ?? [:], role: role, from: self)
                let ack: JSONValue =
                    switch result {
                    case .success(let r):
                        ["t": "ack", "id": id, "ok": true, "rev": .number(Double(r.rev)), "result": r.value ?? .null]
                    case .failure(let e):
                        ["t": "ack", "id": id, "ok": false, "error": ["code": .string(e.code), "message": .string(e.message)]]
                    }
                session.send(text: server.store.encode(ack), droppable: false)
            case "snapshot":
                server.store.clearLagging(self)
                session.send(text: server.store.snapshot(role: role), droppable: false)
            case "sub":
                switch message["stream"]?.string {
                case "dmx":
                    guard let universe = message["universe"]?.string else {
                        session.send(text: server.store.encode(["t": "error", "code": "badStream", "message": "stream dmx needs a universe"]), droppable: false)
                        return
                    }
                    let id = server.nextStream.add(1, ordering: .relaxed).oldValue
                    subscriptions.withLock { $0[id] = .dmx(universe) }
                    session.send(text: server.store.encode(["t": "sub", "id": .number(Double(id)), "stream": "dmx", "universe": .string(universe)]), droppable: false)
                    server.dmxSubscriptionsChanged()
                case "preview":
                    guard let preview = server.preview else {
                        session.send(text: server.store.encode(["t": "error", "code": "noPreview", "message": "the engine is not rendering"]), droppable: false)
                        return
                    }
                    let jpeg = message["codec"]?.string == "jpeg"
                    let target = message["target"]?.string ?? "canvas"
                    let id = server.nextStream.add(1, ordering: .relaxed).oldValue
                    subscriptions.withLock { $0[id] = .preview }
                    // each target has its own streamer: this client's choice does not change what others see
                    let attached = preview.attach(target: target, connection: self, stream: id, jpeg: jpeg) { streamer in
                        session.send(
                            text: server.store.encode([
                                "t": "sub", "id": .number(Double(id)), "stream": "preview", "codec": jpeg ? "jpeg" : "avc", "w": .number(Double(streamer.width)),
                                "h": .number(Double(streamer.height)), "fps": .number(jpeg ? 5 : streamer.fps), "target": .string(target),
                            ]), droppable: false)
                    }
                    if !attached {
                        subscriptions.withLock { _ = $0.removeValue(forKey: id) }
                        session.send(text: server.store.encode(["t": "error", "code": "badTarget", "message": "preview target \(target) is not canvas or an existing output:<id>"]), droppable: false)
                    }
                default:
                    session.send(text: server.store.encode(["t": "error", "code": "badStream", "message": "streams: dmx, preview"]), droppable: false)
                }
            case "unsub":
                if let id = message["id"]?.int {
                    let removed = subscriptions.withLock { $0.removeValue(forKey: UInt32(id)) }
                    if removed == .preview { server.preview?.unsubscribe(connection: self, stream: UInt32(id)) }
                    if case .dmx? = removed { server.dmxSubscriptionsChanged() }
                }
            default:
                session.send(text: server.store.encode(["t": "error", "code": "badMessage", "message": "unknown t \(type)"]), droppable: false)
            }
        }

        private func hello(_ message: JSONValue, on session: WebSocketSession) {
            guard message["schema"]?.int == StateServer.schema else {
                session.send(text: server.store.encode(["t": "error", "code": "schema", "message": "this engine speaks schema \(StateServer.schema)"]), droppable: false)
                session.close(code: 1002, reason: "schema")
                return
            }
            let requested = message["role"]?.string.flatMap(Role.init(rawValue:)) ?? .monitor
            let sessionRole = server.auth.role(forToken: message["token"]?.string) ?? cookieRole
            guard let granted = server.auth.grant(requested: requested, sessionRole: sessionRole) else {
                session.send(text: server.store.encode(["t": "error", "code": "authRequired", "message": "log in for role \(requested)"]), droppable: false)
                session.close(code: 4401, reason: "auth required")
                return
            }
            clientId.withLock { $0 = message["clientId"]?.string ?? "" }
            let first = grantedRole.withLock { current -> Bool in
                let wasNil = current == nil
                current = granted
                return wasNil
            }
            if first { server.store.attach(self) }
            session.send(text: server.store.welcome(role: granted, caps: server.caps), droppable: false)
            server.logger.info("client joined", metadata: ["client": "\(clientId.withLock { $0 })", "role": "\(granted)", "from": "\(session.remoteAddress)"])
        }
    }
}
