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
    public static var certificateFile: URL { tls.appending(path: "certificate.der") }
    public static var fingerprintFile: URL { tls.appending(path: "fingerprint.sha256") }

    public static func ensureDirectories() throws {
        for directory in [applicationSupport, logs, tls] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
