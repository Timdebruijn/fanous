// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AppKit
import CryptoKit
import LanthornCore
import WebKit

/// Hosts the web UI and pins the engine's certificate fingerprint
/// (`~/Library/Application Support/Lanthorn/tls/fingerprint.sha256`).
@MainActor
final class BrowserController: NSObject, WKNavigationDelegate {
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
