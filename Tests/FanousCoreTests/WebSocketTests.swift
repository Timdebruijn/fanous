// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Testing

@testable import FanousCore

private let key: (UInt8, UInt8, UInt8, UInt8) = (0x37, 0xFA, 0x21, 0x3D)
private let keyBytes: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]

/// Deterministic, non-constant test payload.
private func sample(_ count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 7) }
}

/// Builds a masked client frame by hand, independent of WebSocketFrame's own encoder.
private func clientFrame(_ first: UInt8, lengthBytes: [UInt8], _ payload: [UInt8]) -> [UInt8] {
    let masked = payload.enumerated().map { $0.element ^ keyBytes[$0.offset % 4] }
    return [first] + lengthBytes + keyBytes + masked
}

private func request(_ raw: String) throws -> HTTPRequest {
    try #require(try HTTPRequest.parse(Array(raw.utf8))).request
}

private let upgradeHead =
    "GET /ws HTTP/1.1\r\nHost: a\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
    + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"

@Suite struct WebSocketFrameTests {
    // MARK: RFC 6455 §5.7 examples

    @Test func parsesMaskedHelloFromRFC() throws {
        let raw: [UInt8] = [0x81, 0x85, 0x37, 0xFA, 0x21, 0x3D, 0x7F, 0x9F, 0x4D, 0x51, 0x58]
        let (frame, length) = try #require(try WebSocketFrame.parse(raw))
        #expect(frame == WebSocketFrame.text("Hello"))
        #expect(length == raw.count)
        #expect(frame.serializedMasked(key: key) == raw)
    }

    @Test func serializesUnmaskedHelloFromRFC() {
        #expect(WebSocketFrame.text("Hello").serialized() == [0x81, 0x05, 0x48, 0x65, 0x6C, 0x6C, 0x6F])
    }

    @Test func pingAndPongFromRFC() throws {
        let hello = Array("Hello".utf8)
        // Unmasked ping and pong, as a server would send them.
        #expect(WebSocketFrame(opcode: .ping, payload: hello).serialized() == [0x89, 0x05] + hello)
        #expect(WebSocketFrame.pong(hello).serialized() == [0x8A, 0x05] + hello)
        // Masked pong from the RFC, as a client would send it.
        let raw: [UInt8] = [0x8A, 0x85, 0x37, 0xFA, 0x21, 0x3D, 0x7F, 0x9F, 0x4D, 0x51, 0x58]
        let (frame, length) = try #require(try WebSocketFrame.parse(raw))
        #expect(frame == .pong(hello))
        #expect(length == raw.count)
        // A masked ping parses too.
        var ping = raw
        ping[0] = 0x89
        #expect(try #require(try WebSocketFrame.parse(ping)).frame == WebSocketFrame(opcode: .ping, payload: hello))
    }

    @Test func sixteenBitLength() throws {
        let payload = sample(256)
        let raw = clientFrame(0x82, lengthBytes: [0xFE, 0x01, 0x00], payload)
        let (frame, length) = try #require(try WebSocketFrame.parse(raw))
        #expect(frame == .binary(payload))
        #expect(length == raw.count)
        #expect(Array(WebSocketFrame.binary(payload).serialized().prefix(4)) == [0x82, 0x7E, 0x01, 0x00])
    }

