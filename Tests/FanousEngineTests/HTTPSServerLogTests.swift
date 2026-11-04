// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Logging
import Synchronization
import Testing

@testable import FanousEngine

struct HTTPSServerLogTests {
    final class Lines: Sendable {
        let all = Mutex<[String]>([])
    }

    struct Capture: LogHandler {
        let lines: Lines
        var logLevel: Logger.Level = .debug
        var metadata: Logger.Metadata = [:]
        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }
        func log(event: LogEvent) { lines.all.withLock { $0.append("\(event.message)") } }
    }

    /// The request line in the debug log carries the path only: the web UI takes a token as `?token=`.
    @Test func debugLineLeavesTheQueryOut() async throws {
        let lines = Lines()
        let logger = Logger(label: "test") { _ in Capture(lines: lines) }
        let server = try HTTPSServer(
            port: 0, identity: try StateServerTests.makeIdentity(), webRoot: URL(fileURLWithPath: "/nonexistent"), logger: logger
        ) { _ in .text(200, "ok") }
        server.start()
        defer { server.stop() }
        await waitUntil(.seconds(2)) { server.boundPort != nil }
        let port = try #require(server.boundPort)
        let session = URLSession(configuration: .ephemeral, delegate: StateServerTests.TrustAll(), delegateQueue: nil)
        _ = try await session.data(from: URL(string: "https://127.0.0.1:\(port)/api/state?token=secret-4711")!)
        let logged = lines.all.withLock { $0 }
        #expect(logged.contains { $0.contains("GET /api/state") })
        #expect(!logged.contains { $0.contains("secret-4711") })
    }
}
