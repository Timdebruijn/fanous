// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Logging
import os

/// Forwards to the unified log (Console.app, `log stream --predicate 'subsystem == "org.fanous"'`, sysdiagnose):
/// subsystem `org.fanous`, the swift-log label as the category.
struct OSLogHandler: LogHandler {
    var logLevel: Logging.Logger.Level = .info
    var metadata: Logging.Logger.Metadata = [:]
    private let log: os.Logger

    init(label: String) { log = os.Logger(subsystem: "org.fanous", category: label) }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        let merged = metadata.merging(event.metadata ?? [:]) { $1 }
        let suffix = merged.isEmpty ? "" : " " + merged.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        // public: the log file in ~/Library/Logs/Fanous holds the same text unredacted
        log.log(level: Self.type(event.level), "\(event.message.description + suffix, privacy: .public)")
    }

    /// The engine's info lines are its run history (start, settings, devices): `.default`, so the unified log keeps them
    /// on disk and Console shows them like the file does; `.info` is, by default, held in memory only (written out when a
    /// fault follows).
    static func type(_ level: Logging.Logger.Level) -> OSLogType {
        switch level {
        case .trace, .debug: .debug
        case .info, .notice, .warning: .default
        case .error: .error
        case .critical: .fault
        }
    }
}
