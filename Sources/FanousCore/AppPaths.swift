// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

/// Machine-local directories shared by the engine and the shell.
public enum AppPaths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    public static var applicationSupport: URL { home.appending(path: "Library/Application Support/Fanous") }
    public static var logs: URL { home.appending(path: "Library/Logs/Fanous") }
    public static var tls: URL { applicationSupport.appending(path: "tls") }
    /// Metadata and thumbnail cache (DESIGN.md §8.1), keyed by path + mtime + size.
    public static var cache: URL { applicationSupport.appending(path: "cache") }
    /// Persisted ingest queue (DESIGN.md §8.3).
    public static var ingestQueueFile: URL { applicationSupport.appending(path: "ingest-queue.json") }
    /// Default library root (machine setting, OPEN-23).
    public static var defaultLibrary: URL { home.appending(path: "Movies/Fanous Library") }
    /// Machine settings outside the project (DESIGN.md §11.5): role passwords, library root, interfaces.
    public static var settingsFile: URL { applicationSupport.appending(path: "settings.json") }
    /// Per-install random token the local shell presents to authenticate as programmer (mode 0600).
    public static var shellTokenFile: URL { applicationSupport.appending(path: "shell-token") }
    /// The current project document until project bundles exist (DESIGN.md §11.5).
    public static var projectFile: URL { applicationSupport.appending(path: "project.json") }
    public static var certificateFile: URL { tls.appending(path: "certificate.der") }
    public static var fingerprintFile: URL { tls.appending(path: "fingerprint.sha256") }

    public static func ensureDirectories() throws {
        migrateFromLanthorn()
        for directory in [applicationSupport, logs, tls, cache] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// The project was called Lanthorn until 2026-10-25: move its machine state (project, TLS identity, passwords,
    /// shell token, caches, logs) once, so the pinned certificate and the project survive the rename.
    /// ponytail: remove after the first public release; nobody else has a Lanthorn install.
    static func migrateFromLanthorn() {
        let fm = FileManager.default
        for (old, new) in [(home.appending(path: "Library/Application Support/Lanthorn"), applicationSupport), (home.appending(path: "Library/Logs/Lanthorn"), logs)]
        where fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: new.path) {
            try? fm.moveItem(at: old, to: new)
        }
    }
}
