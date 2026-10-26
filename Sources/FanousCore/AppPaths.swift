// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

/// Machine-local directories shared by the engine and the shell.
public enum AppPaths {
    /// `FANOUS_HOME` when it is an absolute path (B47): every path below (Application Support, logs, cache, TLS, the
    /// default library) and the keychain tag of the TLS key then belong to that directory, so a test engine never
    /// touches the user's data. Empty is unset; anything else is ignored and `homeOverrideProblem` says why.
    public static let homeOverride: URL? = parseHome(ProcessInfo.processInfo.environment["FANOUS_HOME"]).url
    public static let homeOverrideProblem: String? = parseHome(ProcessInfo.processInfo.environment["FANOUS_HOME"]).problem
    public static var home: URL { homeOverride ?? FileManager.default.homeDirectoryForCurrentUser }
    /// Keychain application tag of the TLS key: the production one, or one of this `FANOUS_HOME` only.
    public static var tlsKeychainTag: String { tlsKeychainTag(home: homeOverride) }

    static func parseHome(_ value: String?) -> (url: URL?, problem: String?) {
        guard let value, !value.isEmpty else { return (nil, nil) }
        guard value.hasPrefix("/") else { return (nil, "FANOUS_HOME ignored: \(value) is not an absolute path") }
        return (URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL, nil)
    }

    static func tlsKeychainTag(home: URL?) -> String {
        home.map { "org.fanous.tls@\($0.path)" } ?? "org.fanous.tls"
    }
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
    /// Display modes to put back after show mode (DESIGN.md §9.6); present only while a display is switched.
    public static var displayModesFile: URL { applicationSupport.appending(path: "display-modes.json") }
    /// Show mode on (DESIGN.md §14); present only while show mode is on, so a crash brings the engine back in it.
    public static var showStateFile: URL { applicationSupport.appending(path: "show-state.json") }
    /// Written by the shell right before Engine › Restart Engine: the stop keeps show mode for the next start.
    public static var restartPendingFile: URL { applicationSupport.appending(path: "restart-pending") }
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
