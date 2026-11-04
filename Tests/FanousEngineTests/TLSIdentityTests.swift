// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Security
import Testing

@testable import FanousEngine

/// The TLS identity of an unsigned build (OPEN-26): key and certificate in private files, no keychain, so no
/// SecurityAgent prompt. A handshake with a `makeCertificate` identity: StateServerTests' HTTPS fixture.
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
}