    @Test func sixtyFourBitLength() throws {
        let payload = sample(65_536)
        let raw = clientFrame(0x82, lengthBytes: [0xFF, 0, 0, 0, 0, 0, 0x01, 0, 0], payload)
        let (frame, length) = try #require(try WebSocketFrame.parse(raw))
        #expect(frame == .binary(payload))
        #expect(length == raw.count)
        #expect(
            Array(WebSocketFrame.binary(payload).serialized().prefix(10))
                == [0x82, 0x7F, 0, 0, 0, 0, 0, 0x01, 0, 0])
    }

    @Test func fragmentedTextParsesAsTwoFrames() throws {
        let first = WebSocketFrame(fin: false, opcode: .text, payload: Array("Hel".utf8))
        let second = WebSocketFrame(fin: true, opcode: .continuation, payload: Array("lo".utf8))
        let stream = first.serializedMasked(key: key) + second.serializedMasked(key: key)
        let one = try #require(try WebSocketFrame.parse(stream))
        #expect(one.frame == first)
        #expect(!one.frame.fin)
        // `length` is how the caller advances through a buffer holding several frames.
        let two = try #require(try WebSocketFrame.parse(Array(stream[one.length...])))
        #expect(two.frame == second)
        #expect(two.frame.fin)
        #expect(one.length + two.length == stream.count)
    }

    // MARK: Incomplete and invalid input

    @Test func incompleteInputReturnsNil() throws {
        for raw in [
            [0x81, 0x85, 0x37, 0xFA, 0x21, 0x3D, 0x7F, 0x9F, 0x4D, 0x51, 0x58],
            clientFrame(0x82, lengthBytes: [0xFE, 0x01, 0x00], sample(256)),
            clientFrame(0x82, lengthBytes: [0xFF, 0, 0, 0, 0, 0, 0, 0x01, 0], sample(256)),
        ] {
            for cut in 0..<raw.count {
                #expect(try WebSocketFrame.parse(Array(raw.prefix(cut))) == nil, "prefix of \(cut) bytes")
            }
            #expect(try WebSocketFrame.parse(raw) != nil)
        }
    }

    @Test func unmaskedClientFrameThrows() {
        #expect(throws: WebSocketFrame.Error.unmaskedClientFrame) {
            try WebSocketFrame.parse([0x81, 0x05, 0x48, 0x65, 0x6C, 0x6C, 0x6F])
        }
        // Reported from the two header bytes alone, without waiting for the payload.
        #expect(throws: WebSocketFrame.Error.unmaskedClientFrame) { try WebSocketFrame.parse([0x81, 0x05]) }
        // A server frame is not a valid client frame.
        let serverFrame = WebSocketFrame.text("x").serialized()
        #expect(throws: WebSocketFrame.Error.unmaskedClientFrame) { try WebSocketFrame.parse(serverFrame) }
    }

    @Test func reservedBitsAndUnknownOpcodesThrow() {
        for first: UInt8 in [0xC1, 0xA1, 0x91] {
            #expect(throws: WebSocketFrame.Error.reservedBits) { try WebSocketFrame.parse([first, 0x80, 0, 0, 0, 0]) }
        }
        for first: UInt8 in [0x83, 0x87, 0x8B, 0x8F] {
            #expect(throws: WebSocketFrame.Error.unknownOpcode) { try WebSocketFrame.parse([first, 0x80, 0, 0, 0, 0]) }
        }
    }

    @Test func controlFrameLimits() throws {
        let ok = clientFrame(0x89, lengthBytes: [0x80 | 125], sample(125))
        #expect(try #require(try WebSocketFrame.parse(ok)).frame.payload.count == 125)

        let tooLong = clientFrame(0x89, lengthBytes: [0xFE, 0x00, 126], sample(126))
        #expect(throws: WebSocketFrame.Error.controlFrameTooLong) { try WebSocketFrame.parse(tooLong) }
        // Rejected from the header alone.
        #expect(throws: WebSocketFrame.Error.controlFrameTooLong) { try WebSocketFrame.parse(Array(tooLong.prefix(4))) }

        // Control frames cannot be fragmented.
        let fragmentedPing = clientFrame(0x09, lengthBytes: [0x80], [])
        #expect(throws: WebSocketFrame.Error.controlFrameTooLong) { try WebSocketFrame.parse(fragmentedPing) }
        let longClose = clientFrame(0x88, lengthBytes: [0xFE, 0x00, 126], sample(126))
        #expect(throws: WebSocketFrame.Error.controlFrameTooLong) { try WebSocketFrame.parse(longClose) }
    }

    @Test func payloadLimit() throws {
        let raw = clientFrame(0x82, lengthBytes: [0x80 | 11], sample(11))
        #expect(throws: WebSocketFrame.Error.payloadTooLarge) { try WebSocketFrame.parse(raw, maxPayload: 10) }
        #expect(try WebSocketFrame.parse(raw, maxPayload: 11) != nil)
        // A 1 TiB claim is refused from the header, before any payload arrives.
        let huge: [UInt8] = [0x82, 0xFF, 0, 0, 0x01, 0, 0, 0, 0, 0, 1, 2, 3, 4]
        #expect(throws: WebSocketFrame.Error.payloadTooLarge) { try WebSocketFrame.parse(huge) }
        // Even with no limit at all, a near-Int.max length must not overflow.
        let enormous: [UInt8] = [0x82, 0xFF, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 1, 2, 3, 4]
        #expect(try WebSocketFrame.parse(enormous, maxPayload: Int.max) == nil)
    }

    @Test func sixtyFourBitLengthTopBitMustBeClear() {
        let raw: [UInt8] = [0x82, 0xFF, 0x80, 0, 0, 0, 0, 0, 0, 0x01, 1, 2, 3, 4, 0]
        #expect(throws: WebSocketFrame.Error.badLength) { try WebSocketFrame.parse(raw) }
    }

    // MARK: Close frames and round trips

    @Test func closeFrameRoundTrip() throws {
        let close = WebSocketFrame.close(code: 1000, reason: "bye")
        #expect(close.opcode == .close)
        #expect(close.fin)
        #expect(close.serialized() == [0x88, 0x05, 0x03, 0xE8, 0x62, 0x79, 0x65])
        let (parsed, _) = try #require(try WebSocketFrame.parse(close.serializedMasked(key: key)))
        #expect(parsed == close)
        #expect(parsed.closeCode == 1000)
        #expect(String(decoding: parsed.payload.dropFirst(2), as: UTF8.self) == "bye")
    }

    @Test func closeCodeNeedsTwoBytes() {
        #expect(WebSocketFrame(opcode: .close).closeCode == nil)
        #expect(WebSocketFrame(opcode: .close, payload: [0x03]).closeCode == nil)
        #expect(WebSocketFrame.close(code: 1001).closeCode == 1001)
        #expect(WebSocketFrame.close(code: 0xFFFF).closeCode == 0xFFFF)
    }

    @Test func closeReasonIsCutToFitAControlFrame() throws {
        let close = WebSocketFrame.close(code: 1008, reason: String(repeating: "é", count: 100))
        #expect(close.payload.count <= 125)
        #expect(String(bytes: close.payload.dropFirst(2), encoding: .utf8) != nil)
        #expect(try WebSocketFrame.parse(close.serializedMasked(key: key)) != nil)
    }

    @Test(arguments: [0, 125, 126, 65_535, 65_536])
    func roundTripsAtLengthBoundaries(count: Int) throws {
        let payload = sample(count)
        let frame = WebSocketFrame.binary(payload)

        let masked = frame.serializedMasked(key: (0xDE, 0xAD, 0xBE, 0xEF))
        let parsed = try #require(try WebSocketFrame.parse(masked))
        #expect(parsed.frame == frame)
        #expect(parsed.length == masked.count)

        // Header is 2, 4 or 10 bytes depending on the length form, +4 for the mask on client frames.
        let header = count < 126 ? 2 : count <= 0xFFFF ? 4 : 10
        #expect(frame.serialized().count == header + count)
        #expect(masked.count == header + 4 + count)
    }

    @Test func maskIsItsOwnInverse() {
        let payload = sample(37)
        let once = WebSocketFrame.mask(payload, key: key)
        #expect(once != payload)
        #expect(WebSocketFrame.mask(once, key: key) == payload)
    }
}

