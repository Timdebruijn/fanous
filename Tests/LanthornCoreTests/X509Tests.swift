// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Security
import Testing

@testable import LanthornCore

@Suite struct X509Tests {
    static func sample() -> X509SelfSignedCertificate {
        X509SelfSignedCertificate(
            commonName: "Lanthorn Test",
            serialNumber: [0x01, 0x02, 0x03],
            notBefore: Date(timeIntervalSince1970: 1_790_000_000),
            notAfter: Date(timeIntervalSince1970: 1_790_000_000 + 10 * 365 * 86_400),
            publicKeyX963: [0x04] + [UInt8](repeating: 0x11, count: 32) + [UInt8](repeating: 0x22, count: 32),
            dnsNames: ["localhost", "test.local"],
            ipAddresses: [[127, 0, 0, 1], [UInt8](repeating: 0, count: 15) + [1]])
    }

    @Test func tbsIsAValidSequence() {
        let tbs = Self.sample().tbsCertificate()
        #expect(tbs[0] == 0x30)
        // version [0] EXPLICIT INTEGER 2 comes first inside the sequence
        #expect(Array(tbs[4..<9]) == [0xA0, 0x03, 0x02, 0x01, 0x02])
    }

    @Test func securityFrameworkParsesIt() throws {
        // A syntactically valid cert with a dummy signature: enough for Security to parse subject and SANs.
        let dummySignature = DER.sequence([DER.integer(unsignedBytes: [0x7F]), DER.integer(unsignedBytes: [0x7E])])
        let der = Self.sample().certificate(signature: dummySignature)
        let cert = try #require(SecCertificateCreateWithData(nil, Data(der) as CFData))
        #expect(SecCertificateCopySubjectSummary(cert) as String? == "Lanthorn Test")
        let serial = try #require(SecCertificateCopySerialNumberData(cert, nil) as Data?)
        #expect(Array(serial) == [0x01, 0x02, 0x03])
    }
}
