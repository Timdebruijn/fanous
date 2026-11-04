// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Testing

@testable import FanousEngine

/// The REST routes' role gates (DESIGN.md §11, B25) as a table: method, path, credentials → status. Operator and
/// programmer have passwords, monitor is open (a usual install), so "nobody" is granted monitor. Each row's comment says
/// which regression it catches; a nil status is a path the routes decline (the static files answer it).
@Suite(.cleansTempFiles) struct RESTAuthTests {
    enum Who: String, Sendable {
        case nobody, monitor, `operator`, programmer, token, wrongToken
        /// No credentials on an engine where every role is open.
        case nobodyAllOpen
    }

    struct Row: Sendable, CustomTestStringConvertible {
        var method: String
        var target: String
        var who: Who
        var status: Int?
        var body = ""
        var testDescription: String { "\(method) \(target) as \(who) → \(status.map(String.init) ?? "nil")" }
        init(_ method: String, _ target: String, _ who: Who, _ status: Int?, body: String = "") {
            (self.method, self.target, self.who, self.status, self.body) = (method, target, who, status, body)
        }
    }

    struct Fixture {
        let routes: RESTRoutes
        let dir: URL
        let auth: RoleAuth
        var cookies: [Who: String] = [:]

        init(allOpen: Bool = false) throws {
            auth = RoleAuth(settingsURL: nil, shellTokenURL: tempFile("shell-token"), iterations: 1000, logger: testLogger)
            (routes, dir) = try testRoutes(store: testStore().store, auth: auth)
            guard !allOpen else { return }
            try auth.setPassword("op", for: .operator)
            try auth.setPassword("prog", for: .programmer)
            cookies[.monitor] = try auth.login(role: .monitor, password: "", from: "setup-monitor")
            cookies[.operator] = try auth.login(role: .operator, password: "op", from: "setup-operator")
            cookies[.programmer] = try auth.login(role: .programmer, password: "prog", from: "setup-programmer")
        }

        func request(_ method: String, _ target: String, _ who: Who, body: String = "", from address: String = "client") throws -> HTTPRequest {
            var head = "\(method) \(target) HTTP/1.1\r\nHost: a\r\n"
            if let cookie = cookies[who] { head += "Cookie: theme=dark; \(RoleAuth.cookieName)=\(cookie)\r\n" }
            if who == .token { head += "Authorization: Bearer \(try #require(auth.shellToken))\r\n" }
            if who == .wrongToken { head += "Authorization: Bearer \(String(repeating: "0", count: 64))\r\n" }
            var request = try #require(try HTTPRequest.parse(Array((head + "\r\n").utf8))).request
            request.body = Array(body.utf8)
            request.remoteAddress = address
            return request
        }

        func respond(_ row: Row) throws -> HTTPResponse? { routes.handle(try request(row.method, row.target, row.who, body: row.body)) }
    }

    func check(_ row: Row, _ fixture: Fixture? = nil) throws {
        let fixture = try fixture ?? Fixture(allOpen: row.who == .nobodyAllOpen)
        let response = try fixture.respond(row)
        #expect(response?.status == row.status, "\(row.testDescription): \(response.map { String(decoding: $0.body, as: UTF8.self) } ?? "nil")")
    }

    static let job = UUID().uuidString

    @Test(arguments: [
        // job lists carry file paths: dropping the operator gate on GET hands them to a monitor or anyone
        Row("GET", "/api/ingest", .nobody, 403),
        Row("GET", "/api/ingest", .monitor, 403),
        Row("GET", "/api/ingest", .wrongToken, 403),  // a bearer that is not the shell token must not count
        // the gate is operator, not programmer: raising it breaks the operator's Media screen
        Row("GET", "/api/ingest", .operator, 200),
        Row("GET", "/api/ingest", .token, 200),
        // queueing a job reads any file the engine can read: dropping the programmer gate lets lower roles do it
        Row("POST", "/api/ingest", .nobody, 403, body: "{}"),
        Row("POST", "/api/ingest", .monitor, 403, body: "{}"),
        Row("POST", "/api/ingest", .operator, 403, body: "{}"),
        Row("POST", "/api/ingest", .wrongToken, 403, body: "{}"),
        // past the gate the body is checked (400): the programmer cookie, the shell token and an open programmer pass
        Row("POST", "/api/ingest", .programmer, 400, body: "{}"),
        Row("POST", "/api/ingest", .token, 400, body: "{}"),
        Row("POST", "/api/ingest", .nobodyAllOpen, 400, body: "{}"),
        // cancel and remove share the POST gate
        Row("POST", "/api/ingest/\(job)/cancel", .operator, 403),
        Row("POST", "/api/ingest/\(job)/remove", .monitor, 403),
        Row("POST", "/api/ingest/\(job)/cancel", .programmer, 200),
        // a small upload goes through the route: the programmer gate keeps lower roles from writing into the library
        Row("PUT", "/api/upload/1/clip.mov", .monitor, 403, body: "x"),
        Row("PUT", "/api/upload/1/clip.mov", .operator, 403, body: "x"),
        Row("PUT", "/api/upload/1/clip.mov", .programmer, 202, body: "x"),
    ])
    func ingest(_ row: Row) throws { try check(row) }

