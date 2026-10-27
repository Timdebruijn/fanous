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
}
