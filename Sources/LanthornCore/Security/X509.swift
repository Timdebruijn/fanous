// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

/// A self-signed X.509 v3 server certificate for an ECDSA P-256 key.
/// Pure encoding: the caller signs `tbsCertificate()` (ECDSA with SHA-256,
/// X9.62 DER signature) and passes the signature to `certificate(signature:)`.
public struct X509SelfSignedCertificate: Sendable {
    public var commonName: String
    /// Positive big-endian serial number (≤ 20 bytes per RFC 5280).
    public var serialNumber: [UInt8]
    public var notBefore: Date
    public var notAfter: Date
    /// ANSI X9.63 uncompressed point: 0x04 || X || Y (65 bytes).
    public var publicKeyX963: [UInt8]
    public var dnsNames: [String]
    /// Raw addresses: 4 bytes IPv4, 16 bytes IPv6.
    public var ipAddresses: [[UInt8]]

    public init(
        commonName: String, serialNumber: [UInt8], notBefore: Date, notAfter: Date,
        publicKeyX963: [UInt8], dnsNames: [String], ipAddresses: [[UInt8]]
    ) {
        self.commonName = commonName
        self.serialNumber = serialNumber
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.publicKeyX963 = publicKeyX963
        self.dnsNames = dnsNames
        self.ipAddresses = ipAddresses
    }

    static let ecdsaWithSHA256 = "1.2.840.10045.4.3.2"
    static let idECPublicKey = "1.2.840.10045.2.1"
    static let prime256v1 = "1.2.840.10045.3.1.7"
    static let commonNameOID = "2.5.4.3"
    static let basicConstraints = "2.5.29.19"
    static let keyUsage = "2.5.29.15"
    static let extendedKeyUsage = "2.5.29.37"
    static let serverAuth = "1.3.6.1.5.5.7.3.1"
    static let subjectAltName = "2.5.29.17"

    var signatureAlgorithm: [UInt8] { DER.sequence([DER.objectIdentifier(Self.ecdsaWithSHA256)]) }

    var name: [UInt8] {
        DER.sequence([
            DER.set([DER.sequence([DER.objectIdentifier(Self.commonNameOID), DER.utf8String(commonName)])])
        ])
    }

    var subjectPublicKeyInfo: [UInt8] {
        DER.sequence([
            DER.sequence([DER.objectIdentifier(Self.idECPublicKey), DER.objectIdentifier(Self.prime256v1)]),
            DER.bitString(publicKeyX963),
        ])
    }

    func extensions() -> [UInt8] {
        func ext(_ oid: String, critical: Bool, _ value: [UInt8]) -> [UInt8] {
            DER.sequence([DER.objectIdentifier(oid)] + (critical ? [DER.boolean(true)] : []) + [DER.octetString(value)])
        }
        let altNames =
            dnsNames.map { DER.implicitPrimitive(2, Array($0.utf8)) }
            + ipAddresses.map { DER.implicitPrimitive(7, $0) }
        return DER.sequence([
            ext(Self.basicConstraints, critical: true, DER.sequence([])),  // cA = FALSE (default)
            ext(Self.keyUsage, critical: true, DER.bitString([0x80], unusedBits: 7)),  // digitalSignature
            ext(Self.extendedKeyUsage, critical: false, DER.sequence([DER.objectIdentifier(Self.serverAuth)])),
            ext(Self.subjectAltName, critical: false, DER.sequence(altNames)),
        ])
    }

    public func tbsCertificate() -> [UInt8] {
        DER.sequence([
            DER.explicit(0, DER.integer(2)),  // v3
            DER.integer(unsignedBytes: serialNumber),
            signatureAlgorithm,
            name,  // issuer == subject
            DER.sequence([DER.time(notBefore), DER.time(notAfter)]),
            name,
            subjectPublicKeyInfo,
            DER.explicit(3, extensions()),
        ])
    }

    public func certificate(signature: [UInt8]) -> [UInt8] {
        DER.sequence([tbsCertificate(), signatureAlgorithm, DER.bitString(signature)])
    }
}
