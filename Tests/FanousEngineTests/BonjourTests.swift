// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Logging
import Network
import Testing

@testable import FanousEngine

/// Which Bonjour services `HTTPSServer` advertises (DESIGN.md §11.1). Nothing is started, so nothing reaches the network.
struct BonjourTests {
    @Test func advertisesFanousAndHTTPSOnTheSamePort() throws {
        let server = try HTTPSServer(port: 48443, identity: try StateServerTests.makeIdentity(), webRoot: URL(fileURLWithPath: "/nonexistent"),
                                     logger: Logger(label: "test")) { _ in nil }
        server.bonjour(name: "studio")
        let services = server.advertisedServices
        #expect(services.map(\.type) == ["_fanous._tcp", "_https._tcp"])
        #expect(services.allSatisfy { $0.name == "studio" })
        #expect(services[0].txtRecordObject?["port"] == "48443")
        #expect(services[1].txtRecordObject?.dictionary == ["path": "/", "port": "48443"])
    }

    @Test func loopbackOnlyAdvertisesNothing() throws {
        let server = try HTTPSServer(port: 48443, identity: try StateServerTests.makeIdentity(), webRoot: URL(fileURLWithPath: "/nonexistent"),
                                     loopbackOnly: true, logger: Logger(label: "test")) { _ in nil }
        server.bonjour(name: "studio")
        #expect(server.advertisedServices.isEmpty)
    }

    @Test func portZeroAdvertisesNothing() throws {
        let server = try HTTPSServer(port: 0, identity: try StateServerTests.makeIdentity(), webRoot: URL(fileURLWithPath: "/nonexistent"),
                                     logger: Logger(label: "test")) { _ in nil }
        server.bonjour(name: "studio")
        #expect(server.advertisedServices.isEmpty)
    }
}
