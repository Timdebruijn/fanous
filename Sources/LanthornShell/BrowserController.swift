// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AppKit
import CryptoKit
import LanthornCore
import WebKit

/// Hosts the web UI and pins the engine's certificate fingerprint
/// (`~/Library/Application Support/Lanthorn/tls/fingerprint.sha256`). A WKWebView without a UI delegate answers
/// every `confirm()` with false and ignores `<input type=file>` and downloads, so this class provides all three.
@MainActor
final class BrowserController: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let webView: WKWebView
    private let url: URL
    private var retryScheduled = false

    init(url: URL) {
        self.url = url
        let configuration = WKWebViewConfiguration()
        configuration.preferences.isElementFullscreenEnabled = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    // MARK: JavaScript dialogs and file pickers

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        await present(alert)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await present(alert) == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return await present(alert) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window = webView.window else { return panel.runModal() == .OK ? panel.urls : nil }
        let response = await panel.beginSheetModal(for: window)
        return response == .OK ? panel.urls : nil
    }

    /// As a sheet on the window when there is one, so the dialog belongs to the UI that asked.
    @discardableResult
    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = webView.window else { return alert.runModal() }
        return await alert.beginSheetModal(for: window)
    }

    // MARK: Downloads (GDTF export, log download, CSV)

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.shouldPerformDownload ? .download : .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard let window = webView.window else { return panel.runModal() == .OK ? panel.url : nil }
        return await panel.beginSheetModal(for: window) == .OK ? panel.url : nil
    }

    func downloadDidFinish(_ download: WKDownload) {}

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        let alert = NSAlert()
        alert.messageText = "The download failed."
        alert.informativeText = error.localizedDescription
        Task { await present(alert) }
    }

    func load() { webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)) }

    /// The engine may still be starting: retry every second until the page loads.
    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            retryScheduled = false
            load()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        scheduleRetry()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        scheduleRetry()
    }

    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else { return (.performDefaultHandling, nil) }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
            let expected = Self.pinnedFingerprint()
        else { return (.cancelAuthenticationChallenge, nil) }
        let der = SecCertificateCopyData(leaf) as Data
        let actual = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            NSLog("certificate fingerprint mismatch: expected %@, got %@", expected, actual)
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    static func pinnedFingerprint() -> String? {
        guard let text = try? String(contentsOf: AppPaths.fingerprintFile, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.count == 64 ? trimmed : nil
    }
}
