// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import LanthornCore
import Logging
import Testing

@testable import LanthornEngine

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

    @Test func cookieParsing() throws {
        var request = try #require(try HTTPRequest.parse(Array("GET /ws HTTP/1.1\r\nCookie: theme=dark; lanthorn_session=abc123; other=1\r\n\r\n".utf8))).request
        #expect(RoleAuth.cookie(in: request) == "abc123")
        request.headers = []
        #expect(RoleAuth.cookie(in: request) == nil)
        #expect(RoleAuth.cookieHeader("v").hasPrefix("lanthorn_session=v; Path=/; Secure; HttpOnly; SameSite=Strict"))
    }
}
