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
struct TLSIdentityTests {
    @Test func inMemoryIdentityServesHandshake() throws {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: false],
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else { throw error!.takeRetainedValue() }
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
