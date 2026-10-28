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

    @Test func handEditedPasswordsTakeEffectAtTheNextWrite() throws {
        // B82: the copy in memory takes the passwords of the file as written by any command
        let (auth, file) = try Self.settingsAuth(nil)
        try auth.setPassword("op", for: .operator)
        let (other, otherFile) = try Self.settingsAuth(nil)
        try other.setPassword("hand", for: .programmer)
        var edited = try Self.raw(file)
        try edited.set(try #require(Self.raw(otherFile)["passwords"]?["programmer"]), at: "/passwords/programmer")
        try JSONEncoder().encode(edited).write(to: file)
        #expect(auth.isOpen(.programmer), "not before a write")
        _ = try auth.setSync(["port": 48980])
        #expect(!auth.isOpen(.programmer) && auth.verify("hand", for: .programmer) && !auth.verify("x", for: .programmer))
        #expect(auth.verify("op", for: .operator) && !auth.verify("x", for: .operator))

        var removed = try Self.raw(file)
        try removed.remove(at: "/passwords/operator")
        try JSONEncoder().encode(removed).write(to: file)
        _ = try auth.setSync(["port": 48981])
        #expect(auth.isOpen(.operator), "a record removed by hand opens the role, as at the next start")

        try auth.setPassword("op", for: .operator)
        var badRecord = try Self.raw(file)
        try badRecord.set("junk", at: "/passwords/admin")
        try JSONEncoder().encode(badRecord).write(to: file)
        _ = try auth.setSync(["port": 48982])
        #expect(auth.verify("hand", for: .programmer) && auth.verify("op", for: .operator) && !auth.isOpen(.operator),
                "passwords that do not decode keep the copy in memory")

        var broken = try Self.raw(file)
        try broken.set("oops", at: "/passwords")
        let brokenData = try JSONEncoder().encode(broken)
        try brokenData.write(to: file)
        let refusal = "passwords in settings.json could not be read; fix it first"
        #expect(throws: RoleAuth.UnreadableSettings(description: refusal)) { try auth.setPassword("mon", for: .monitor) }
        #expect(throws: RoleAuth.UnreadableSettings(description: refusal)) { _ = try auth.setSync(["port": 48983]) }
        #expect(try Data(contentsOf: file) == brokenData, "the file is left untouched")
        #expect(!auth.isOpen(.programmer) && !auth.isOpen(.operator) && auth.isOpen(.monitor), "a refused write opens no role")
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

    @Test func cookieParsing() throws {
        var request = try #require(try HTTPRequest.parse(Array("GET /ws HTTP/1.1\r\nCookie: theme=dark; fanous_session=abc123; other=1\r\n\r\n".utf8))).request
        #expect(RoleAuth.cookie(in: request) == "abc123")
        request.headers = []
        #expect(RoleAuth.cookie(in: request) == nil)
        #expect(RoleAuth.cookieHeader("v").hasPrefix("fanous_session=v; Path=/; Secure; HttpOnly; SameSite=Strict"))
    }
}
