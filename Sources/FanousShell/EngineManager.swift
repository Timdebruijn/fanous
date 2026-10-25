// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AppKit
import FanousCore
import Security
import ServiceManagement

/// Bundled: the engine is a LaunchAgent registered through SMAppService.
/// Development (`swift run FanousShell`), or `Fanous.app --engine child`:
/// the engine runs as a child process and nothing is installed.
@MainActor
final class EngineManager {
    static let agentPlist = "org.fanous.engine.plist"
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

    /// One line for the Engine menu: service state plus whether the engine answers on 8443.
    func statusLine(completion: @escaping @MainActor (String) -> Void) {
        let service: String
        if usesAgent {
            switch SMAppService.agent(plistName: Self.agentPlist).status {
            case .enabled: service = "service installed"
            case .requiresApproval: service = "service needs approval in Login Items"
            case .notRegistered: service = "service not installed"
            case .notFound: service = "service plist missing"
            @unknown default: service = "service state unknown"
            }
        } else {
            service = child?.isRunning == true ? "child process" : "no child process"
        }
        var request = URLRequest(url: URL(string: "https://127.0.0.1:8443/healthz")!)
        request.timeoutInterval = 1
        let task = URLSession(configuration: .ephemeral, delegate: TrustAnyLocalhost.shared, delegateQueue: nil).dataTask(with: request) { data, _, _ in
            let version = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["version"] as? String
            let engine = version.map { "Engine \($0) running" } ?? "Engine not running"
            DispatchQueue.main.async { MainActor.assumeIsolated { completion("\(engine) · \(service)") } }
        }
        task.resume()
    }

    /// Start: register the service when needed and kick it; in development start the child.
    func startEngine() {
        if usesAgent {
            startAgent()
            run("/bin/launchctl", ["kickstart", "gui/\(getuid())/org.fanous.engine"])
        } else if child?.isRunning != true {
            startChild()
        }
    }

    /// Stop: a KeepAlive agent only stays down when its registration goes; the next start registers it again.
    func stopEngine() {
        if usesAgent {
            do { try SMAppService.agent(plistName: Self.agentPlist).unregister() } catch { alert("The engine service could not be removed.", "\(error)") }
        } else {
            stopIfChild()
        }
    }

    func restart() {
        if usesAgent {
            run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/org.fanous.engine"])
        } else {
            stopIfChild()
            startChild()
        }
    }

    func stopIfChild() {
        child?.terminate()
        child = nil
    }

    /// No team identifier = ad-hoc signed (local builds). launchd pins a registered agent to its cdhash, which every
    /// rebuild changes; a Developer ID build is pinned to the team instead.
    static var isAdHocSigned: Bool {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code, SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let dict = info as? [String: Any]
        else { return true }
        return dict[kSecCodeInfoTeamIdentifier as String] == nil
    }

    private func startAgent() {
        let service = SMAppService.agent(plistName: Self.agentPlist)
        // an ad-hoc rebuild leaves the agent pinned to the old binary (launchd: EX_CONFIG); register it afresh
        if Self.isAdHocSigned, service.status == .enabled {
            try? service.unregister()
        }
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
            alert.messageText = "Allow Fanous to run its engine in the background"
            alert.informativeText =
                "macOS needs your approval once. Open System Settings › General › Login Items & Extensions and allow Fanous."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn { SMAppService.openSystemSettingsLoginItems() }
        }
    }

    private func startChild() {
        let executable = Bundle.main.executableURL!.deletingLastPathComponent().appending(path: "fanousd")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            NSLog("fanousd not found next to the shell (%@); start it by hand", executable.path)
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

    /// The engine's certificate is self-signed; the shell pins its fingerprint in the web view, this status probe only reads the version.
    final class TrustAnyLocalhost: NSObject, URLSessionDelegate {
        static let shared = TrustAnyLocalhost()
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.host == "127.0.0.1", let trust = challenge.protectionSpace.serverTrust else { return completionHandler(.performDefaultHandling, nil) }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    private func alert(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}
