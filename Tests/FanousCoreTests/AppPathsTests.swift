// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Testing

@testable import FanousCore

@Suite struct AppPathsTests {
    @Test func fanousHomeMustBeAnAbsolutePath() {
        #expect(AppPaths.parseHome(nil) == (nil, nil))
        #expect(AppPaths.parseHome("") == (nil, nil))
        let relative = AppPaths.parseHome("tmp/fanous")
        #expect(relative.url == nil)
        #expect(relative.problem?.contains("not an absolute path") == true)
        #expect(AppPaths.parseHome("/tmp/x/../fanous/").url?.path == "/tmp/fanous")
    }

    @Test func tlsKeychainTagIsTheProductionOneOnlyWithoutOverride() {
        #expect(AppPaths.tlsKeychainTag(home: nil) == "org.fanous.tls")
        let a = AppPaths.tlsKeychainTag(home: URL(fileURLWithPath: "/tmp/fanous-e2e-a"))
        let b = AppPaths.tlsKeychainTag(home: URL(fileURLWithPath: "/tmp/fanous-e2e-b"))
        #expect(a != "org.fanous.tls")
        #expect(a != b)
        #expect(a == AppPaths.tlsKeychainTag(home: URL(fileURLWithPath: "/tmp/fanous-e2e-a")))
    }

    /// The shell opens the UI with its token once the engine has written the file, and without it before.
    @Test func shellPageCarriesTheTokenOnceTheFileExists() throws {
        let base = try #require(URL(string: "https://127.0.0.1:8443/"))
        let file = FileManager.default.temporaryDirectory.appending(path: "fanous-shell-token-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(AppPaths.shellPageURL(base, tokenFile: file) == base)
        try Data("0123abcd\n".utf8).write(to: file)
        #expect(AppPaths.shellPageURL(base, tokenFile: file).absoluteString == "https://127.0.0.1:8443/?token=0123abcd")
    }
}
