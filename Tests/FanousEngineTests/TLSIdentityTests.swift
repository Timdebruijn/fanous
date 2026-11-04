// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Network
import Security
import Testing

@testable import FanousEngine

/// Spike (OPEN-26): a TLS identity that never touches a keychain. The key is
/// an in-memory SecKey, the identity comes from `SecIdentityCreate` (public in
/// the macOS 27 SDK, 10.12+), and Network.framework must complete a handshake
/// with it. No keychain means no SecurityAgent prompt on ad-hoc builds.
@Suite(.cleansTempFiles) struct TLSIdentityTests {
    /// The file storage is what an unsigned build (this test binary) gets: the data-protection keychain refuses a new key
    /// (errSecMissingEntitlement). Probed with a key under a tag of its own, removed again if the keychain took it; the
    /// tests are then skipped rather than add a key under the production tag (`loadOrCreate` here has no FANOUS_HOME).
    static let fileStorage: Bool = {
        let tag = Data("org.fanous.tls.probe.\(UUID())".utf8)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: tag],
            kSecUseDataProtectionKeychain as String: true,
        ]
        guard SecKeyCreateRandomKey(attributes as CFDictionary, nil) != nil else { return true }
        SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag, kSecUseDataProtectionKeychain as String: true] as CFDictionary)
        return false
    }()

    static func loadOrCreate(_ directory: URL) throws -> TLSIdentity {
        let identity = try TLSIdentity.loadOrCreate(directory: directory, hostnames: ["localhost"], ipAddresses: ["127.0.0.1"], logger: testLogger)
        #expect(identity.storage == .file)
        return identity
    }

    static func mode(_ url: URL) throws -> Int { try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) }

    /// `TLSIdentity.reset` is not tested: it deletes the production-tag key and the "Fanous (" certificates from the
    /// login keychain unless FANOUS_HOME is set.
    @Test(.enabled(if: fileStorage)) func loadOrCreateKeepsTheIdentityInPrivateFiles() throws {
        let directory = try tempDir("tls")
        let first = try Self.loadOrCreate(directory)
        for file in ["certificate.der", "fingerprint.sha256", "private-key.der"] {
            #expect(FileManager.default.fileExists(atPath: directory.appending(path: file).path), "\(file)")
        }
        #expect(try Self.mode(directory.appending(path: "private-key.der")) == 0o600)
        #expect(try Self.mode(directory) == 0o700)
        #expect(try String(contentsOf: directory.appending(path: "fingerprint.sha256"), encoding: .utf8) == first.fingerprintSHA256 + "\n")
        #expect(try Self.loadOrCreate(directory).fingerprintSHA256 == first.fingerprintSHA256)
    }

    @Test(.enabled(if: fileStorage)) func aCorruptCertificateIsRegenerated() throws {
        let directory = try tempDir("tls")
        let first = try Self.loadOrCreate(directory)
        try Data("not a certificate".utf8).write(to: directory.appending(path: "certificate.der"))
        let second = try Self.loadOrCreate(directory)
        #expect(second.fingerprintSHA256 != first.fingerprintSHA256)
        #expect(try Self.loadOrCreate(directory).fingerprintSHA256 == second.fingerprintSHA256)
    }

    /// A key that does not belong to the certificate would fail every handshake; the next start makes a new pair.
    @Test(.enabled(if: fileStorage)) func aKeyThatDoesNotMatchIsRegenerated() throws {
        let directory = try tempDir("tls")
        let first = try Self.loadOrCreate(directory)
        var error: Unmanaged<CFError>?
        let other = try #require(SecKeyCopyExternalRepresentation(try makeKey(), &error) as Data?)
        try other.write(to: directory.appending(path: "private-key.der"))
        #expect(try Self.loadOrCreate(directory).fingerprintSHA256 != first.fingerprintSHA256)
    }

    @Test func inMemoryIdentityServesHandshake() throws {
        let privateKey = try makeKey()
        var error: Unmanaged<CFError>?
        // round-trip through the external representation: that is what a key file on disk would hold
        guard let external = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else { throw error!.takeRetainedValue() }
        let reloadAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256,
        ]
        guard let reloaded = SecKeyCreateWithData(external as CFData, reloadAttributes as CFDictionary, &error) else { throw error!.takeRetainedValue() }
        let (certificate, _) = try TLSIdentity.makeCertificate(privateKey: reloaded, hostnames: ["localhost"], ipAddresses: ["127.0.0.1"])
        let identity = try #require(SecIdentityCreate(nil, certificate, reloaded))

        let serverOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(serverOptions.securityProtocolOptions, sec_identity_create(identity)!)
        let listener = try NWListener(using: NWParameters(tls: serverOptions), on: .any)
        let queue = DispatchQueue(label: "tls-spike")
        let ready = Ready()
        listener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { state in if case .ready = state { ready.serverReady.signal() } }
            connection.start(queue: queue)
        }
        listener.stateUpdateHandler = { state in if case .ready = state { ready.listening.signal() } }
        listener.start(queue: queue)
        #expect(ready.listening.wait(timeout: .now() + 5) == .success)
        let port = try #require(listener.port)

        let clientOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(clientOptions.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
        let client = NWConnection(host: "127.0.0.1", port: port, using: NWParameters(tls: clientOptions))
        client.stateUpdateHandler = { state in
            if case .ready = state { ready.clientReady.signal() }
            if case .failed(let e) = state { ready.failure = "\(e)"; ready.clientReady.signal() }
        }
        client.start(queue: queue)
        #expect(ready.clientReady.wait(timeout: .now() + 5) == .success)
        #expect(ready.failure == nil, Comment(rawValue: ready.failure ?? ""))
        #expect(ready.serverReady.wait(timeout: .now() + 5) == .success)
        client.cancel()
        listener.cancel()
    }

    final class Ready: @unchecked Sendable {
        let listening = DispatchSemaphore(value: 0)
        let serverReady = DispatchSemaphore(value: 0)
        let clientReady = DispatchSemaphore(value: 0)
        var failure: String?
    }
}
