// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import Logging
import Security
import Synchronization
import Testing

@testable import FanousEngine

/// End to end over TLS: a real `HTTPSServer`, the WebSocket upgrade, hello/welcome, commands, acks, patches,
/// show lock, login cookies and a second client seeing the same revision (DESIGN.md §11.2).
struct StateServerTests {
    static let logger = Logger(label: "test")

    /// Accepts the self-signed test certificate.
    final class TrustAll: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard let trust = challenge.protectionSpace.serverTrust else { return (.cancelAuthenticationChallenge, nil) }
            return (.useCredential, URLCredential(trust: trust))
        }
    }

    struct Fixture {
        let server: HTTPSServer
        let stateServer: StateServer
        let store: StateStore
        let auth: RoleAuth
        let port: UInt16
        let session: URLSession

        func socket(cookie: String? = nil) -> URLSessionWebSocketTask {
            var request = URLRequest(url: URL(string: "wss://127.0.0.1:\(port)/ws")!)
            if let cookie { request.setValue("\(RoleAuth.cookieName)=\(cookie)", forHTTPHeaderField: "Cookie") }
            let task = session.webSocketTask(with: request)
            task.resume()
            return task
        }

        func post(_ path: String, _ body: String) async throws -> HTTPURLResponse {
            var request = URLRequest(url: URL(string: "https://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            let (_, response) = try await session.data(for: request)
            return response as! HTTPURLResponse
        }
    }

    static func makeIdentity() throws -> TLSIdentity {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: false],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else { throw error!.takeRetainedValue() }
        let (certificate, der) = try TLSIdentity.makeCertificate(privateKey: key, hostnames: ["localhost"], ipAddresses: ["127.0.0.1"])
        let identity = try #require(SecIdentityCreate(nil, certificate, key))
        return TLSIdentity(identity: identity, certificateDER: der, storage: .file)
    }

    static func start() async throws -> Fixture {
        let auth = RoleAuth(settingsURL: nil, shellTokenURL: nil, iterations: 1000, logger: logger)
        let project = ProjectDocument.initial(patch: .standard(layers: 2, outputs: 1), layerCount: 2, libraryRoot: "/tmp/lib", policy: .dmx)
        let store = StateStore(project: project, logger: logger)
        ProjectDocument.registerCommands(on: store, auth: auth)
        let stateServer = StateServer(store: store, auth: auth, caps: ["schema": 1], logger: logger)
        let server = try HTTPSServer(port: 0, identity: try makeIdentity(), webRoot: URL(fileURLWithPath: "/nonexistent"), logger: logger) { request in
            guard request.path == "/api/login", request.method == "POST",
                let body = try? JSONDecoder().decode(JSONValue.self, from: Data(request.body)),
                let role = body["role"]?.string.flatMap(Role.init(rawValue:))
            else { return nil }
            do {
                let cookie = try auth.login(role: role, password: body["password"]?.string ?? "", from: request.remoteAddress)
                return HTTPResponse(status: 204, headers: [HTTPHeader("Set-Cookie", RoleAuth.cookieHeader(cookie))])
            } catch {
                return .text(401, "wrong password")
            }
        }
        server.upgradeRoute = { stateServer.upgrade($0) }
        server.start()
        for _ in 0..<100 where server.boundPort == nil { try await Task.sleep(for: .milliseconds(20)) }
        let port = try #require(server.boundPort)
        let session = URLSession(configuration: .ephemeral, delegate: TrustAll(), delegateQueue: nil)
        return Fixture(server: server, stateServer: stateServer, store: store, auth: auth, port: port, session: session)
    }

    static func receive(_ task: URLSessionWebSocketTask) async throws -> JSONValue {
        switch try await task.receive() {
        case .string(let text): return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        case .data(let data): return ["binary": .number(Double(data.count))]
        @unknown default: return .null
        }
    }

    /// Reads messages until one with `t == type` arrives (patches and acks may interleave).
    static func receive(_ task: URLSessionWebSocketTask, until type: String) async throws -> JSONValue {
        for _ in 0..<10 {
            let message = try await receive(task)
            if message["t"]?.string == type { return message }
        }
        throw CommandError("timeout", "no \(type) message")
    }

    @Test func helloCommandsPatchesAndLock() async throws {
        let f = try await Self.start()
        defer { f.server.stop() }
        let a = f.socket()
        try await a.send(.string(#"{"t":"hello","clientId":"a","schema":1,"role":"programmer"}"#))
        let welcome = try await Self.receive(a, until: "welcome")
        #expect(welcome["role"]?.string == "programmer")
        #expect(welcome["rev"]?.int == 0)
        #expect(welcome["project"]?["showLock"]?.bool == false)
        #expect(welcome["caps"]?["schema"]?.int == 1)

        let b = f.socket()
        try await b.send(.string(#"{"t":"hello","clientId":"b","schema":1}"#))
        #expect(try await Self.receive(b, until: "welcome")["role"]?.string == "monitor")

        try await a.send(.string(#"{"t":"cmd","id":"c1","name":"project.set","args":{"path":"/name","value":"Tour"}}"#))
        let ack = try await Self.receive(a, until: "ack")
        #expect(ack["id"]?.string == "c1")
        #expect(ack["ok"]?.bool == true)
        #expect(ack["rev"]?.int == 1)
        let patchForB = try await Self.receive(b, until: "patch")
        #expect(patchForB["rev"]?.int == 1)
        #expect(patchForB["ops"]?.array?.first?["value"]?.string == "Tour")

        try await b.send(.string(#"{"t":"cmd","id":"m1","name":"show.lock"}"#))
        let forbidden = try await Self.receive(b, until: "ack")
        #expect(forbidden["ok"]?.bool == false)
        #expect(forbidden["error"]?["code"]?.string == "forbidden")

        try await a.send(.string(#"{"t":"cmd","id":"c2","name":"show.lock"}"#))
        #expect(try await Self.receive(a, until: "ack")["ok"]?.bool == true)
        try await a.send(.string(#"{"t":"cmd","id":"c3","name":"project.set","args":{"path":"/name","value":"Nope"}}"#))
        let locked = try await Self.receive(a, until: "ack")
        #expect(locked["error"]?["code"]?.string == "showLocked")
        #expect(f.store.project["name"]?.string == "Tour")

        try await a.send(.string(#"{"t":"snapshot"}"#))
        let snapshot = try await Self.receive(a, until: "snapshot")
        #expect(snapshot["project"]?["showLock"]?.bool == true)
        #expect(snapshot["rev"]?.int == 2)

        try await a.send(.string(#"{"t":"sub","stream":"dmx","universe":"artnet:0.0.0"}"#))
        let sub = try await Self.receive(a, until: "sub")
        #expect(sub["id"]?.int != nil)
        // a refused preview (no renderer here) names its stream, so the client settles the waiting request (B62)
        try await a.send(.string(#"{"t":"sub","stream":"preview","codec":"jpeg"}"#))
        let refused = try await Self.receive(a, until: "error")
        #expect(refused["code"]?.string == "noPreview")
        #expect(refused["stream"]?.string == "preview")
        #expect(refused["id"]?.int != nil && refused["id"]?.int != sub["id"]?.int)

        a.cancel(with: .normalClosure, reason: nil)
        b.cancel(with: .normalClosure, reason: nil)
        for _ in 0..<50 where f.store.clientCount > 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(f.store.clientCount == 0)
    }

    /// B62: the client matches preview replies to its requests by order, so a refused request must be answered in its
    /// turn, with its own stream id and `stream`, and must leave no subscription behind.
    @Test func previewRepliesComeInRequestOrderAndARefusalKeepsNoSubscription() async throws {
        let f = try await Self.start()
        defer { f.server.stop() }
        let rig = try PreviewHubTests.Rig()  // a hub that previews "canvas" and "output:1"
        f.stateServer.preview = rig.hub
        let connection = Mutex<StateServer.Connection?>(nil)
        f.server.upgradeRoute = { [stateServer = f.stateServer] request in
            let handler = stateServer.upgrade(request)
            connection.withLock { $0 = handler as? StateServer.Connection }
            return handler
        }
        let a = f.socket()
        try await a.send(.string(#"{"t":"hello","clientId":"a","schema":1}"#))
        _ = try await Self.receive(a, until: "welcome")
        for target in ["canvas", "output:99", "output:1"] {
            try await a.send(.string(#"{"t":"sub","stream":"preview","codec":"jpeg","target":"\#(target)"}"#))
        }
        var replies: [JSONValue] = []
        while replies.count < 3 {
            let message = try await Self.receive(a)
            if ["sub", "error"].contains(message["t"]?.string) { replies.append(message) }
        }
        #expect(replies.map { $0["t"]?.string } == ["sub", "error", "sub"])
        #expect(replies.map { $0["target"]?.string } == ["canvas", nil, "output:1"])
        #expect(replies[1]["code"]?.string == "badTarget" && replies[1]["stream"]?.string == "preview")
        let ids = replies.compactMap { $0["id"]?.int }
        #expect(ids.count == 3 && Set(ids).count == 3, "every reply has its own stream id: \(ids)")
        let table = try #require(connection.withLock { $0 }).subscriptions.withLock { $0 }
        #expect(Set(table.keys) == [UInt32(ids[0]), UInt32(ids[2])], "the refused id is not subscribed")
        #expect(!rig.hub.targets.contains("output:99"))
        a.cancel(with: .normalClosure, reason: nil)
    }

    /// B32: `w` picks the size class; the reply says the size the stream has (the target's shape, 16:9 here).
    @Test func previewSubTakesAWantedWidthAndRepliesWithTheStreamSize() async throws {
        let f = try await Self.start()
        defer { f.server.stop() }
        let rig = try PreviewHubTests.Rig()
        f.stateServer.preview = rig.hub
        let a = f.socket()
        try await a.send(.string(#"{"t":"hello","clientId":"a","schema":1}"#))
        _ = try await Self.receive(a, until: "welcome")
        for w in ["", #","w":300"#, #","w":1e300"#, #","w":-5"#] {
            try await a.send(.string(#"{"t":"sub","stream":"preview","codec":"jpeg","target":"output:1"\#(w)}"#))
        }
        var sizes: [[Int]] = []
        while sizes.count < 4 {
            let message = try await Self.receive(a)
            if message["t"]?.string == "sub" { sizes.append([message["w"]?.int ?? 0, message["h"]?.int ?? 0]) }
        }
        #expect(sizes == [[640, 360], [320, 180], [1280, 720], [320, 180]])
        a.cancel(with: .normalClosure, reason: nil)
    }

    /// B29: `sub {stream:"thumbs"}` is answered like the other subs (stream id, cell width, rate) and subscribes this
    /// connection to the one thumbnail producer; `unsub` ends it; without a renderer it is refused with its stream named.
    @Test func thumbsSubIsAnsweredAndUnsubEndsIt() async throws {
        let f = try await Self.start()
        defer { f.server.stop() }
        let a = f.socket()
        try await a.send(.string(#"{"t":"hello","clientId":"a","schema":1}"#))
        _ = try await Self.receive(a, until: "welcome")
        try await a.send(.string(#"{"t":"sub","stream":"thumbs"}"#))
        let refused = try await Self.receive(a, until: "error")
        #expect(refused["code"]?.string == "noPreview" && refused["stream"]?.string == "thumbs" && refused["id"]?.int != nil)

        let rig = try PreviewHubTests.Rig()
        let thumbnails = try ThumbnailStreamer(context: rig.context, compositor: rig.compositor)
        rig.hub.thumbnails = thumbnails
        f.stateServer.preview = rig.hub
        try await a.send(.string(#"{"t":"sub","stream":"thumbs"}"#))
        let sub = try await Self.receive(a, until: "sub")
        #expect(sub["stream"]?.string == "thumbs" && sub["w"]?.int == 160 && sub["fps"]?.int == 4)
        let id = try #require(sub["id"]?.int)
        #expect(thumbnails.hasSubscribers && rig.hub.wantsFrames)
        try await a.send(.string(#"{"t":"unsub","id":\#(id)}"#))
        for _ in 0..<100 where thumbnails.hasSubscribers { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!thumbnails.hasSubscribers && !rig.hub.wantsFrames, "nobody wants thumbnails: no atlas pass")
        a.cancel(with: .normalClosure, reason: nil)
    }

    @Test func dmxMonitorTimerFollowsTheSubscriptions() async throws {
        let f = try await Self.start()
        defer { f.server.stop() }
        let changes = Mutex<[Bool]>([])
        f.stateServer.onDMXActive = { on in changes.withLock { $0.append(on) } }
        let a = f.socket(), b = f.socket()
        for (task, name) in [(a, "a"), (b, "b")] {
            try await task.send(.string(#"{"t":"hello","clientId":"\#(name)","schema":1}"#))
            _ = try await Self.receive(task, until: "welcome")
        }
        #expect(changes.withLock { $0 }.isEmpty, "no subscription, no timer")
        try await a.send(.string(#"{"t":"sub","stream":"dmx","universe":"artnet:0.0.0"}"#))
        let id = try #require(try await Self.receive(a, until: "sub")["id"]?.int)
        try await b.send(.string(#"{"t":"sub","stream":"dmx","universe":"artnet:0.0.0"}"#))
        _ = try await Self.receive(b, until: "sub")
        #expect(changes.withLock { $0 } == [true], "started once, with the first subscription")
        try await a.send(.string(#"{"t":"unsub","id":\#(id)}"#))
        try await Task.sleep(for: .milliseconds(200))
        #expect(changes.withLock { $0 } == [true], "b still watches")
        b.cancel(with: .normalClosure, reason: nil)
        for _ in 0..<100 where changes.withLock({ $0.count }) < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(changes.withLock { $0 } == [true, false], "stopped with the last one (closing the socket counts)")
        a.cancel(with: .normalClosure, reason: nil)
    }

    @Test func loginCookieUnlocksProtectedRole() async throws {
        let f = try await Self.start()
        defer { f.server.stop() }
        try f.auth.setPassword("secret", for: .programmer)

        let anonymous = f.socket()
        try await anonymous.send(.string(#"{"t":"hello","clientId":"x","schema":1,"role":"programmer"}"#))
        #expect(try await Self.receive(anonymous, until: "welcome")["role"]?.string == "operator")
        anonymous.cancel(with: .normalClosure, reason: nil)

        #expect(try await f.post("/api/login", #"{"role":"programmer","password":"wrong"}"#).statusCode == 401)
        let ok = try await f.post("/api/login", #"{"role":"programmer","password":"secret"}"#)
        #expect(ok.statusCode == 204)
        let setCookie = try #require(ok.value(forHTTPHeaderField: "Set-Cookie"))
        let cookie = String(setCookie.dropFirst(RoleAuth.cookieName.count + 1).prefix { $0 != ";" })
        #expect(cookie.count == 64)

        let programmer = f.socket(cookie: cookie)
        try await programmer.send(.string(#"{"t":"hello","clientId":"p","schema":1,"role":"programmer"}"#))
        #expect(try await Self.receive(programmer, until: "welcome")["role"]?.string == "programmer")
        programmer.cancel(with: .normalClosure, reason: nil)
    }

    @Test func wrongSchemaAndUnknownPathAreRefused() async throws {
        let f = try await Self.start()
        defer { f.server.stop() }
        let task = f.socket()
        try await task.send(.string(#"{"t":"hello","clientId":"x","schema":2}"#))
        let error = try await Self.receive(task, until: "error")
        #expect(error["code"]?.string == "schema")
        var request = URLRequest(url: URL(string: "wss://127.0.0.1:\(f.port)/nope")!)
        request.timeoutInterval = 5
        let bad = f.session.webSocketTask(with: request)
        bad.resume()
        await #expect(throws: Error.self) { try await bad.receive() }
    }
}
