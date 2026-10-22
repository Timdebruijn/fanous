// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AppKit
import LanthornCore
import ServiceManagement

/// Bundled: the engine is a LaunchAgent registered through SMAppService.
/// Development (`swift run LanthornShell`), or `Lanthorn.app --engine child`:
/// the engine runs as a child process and nothing is installed.
@MainActor
final class EngineManager {
    static let agentPlist = "org.lanthorn.engine.plist"
    private var child: Process?

    var isBundled: Bool {
        FileManager.default.fileExists(
            atPath: Bundle.main.bundleURL.appending(path: "Contents/Library/LaunchAgents/\(Self.agentPlist)").path)
    }

    var usesAgent: Bool {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--engine"), arguments.indices.contains(index + 1) {
            return arguments[index + 1] != "child"
        }
        return isBundled
    }

    func start() {
        if usesAgent { startAgent() } else { startChild() }
    }

    func restart() {
        if usesAgent {
            run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/org.lanthorn.engine"])
        } else {
            stopIfChild()
            startChild()
        }
    }

    func stopIfChild() {
        child?.terminate()
        child = nil
    }

    private func startAgent() {
        let service = SMAppService.agent(plistName: Self.agentPlist)
        if service.status == .notRegistered || service.status == .notFound {
            do {
                try service.register()
            } catch {
                alert("The engine could not be registered as a background service.", "\(error)")
                return
            }
        }
        if service.status == .requiresApproval {
            let alert = NSAlert()
            alert.messageText = "Allow Lanthorn to run its engine in the background"
            alert.informativeText =
                "macOS needs your approval once. Open System Settings › General › Login Items & Extensions and allow Lanthorn."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn { SMAppService.openSystemSettingsLoginItems() }
        }
    }

    private func startChild() {
        let executable = Bundle.main.executableURL!.deletingLastPathComponent().appending(path: "lanthornd")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            NSLog("lanthornd not found next to the shell (%@); start it by hand", executable.path)
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--foreground"]
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do {
            try process.run()
            child = process
        } catch {
            alert("The engine could not be started.", "\(error)")
        }
    }

    private func run(_ tool: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try? process.run()
    }

    private func alert(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}