    /// A large upload streams to `_incoming/` before the route runs; the sink is its only gate (nil: the server
    /// answers 413 and reads no body).
    @Test(arguments: [(Who.nobody, false), (.monitor, false), (.operator, false), (.wrongToken, false), (.programmer, true), (.token, true)])
    func uploadSink(_ who: Who, accepted: Bool) throws {
        let f = try Fixture()
        // dropping the role check lets any client fill the disk under the library root
        #expect((f.routes.uploadTarget(try f.request("PUT", "/api/upload/1/clip.mov", who)) != nil) == accepted)
    }

    @Test(arguments: [
        // GET reaches the method check before the gate: 405, not 403, whoever asks
        Row("GET", "/api/library/folder", .nobody, 405),
        // creating folders under the root is programmer work: dropping the gate lets lower roles do it
        Row("POST", "/api/library/folder", .nobody, 403, body: #"{"number": 1, "name": "Intro"}"#),
        Row("POST", "/api/library/folder", .monitor, 403, body: #"{"number": 1, "name": "Intro"}"#),
        Row("POST", "/api/library/folder", .operator, 403, body: #"{"number": 1, "name": "Intro"}"#),
        Row("POST", "/api/library/folder", .wrongToken, 403, body: #"{"number": 1, "name": "Intro"}"#),
        Row("POST", "/api/library/folder", .programmer, 200, body: #"{"number": 1, "name": "Intro"}"#),
        Row("POST", "/api/library/folder", .token, 200, body: #"{"number": 1, "name": "Intro"}"#),
        Row("POST", "/api/library/folder", .programmer, 400, body: #"{"number": 256, "name": "Intro"}"#),
        // any role, by design: it only re-reads the disk (a gate added here breaks the monitor's rescan)
        Row("POST", "/api/library/rescan", .nobody, 200),
        Row("GET", "/api/library", .nobody, 200),
    ])
    func library(_ row: Row) throws { try check(row) }

    /// Below operator `/api/library` has no absolute paths (B25): dropping the redaction shows a monitor the root.
    @Test(arguments: [(Who.nobody, true), (.monitor, true), (.wrongToken, true), (.operator, false), (.programmer, false), (.token, false)])
    func libraryRootRedacted(_ who: Who, redacted: Bool) throws {
        let f = try Fixture()
        let response = try #require(f.routes.handle(try f.request("GET", "/api/library", who)))
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(response.body))["root"]?.string
        #expect(root == (redacted ? "" : f.dir.appending(path: "library").path))
    }

    @Test(arguments: [
        // the engine log names files, hosts and errors: dropping the programmer gate shows it to lower roles
        Row("GET", "/api/logs", .nobody, 403),
        Row("GET", "/api/logs", .monitor, 403),
        Row("GET", "/api/logs", .operator, 403),
        Row("GET", "/api/logs", .wrongToken, 403),
        Row("GET", "/api/logs", .programmer, 200),
        Row("GET", "/api/logs?download=1", .token, 200),
    ])
    func logs(_ row: Row) throws {
        let f = try Fixture()
        try Data("engine log\n".utf8).write(to: f.dir.appending(path: "fanousd.log"))
        try check(row, f)
    }

    @Test(arguments: [
        Row("GET", "/api/login", .nobody, 405),  // a GET must not log in (cookies, links)
        Row("POST", "/api/login", .nobody, 400, body: "{}"),
        Row("POST", "/api/login", .nobody, 400, body: #"{"role": "admin", "password": "x"}"#),
        Row("POST", "/api/login", .nobody, 401, body: #"{"role": "programmer", "password": "wrong"}"#),  // a wrong password must not give a session
        Row("POST", "/api/login", .nobody, 401, body: #"{"role": "operator"}"#),  // nor a missing one
        Row("POST", "/api/login", .nobody, 204, body: #"{"role": "programmer", "password": "prog"}"#),
        Row("POST", "/api/login", .nobody, 204, body: #"{"role": "monitor"}"#),  // an open role needs no password
        Row("GET", "/api/logout", .programmer, 405),
        Row("POST", "/api/logout", .programmer, 204),
    ])
    func login(_ row: Row) throws { try check(row) }

    /// 5 logins a minute per address (RoleAuth.loginsPerMinute): the 6th is 429 even with the right password, another
    /// address is not limited. Dropping the 429 mapping turns the limit into a 401 a password guesser cannot tell apart.
    @Test func sixthLoginIs429() throws {
        let f = try Fixture()
        func login(_ password: String, from address: String) throws -> HTTPResponse? {
            f.routes.handle(try f.request("POST", "/api/login", .nobody, body: #"{"role": "programmer", "password": "\#(password)"}"#, from: address))
        }
        for _ in 0..<5 { #expect(try login("wrong", from: "10.0.0.9")?.status == 401) }
        #expect(try login("prog", from: "10.0.0.9")?.status == 429)
        #expect(try login("prog", from: "10.0.0.10")?.status == 204)
    }

    /// The cookie names the session's role; the shell token as a bearer does not count here (pinned, not judged).
    @Test(arguments: [(Who.nobody, nil), (.monitor, "monitor"), (.operator, "operator"), (.programmer, "programmer"), (.token, nil)] as [(Who, String?)])
    func session(_ who: Who, role: String?) throws {
        let f = try Fixture()
        let response = try #require(f.routes.handle(try f.request("GET", "/api/session", who)))
        let body = try JSONDecoder().decode(JSONValue.self, from: Data(response.body))
        #expect(body["role"]?.string == role)
        #expect(body["open"] == ["monitor"])
    }

    @Test(arguments: [
        Row("GET", "/api/thumbnail/abc.jpg", .nobody, 200),  // any role: the library screen shows them to a monitor
        // the name must stay inside the cache: a check dropped or loosened would serve the file next to it
        Row("GET", "/api/thumbnail/..%2Fsecret.jpg", .nobody, 404),
        Row("GET", "/api/thumbnail/%2E%2E%2Fsecret.jpg", .nobody, 404),  // not percent-decoded: no such file in the cache
        Row("GET", "/api/thumbnail/../secret.jpg", .nobody, 404),
        Row("GET", "/api/thumbnail/sub/abc.jpg", .nobody, 404),
        Row("GET", "/api/thumbnail/secret.txt", .nobody, 404),  // only .jpg
    ])
    func thumbnail(_ row: Row) throws {
        let f = try Fixture()
        try FileManager.default.createDirectory(at: f.dir.appending(path: "thumbnails"), withIntermediateDirectories: true)
        try Data([0xFF, 0xD8]).write(to: f.dir.appending(path: "thumbnails/abc.jpg"))
        try Data("outside".utf8).write(to: f.dir.appending(path: "secret.jpg"))
        try Data("outside".utf8).write(to: f.dir.appending(path: "thumbnails/secret.txt"))
        try check(row, f)
    }

    /// Ungated routes: anyone gets them. A row fails when a route drops out of the switch (the static files answer 404
    /// or 405) or when a gate is added to a route monitoring tools read without a session.
    @Test(arguments: [
        Row("GET", "/healthz", .nobody, 200),
        Row("HEAD", "/healthz", .nobody, 200),  // the server strips the body; the route answers HEAD like GET
        Row("POST", "/healthz", .nobody, 200),  // no method check on the read-only routes
        Row("GET", "/metrics", .nobody, 200),
        Row("GET", "/api/metrics", .nobody, 200),
        Row("GET", "/api/live", .nobody, 200),
        Row("GET", "/api/patch", .nobody, 200),
        Row("GET", "/api/gdtf", .nobody, 200),
        Row("GET", "/api/channel-map.md", .nobody, 200),
        Row("GET", "/api/channel-map.json", .nobody, 200),
        // not a route: the static files answer (a catch-all here would hide the web UI)
        Row("GET", "/api/nope", .programmer, nil),
        Row("GET", "/index.html", .nobody, nil),
        Row("GET", "/api/library/x", .nobody, nil),
    ])
    func open(_ row: Row) throws { try check(row) }
}
