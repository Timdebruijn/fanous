// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Logging
import OSLog
import Testing

@testable import FanousEngine

struct OSLogHandlerTests {
    /// A swift-log line reaches the unified log under subsystem org.fanous, with its metadata, and info is kept as notice.
    @Test func lineReachesTheUnifiedLog() async throws {
        let marker = UUID().uuidString
        let start = Date()
        var logger = Logging.Logger(label: "test") { OSLogHandler(label: $0) }
        logger[metadataKey: "b"] = "2"
        logger.info("unified \(marker)", metadata: ["a": "1"])
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        var found: OSLogEntryLog?
        for _ in 0..<20 where found == nil {
            found = try store.getEntries(at: store.position(date: start), matching: NSPredicate(format: "subsystem == 'org.fanous'"))
                .lazy.compactMap { $0 as? OSLogEntryLog }.first { $0.composedMessage.contains(marker) }
            if found == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        let entry = try #require(found)
        #expect(entry.category == "test")
        #expect(entry.composedMessage == "unified \(marker) a=1 b=2")
        #expect(entry.level == .notice)
    }
}
