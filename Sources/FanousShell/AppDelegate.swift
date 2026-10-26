// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AppKit
import FanousCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: NSWindow?
    private let engine = EngineManager()
    private var browser: BrowserController?
    private var statusItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let browser = BrowserController(url: URL(string: "https://127.0.0.1:8443/")!)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = Attribution.projectName
        window.contentView = browser.webView
        window.setFrameAutosaveName("FanousMain")
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        self.browser = browser
        NSApp.activate()
        // window first: any question about the background service appears as a sheet on it (the page retries until the engine answers)
        engine.start()
        browser.load()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    static let keepEngineOnQuitKey = "KeepEngineOnQuit"

    /// Quitting leaves a service engine running; ask once per quit unless "keep running" was remembered.
    /// A child engine stops with the app (applicationWillTerminate), so there is nothing to ask.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard engine.usesAgent, !UserDefaults.standard.bool(forKey: Self.keepEngineOnQuitKey) else { return .terminateNow }
        // one 1 s probe (plus at most 1 s before the answer): a slow or dead engine never holds the quit for long
        EngineManager.engineAnswers(within: 1) { [weak self] running in
            guard let self, running else { return sender.reply(toApplicationShouldTerminate: true) }
            self.askAboutEngine(sender)
        }
        return .terminateLater
    }

    private func askAboutEngine(_ sender: NSApplication) {
        let alert = NSAlert()
        alert.messageText = "Quit \(Attribution.projectName)?"
        alert.informativeText = "The engine keeps the outputs running after the app quits. Stop it too?"
        alert.addButton(withTitle: "Keep Engine Running")  // first button: default, Return
        alert.addButton(withTitle: "Stop Engine and Quit")
        alert.addButton(withTitle: "Cancel")  // Escape
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        engine.present(alert) { [engine] response in
            switch response {
            case .alertFirstButtonReturn:
                // only "keep running" is remembered; stopping is always asked for
                if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: Self.keepEngineOnQuitKey) }
                sender.reply(toApplicationShouldTerminate: true)
            case .alertSecondButtonReturn:
                // a failed stop shows its own alert and keeps the app open
                sender.reply(toApplicationShouldTerminate: engine.stopEngine())
            default:
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { engine.stopIfChild() }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(
            string: "\(Attribution.text)\n\n\(Attribution.artNetCredit)\n\nGPL-3.0-only with additional terms.")
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: Attribution.projectName,
            .applicationVersion: FanousVersion.string,
            .version: "",
            .credits: credits,
        ])
    }

    @objc func restartEngine(_ sender: Any?) {
        engine.restart()
        browser?.load()
    }

    @objc func startEngine(_ sender: Any?) {
        engine.startEngine()
        browser?.load()
    }

    @objc func stopEngine(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Stop the engine?"
        alert.informativeText = "Outputs go black and the background service is removed until the next start. The project is kept."
        alert.addButton(withTitle: "Stop Engine")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        engine.stopEngine()
    }

    /// Engine menu: refresh the status line each time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let statusItem else { return }
        statusItem.title = "Checking the engine…"
        engine.statusLine { [weak statusItem] line in statusItem?.title = line }
    }

    @objc func openLogs(_ sender: Any?) { NSWorkspace.shared.open(AppPaths.logs) }

    @objc func reloadUI(_ sender: Any?) { browser?.load() }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(Attribution.projectName)", action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(Attribution.projectName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(Attribution.projectName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(submenu: appMenu)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(submenu: editMenu)

        let engineMenu = NSMenu(title: "Engine")
        engineMenu.delegate = self
        let status = NSMenuItem(title: "Engine status unknown", action: nil, keyEquivalent: "")
        status.isEnabled = false
        engineMenu.addItem(status)
        statusItem = status
        engineMenu.addItem(.separator())
        engineMenu.addItem(withTitle: "Reload UI", action: #selector(reloadUI(_:)), keyEquivalent: "r")
        engineMenu.addItem(withTitle: "Start Engine", action: #selector(startEngine(_:)), keyEquivalent: "")
        engineMenu.addItem(withTitle: "Restart Engine", action: #selector(restartEngine(_:)), keyEquivalent: "")
        engineMenu.addItem(withTitle: "Stop Engine…", action: #selector(stopEngine(_:)), keyEquivalent: "")
        engineMenu.addItem(.separator())
        engineMenu.addItem(withTitle: "Open Logs", action: #selector(openLogs(_:)), keyEquivalent: "")
        mainMenu.addItem(submenu: engineMenu)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        mainMenu.addItem(submenu: windowMenu)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}

extension NSMenu {
    fileprivate func addItem(submenu: NSMenu) {
        let item = NSMenuItem()
        item.submenu = submenu
        addItem(item)
    }
}
