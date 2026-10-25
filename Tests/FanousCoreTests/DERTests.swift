// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Testing

@testable import FanousCore

@Suite struct DERTests {
    @Test func integers() {
        #expect(DER.integer(0) == [0x02, 0x01, 0x00])
        #expect(DER.integer(127) == [0x02, 0x01, 0x7F])
        #expect(DER.integer(128) == [0x02, 0x02, 0x00, 0x80])
        #expect(DER.integer(256) == [0x02, 0x02, 0x01, 0x00])
        #expect(DER.integer(unsignedBytes: [0x00, 0x00, 0x05]) == [0x02, 0x01, 0x05])
        #expect(DER.integer(unsignedBytes: [0xFF]) == [0x02, 0x02, 0x00, 0xFF])
        #expect(DER.integer(unsignedBytes: []) == [0x02, 0x01, 0x00])
    }

    @Test func lengths() {
        #expect(DER.length(0) == [0x00])
        #expect(DER.length(127) == [0x7F])
        #expect(DER.length(128) == [0x81, 0x80])
        #expect(DER.length(256) == [0x82, 0x01, 0x00])
        #expect(DER.length(65_536) == [0x83, 0x01, 0x00, 0x00])
    }

    @Test func objectIdentifiers() {
        #expect(DER.objectIdentifier("1.2.840.10045.4.3.2") == [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
        #expect(DER.objectIdentifier("2.5.4.3") == [0x06, 0x03, 0x55, 0x04, 0x03])
        #expect(DER.objectIdentifier("1.3.6.1.5.5.7.3.1") == [0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01])
    }

    @Test func times() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21T14:13:20Z
        #expect(DER.time(date) == [0x17, 0x0D] + Array("260921141320Z".utf8))
        let far = Date(timeIntervalSince1970: 2_600_000_000)  // 2052-05-22T14:13:20Z
        #expect(DER.time(far) == [0x18, 0x0F] + Array("20520522141320Z".utf8))
    }

    @Test func tagsAndStrings() {
        #expect(DER.explicit(0, DER.integer(2)) == [0xA0, 0x03, 0x02, 0x01, 0x02])
        #expect(DER.bitString([0x80], unusedBits: 7) == [0x03, 0x02, 0x07, 0x80])
        #expect(DER.boolean(true) == [0x01, 0x01, 0xFF])
        #expect(DER.utf8String("ab") == [0x0C, 0x02, 0x61, 0x62])
        #expect(DER.sequence([]) == [0x30, 0x00])
    }
}
