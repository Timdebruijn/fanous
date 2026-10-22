// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Testing

@testable import LanthornCore

@Suite struct OSCTests {
    @Test func messageRoundTripWithEveryType() throws {
        let message = OSCMessage("/a/b", [
            .int32(-5), .float32(0.5), .string("hi"), .blob([1, 2, 3]), .int64(1 << 40), .double(2.5), .timetag(1),
            .bool(true), .bool(false), .null, .impulse,
        ])
        let bytes = message.encoded()
        #expect(bytes.count % 4 == 0)
        #expect(Array(bytes[0..<8]) == Array("/a/b\0\0\0\0".utf8))
        #expect(try OSCPacket.parse(bytes) == .message(message))
    }

    @Test func alignmentOfStringsAndBlobs() {
        #expect(OSCMessage("/abc").encoded() == Array("/abc\0\0\0\0,\0\0\0".utf8))
        #expect(OSCMessage("/ab", [.blob([1])]).encoded().count == 4 + 4 + 8)
    }

    @Test func bundlesNest() throws {
        let inner = OSCBundle(timetag: 42, elements: [.message(OSCMessage("/x", [.int32(1)]))])
        let bundle = OSCBundle(elements: [.message(OSCMessage("/y")), .bundle(inner)])
        let bytes = bundle.encoded()
        #expect(Array(bytes[0..<8]) == Array("#bundle\0".utf8))
        #expect(try OSCPacket.parse(bytes) == .bundle(bundle))
    }

    @Test func parseErrors() {
        #expect(throws: OSCParseError.truncated) { try OSCPacket.parse([]) }
        #expect(throws: OSCParseError.badAddress) { try OSCPacket.parse(Array("abc\0".utf8)) }
        #expect(throws: OSCParseError.badTypeTags) { try OSCPacket.parse(Array("/a\0\0if\0\0".utf8)) }
        #expect(throws: OSCParseError.truncated) { try OSCPacket.parse(Array("/a\0\0,i\0\0".utf8) + [0, 0]) }
        #expect(throws: OSCParseError.unsupportedType("q")) { try OSCPacket.parse(Array("/a\0\0,q\0\0".utf8)) }
        #expect(throws: OSCParseError.badBundle) { try OSCPacket.parse(Array("#bundlx\0".utf8) + [0, 0, 0, 0, 0, 0, 0, 1]) }
    }

    @Test func missingTypeTagsIsAnEmptyMessage() throws {
        #expect(try OSCPacket.parse(Array("/go\0".utf8)) == .message(OSCMessage("/go")))
    }

    @Test func slipFramingAcrossFeeds() {
        let packet: [UInt8] = [0x01, 0xC0, 0x02, 0xDB, 0x03]
        let encoded = SLIPDecoder.encode(packet)
        #expect(encoded == [0xC0, 0x01, 0xDB, 0xDC, 0x02, 0xDB, 0xDD, 0x03, 0xC0])
        var decoder = SLIPDecoder()
        #expect(decoder.feed(Array(encoded[0..<4])) == [])
        #expect(decoder.feed(Array(encoded[4...]) + encoded) == [packet, packet])
    }

    @Test func addressMapParsesParameters() {
        func command(_ address: String, _ args: [OSCArgument]) -> OSCCommand? {
            OSCAddressMap.command(for: OSCMessage(address, args))
        }
        #expect(command("/lanthorn/layer/3/intensity", [.float32(0.5)]) == .setParameter(.layer(3), .layer(.intensity), raw: 32768))
        #expect(command("/lanthorn/layer/3/intensity", [.int32(255)]) == .setParameter(.layer(3), .layer(.intensity), raw: 255))
        #expect(command("/lanthorn/layer/3/intensity", [.float32(7)]) == .setParameter(.layer(3), .layer(.intensity), raw: 65535))
        #expect(command("/lanthorn/layer/1/playMode", [.int32(17)]) == .setParameter(.layer(1), .layer(.playMode), raw: 17))
        #expect(command("/lanthorn/output/1/blend", [.int32(200)]) == .setParameter(.output(1), .output(.blend), raw: 200))
        #expect(command("/lanthorn/master/intensity", [.bool(true)]) == .setParameter(.master, .master(.intensity), raw: 65535))
        #expect(command("/lanthorn/layer/2/media", [.int32(12), .int32(4)]) == .setMedia(layer: 2, folder: 12, file: 4))
        #expect(command("/lanthorn/layer/2/retrigger", []) == .retrigger(layer: 2))
        #expect(command("/lanthorn/cue/go", []) == .cueGo)
        #expect(command("/lanthorn/cue/back", []) == .cueBack)
        #expect(command("/lanthorn/cue/goto", [.float32(3)]) == .cueGoto(3))
        #expect(command("/lanthorn/cue/12.5/go", []) == .cueGoto(12.5))
        #expect(command("/lanthorn/show/lock", [.bool(true)]) == .showLock(true))
        #expect(command("/lanthorn/show/mode", [.int32(0)]) == .showMode(false))
        #expect(command("/lanthorn/timecode/enable", [.impulse]) == .timecodeEnable(true))
        #expect(command("/lanthorn/project/load", [.string("Show.lanthorn")]) == .projectLoad("Show.lanthorn"))
        #expect(command("/other/thing", [.int32(1)]) == nil)
        #expect(command("/lanthorn/layer/0/intensity", [.int32(1)]) == nil)
        #expect(command("/lanthorn/layer/1/nonsense", [.int32(1)]) == nil)
        #expect(command("/lanthorn/layer/1/intensity", [.string("x")]) == nil)
        #expect(OSCAddressMap.address(.layer(3), .layer(.intensity)) == "/lanthorn/layer/3/intensity")
        #expect(OSCAddressMap.address(.master, .master(.speed)) == "/lanthorn/master/speed")
    }
}