@Suite struct WebSocketHandshakeTests {
    @Test func otherStatusesStillCarryContentLength() {
        let wire = String(decoding: HTTPResponse(status: 204).serialized(), as: UTF8.self)
        #expect(wire == "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
    }

    @Test func headerMatchingIsCaseInsensitiveAndListAware() throws {
        let firefox =
            "GET /ws HTTP/1.1\r\nhost: a\r\nupgrade: WebSocket\r\nconnection: keep-alive, Upgrade\r\n"
            + "sec-websocket-key: abc\r\nsec-websocket-version: 13\r\n\r\n"
        #expect(WebSocketHandshake.isUpgrade(try request(firefox)))
        let split =
            "GET /ws HTTP/1.1\r\nUpgrade: websocket\r\nConnection: keep-alive\r\nConnection: upgrade\r\n"
            + "Sec-WebSocket-Key: abc\r\nSec-WebSocket-Version: 13\r\n\r\n"
        #expect(WebSocketHandshake.isUpgrade(try request(split)))
    }

    @Test func isUpgradeRejectsEverythingElse() throws {
        #expect(!WebSocketHandshake.isUpgrade(try request("GET /ws HTTP/1.1\r\nHost: a\r\n\r\n")))

        let variants = [
            upgradeHead.replacingOccurrences(of: "GET", with: "POST"),
            upgradeHead.replacingOccurrences(of: "Upgrade: websocket\r\n", with: ""),
            upgradeHead.replacingOccurrences(of: "Upgrade: websocket", with: "Upgrade: h2c"),
            upgradeHead.replacingOccurrences(of: "Connection: Upgrade", with: "Connection: keep-alive"),
            upgradeHead.replacingOccurrences(of: "Sec-WebSocket-Version: 13", with: "Sec-WebSocket-Version: 8"),
            upgradeHead.replacingOccurrences(of: "Sec-WebSocket-Version: 13\r\n", with: ""),
            upgradeHead.replacingOccurrences(of: "dGhlIHNhbXBsZSBub25jZQ==", with: ""),
            upgradeHead.replacingOccurrences(of: "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n", with: ""),
            upgradeHead.replacingOccurrences(of: "HTTP/1.1", with: "HTTP/1.0"),
        ]
        for raw in variants {
            let parsed = try request(raw)
            #expect(!WebSocketHandshake.isUpgrade(parsed), "\(raw)")
        }
    }
}
