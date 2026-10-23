// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

/// Machine-local directories shared by the engine and the shell.
public enum AppPaths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    public static var applicationSupport: URL { home.appending(path: "Library/Application Support/Lanthorn") }
    public static var logs: URL { home.appending(path: "Library/Logs/Lanthorn") }
    public static var tls: URL { applicationSupport.appending(path: "tls") }
    /// Metadata and thumbnail cache (DESIGN.md §8.1), keyed by path + mtime + size.
    public static var cache: URL { applicationSupport.appending(path: "cache") }
    /// Persisted ingest queue (DESIGN.md §8.3).
    public static var ingestQueueFile: URL { applicationSupport.appending(path: "ingest-queue.json") }
    /// Default library root (machine setting, OPEN-23).
    public static var defaultLibrary: URL { home.appending(path: "Movies/Lanthorn Library") }
    public static var certificateFile: URL { tls.appending(path: "certificate.der") }
    public static var fingerprintFile: URL { tls.appending(path: "fingerprint.sha256") }

    public static func ensureDirectories() throws {
        for directory in [applicationSupport, logs, tls, cache] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
