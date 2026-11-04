// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Logging
import OSLog
import Testing

@testable import FanousEngine

@Suite(.cleansTempFiles)
struct OSLogHandlerTests {
    /// A line through the engine's handler reaches the unified log under subsystem org.fanous and the file, the call's
    /// metadata winning over the logger's, and info is kept as notice.
    @Test func lineReachesTheUnifiedLogAndTheFile() async throws {
        let marker = UUID().uuidString
        let file = tempFile("fanous-oslog", ext: "log")
        let sink = FileLogSink(url: file)
        var logger = Logging.Logger(label: "test") { EngineLogging.handler(label: $0, level: .info, sink: sink) }
        logger[metadataKey: "a"] = "logger"
        logger[metadataKey: "b"] = "2"
        logger.info("unified \(marker)", metadata: ["a": "call"])
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        var found: OSLogEntryLog?
        for _ in 0..<20 where found == nil {
            found = try store.getEntries(matching: NSPredicate(format: "subsystem == 'org.fanous'"))
                .lazy.compactMap { $0 as? OSLogEntryLog }.first { $0.composedMessage.contains(marker) }
            if found == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        let entry = try #require(found)
        #expect(entry.category == "test")
        #expect(entry.composedMessage == "unified \(marker) a=call b=2")
        #expect(entry.level == .notice)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("[test] unified \(marker) a=call b=2"))
    }

    @Test func levels() {
        #expect(OSLogHandler.type(.trace) == .debug)
        #expect(OSLogHandler.type(.debug) == .debug)
        #expect(OSLogHandler.type(.warning) == .default)
        #expect(OSLogHandler.type(.error) == .error)
        #expect(OSLogHandler.type(.critical) == .fault)
    }
}
