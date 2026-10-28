// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import Logging
import Testing

@testable import FanousEngine

struct RoleAuthTests {
    static let logger = Logger(label: "test")

    static func makeAuth(persist: Bool = false) -> (RoleAuth, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "auth-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let auth = RoleAuth(
            settingsURL: persist ? directory.appending(path: "settings.json") : nil, shellTokenURL: directory.appending(path: "shell-token"),
            iterations: 1000, logger: logger)
        return (auth, directory)
    }

    @Test func openRolesNeedNoPassword() throws {
        let (auth, _) = Self.makeAuth()
        #expect(auth.isOpen(.programmer))
        #expect(auth.grant(requested: .programmer, cookie: nil, token: nil) == .programmer)
        let cookie = try auth.login(role: .operator, password: "", from: "10.0.0.1")
        #expect(auth.role(forCookie: cookie) == .operator)
        auth.logout(cookie: cookie)
        #expect(auth.role(forCookie: cookie) == nil)
    }

    @Test func passwordsPersistAndVerify() throws {
        let (auth, directory) = Self.makeAuth(persist: true)
        try auth.setPassword("correct horse", for: .programmer)
        #expect(!auth.isOpen(.programmer))
        #expect(auth.verify("correct horse", for: .programmer))
        #expect(!auth.verify("wrong", for: .programmer))
        #expect(auth.grant(requested: .programmer, cookie: nil, token: nil) == .operator, "falls back to the highest open role")
        #expect(throws: RoleAuth.LoginError.wrongPassword) { try auth.login(role: .programmer, password: "wrong", from: "10.0.0.2") }
        let cookie = try auth.login(role: .programmer, password: "correct horse", from: "10.0.0.2")
        #expect(auth.grant(requested: .programmer, cookie: cookie, token: nil) == .programmer)
        #expect(auth.grant(requested: .operator, cookie: cookie, token: nil) == .operator)

        let settings = MachineSettings.load(from: directory.appending(path: "settings.json"))
        #expect(settings.passwords["programmer"]?.iterations == 1000)
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appending(path: "settings.json").path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        let reloaded = RoleAuth(settingsURL: directory.appending(path: "settings.json"), shellTokenURL: nil, iterations: 1000, logger: Self.logger)
        #expect(reloaded.verify("correct horse", for: .programmer))
        try reloaded.setPassword(nil, for: .programmer)
        #expect(reloaded.isOpen(.programmer))
    }

    @Test func monitorStaysOpenWhenOthersAreProtected() throws {
        let (auth, _) = Self.makeAuth()
        try auth.setPassword("a", for: .programmer)
        try auth.setPassword("b", for: .operator)
        #expect(auth.grant(requested: .programmer, cookie: nil, token: nil) == .monitor)
        try auth.setPassword("c", for: .monitor)
        #expect(auth.grant(requested: .monitor, cookie: nil, token: nil) == nil)
    }

    @Test func loginIsRateLimitedPerAddress() throws {
        let (auth, _) = Self.makeAuth()
        try auth.setPassword("pw", for: .programmer)
        for _ in 0..<RoleAuth.loginsPerMinute {
            #expect(throws: RoleAuth.LoginError.wrongPassword) { try auth.login(role: .programmer, password: "x", from: "10.0.0.3") }
        }
        #expect(throws: RoleAuth.LoginError.rateLimited) { try auth.login(role: .programmer, password: "pw", from: "10.0.0.3") }
        // another address is unaffected
        _ = try auth.login(role: .programmer, password: "pw", from: "10.0.0.4")
    }

    @Test func shellTokenIsCreatedOnceWithMode600() throws {
        let (auth, directory) = Self.makeAuth()
        let token = try #require(auth.shellToken)
        #expect(token.count == 64)
        let file = directory.appending(path: "shell-token")
        #expect(try String(contentsOf: file, encoding: .utf8) == token)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        let again = RoleAuth(settingsURL: nil, shellTokenURL: file, iterations: 1000, logger: Self.logger)
        #expect(again.shellToken == token)
        try again.setPassword("pw", for: .programmer)
        #expect(again.grant(requested: .programmer, cookie: nil, token: token) == .programmer)
        #expect(again.grant(requested: .programmer, cookie: nil, token: "nope") == .operator)
        #expect(again.role(forToken: String(token.dropLast()) + "0") == nil)
    }

    /// A fresh directory with `settings.json` holding `contents` (none: no file), and a `RoleAuth` that loaded it.
    static func settingsAuth(_ contents: String?) throws -> (RoleAuth, URL) {
        let (_, directory) = makeAuth()
        let file = directory.appending(path: "settings.json")
        if let contents { try Data(contents.utf8).write(to: file) }
        return (RoleAuth(settingsURL: file, shellTokenURL: nil, iterations: 1000, logger: logger), file)
    }

    static func raw(_ file: URL) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file)) }

    @Test func writesKeepUnknownFields() throws {
        let (auth, file) = try Self.settingsAuth(#"{"future": [1, "x"], "sync": {"port": 48900, "mode": "fast"}}"#)
        try auth.setPassword("pw", for: .operator)
        let sync = try auth.setSync(["target": "127.0.0.1:48901"])
        #expect(sync.port == 48900 && sync.target == "127.0.0.1:48901")
        let raw = try Self.raw(file)
        #expect(raw["future"] == [1, "x"], "an unknown top-level field survives")
        #expect(raw["sync"] == ["port": 48900, "target": "127.0.0.1:48901", "mode": "fast"], "an unknown sync field survives")
        #expect(raw["passwords"]?["operator"]?["iterations"] == 1000)
        #expect(auth.verify("pw", for: .operator) && !auth.verify("x", for: .operator))
        #expect(auth.syncSettings.target == "127.0.0.1:48901", "the copy in memory follows the write")
        try auth.setPassword(nil, for: .operator)
        #expect(try Self.raw(file)["passwords"] == [:], "clearing removes the record")
        #expect(try Self.raw(file)["future"] == [1, "x"])
        #expect(auth.isOpen(.operator))
    }

    @Test func handEditAfterLoadSurvivesTheNextWrite() throws {
        // unreadable at start (machine settings start empty), fixed by hand while the engine runs
        let (auth, file) = try Self.settingsAuth(#"{"passwords": "#)
        let (other, otherFile) = try Self.settingsAuth(nil)
        try other.setPassword("hand", for: .programmer)
        var edited = try Self.raw(otherFile)
        try edited.set("x", at: "/note")
        try edited.set(["prot": 1], at: "/oscFeedback")
        try edited.set(["interface": "en0", "port": 48950], at: "/sync")
        try JSONEncoder().encode(edited).write(to: file)

        let sync = try auth.setSync(["target": "127.0.0.1:48951"])
        #expect(sync.interface == "en0" && sync.port == 48950 && sync.target == "127.0.0.1:48951", "what is applied merges the file")
        #expect(auth.syncSettings == sync)
        try auth.setPassword("pw", for: .operator)
        let raw = try Self.raw(file)
        #expect(raw["passwords"]?["programmer"] == edited["passwords"]?["programmer"], "the hand-set password record is kept")
        #expect(raw["note"] == "x" && raw["oscFeedback"] == ["prot": 1], "unknown and misspelled fields are kept")
        #expect(raw["sync"] == ["interface": "en0", "port": 48950, "target": "127.0.0.1:48951"], "the hand-edited port survives a target-only sync.set")
        #expect(MachineSettings.load(from: file).passwords.keys.sorted() == ["operator", "programmer"])
    }

    @Test func unparsableFileIsNotOverwritten() throws {
        for contents in [#"{"passwords": "#, "[]", "\u{FF}"] {
            let (auth, file) = try Self.settingsAuth(contents)
            #expect(throws: RoleAuth.UnreadableSettings.self) { try auth.setPassword("pw", for: .programmer) }
            #expect(throws: RoleAuth.UnreadableSettings.self) { try auth.setSync(["port": 48960]) }
            #expect(try Data(contentsOf: file) == Data(contents.utf8), "the file is left untouched")
            #expect(auth.isOpen(.programmer), "a refused write changes nothing in memory")
            #expect("\(RoleAuth.UnreadableSettings())" == "settings.json could not be read; fix or remove it first")
        }
    }

    @Test func missingFileIsCreatedWithOnlyTheWrittenField() throws {
        let (auth, file) = try Self.settingsAuth(nil)
        #expect(try auth.setSync(["target": "broadcast"]) == SyncSettings())
        #expect(try Self.raw(file) == ["sync": ["target": "broadcast"]])
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)

        let (other, otherFile) = try Self.settingsAuth(nil)
        try other.setPassword("pw", for: .monitor)
        #expect(try Self.raw(otherFile).object?.keys.sorted() == ["passwords"])
        #expect(try Self.raw(otherFile)["passwords"]?.object?.keys.sorted() == ["monitor"])
    }

    @Test func settingsAreOwnerOnlyFromTheStart() throws {
        // B83: written to a temporary file created 0600 and renamed into place, never chmod-ed after the write
        let (auth, file) = try Self.settingsAuth(nil)
        let directory = file.deletingLastPathComponent()
        func mode(_ url: URL) throws -> Int? { try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int }
        func entries() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() }
        try auth.setPassword("pw", for: .programmer)
        #expect(try mode(file) == 0o600, "a new file")
        _ = try auth.setSync(["port": 48970])
        #expect(try mode(file) == 0o600, "an existing file")
        #expect(try entries() == ["settings.json", "shell-token"], "no temporary file is left")

        let fresh = directory.appending(path: "fresh")
        try RoleAuth.writePrivately(Data("x".utf8), to: fresh)
        #expect(try mode(fresh) == 0o600, "the helper alone, with no chmod after it")
        let blocked = directory.appending(path: "blocked")
        try FileManager.default.createDirectory(at: blocked.appending(path: "inside"), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try RoleAuth.writePrivately(Data("x".utf8), to: blocked) }
        #expect(try entries() == ["blocked", "fresh", "settings.json", "shell-token"], "a failed write leaves no temporary file")
    }

    @Test func cookieParsing() throws {
        var request = try #require(try HTTPRequest.parse(Array("GET /ws HTTP/1.1\r\nCookie: theme=dark; fanous_session=abc123; other=1\r\n\r\n".utf8))).request
        #expect(RoleAuth.cookie(in: request) == "abc123")
        request.headers = []
        #expect(RoleAuth.cookie(in: request) == nil)
        #expect(RoleAuth.cookieHeader("v").hasPrefix("fanous_session=v; Path=/; Secure; HttpOnly; SameSite=Strict"))
    }
}
