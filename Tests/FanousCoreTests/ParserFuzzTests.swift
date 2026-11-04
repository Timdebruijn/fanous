// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Testing

@testable import FanousCore

/// Every parser on the network boundary survives hostile input (DESIGN.md §18): each sample, real captures and
/// encoded messages, is cut at every length and has every byte replaced by five values. The parser may throw or
/// return nothing; it never traps. Two traps found by reading in the 2026-11-04 test review would have failed here:
/// an OSC blob without padding before a string, and a negative Content-Length.
@Suite struct ParserFuzzTests {
    enum Parser: CaseIterable {
        case artNet, sacn, osc, citp, webSocket, http, sync, midi

        var samples: [[UInt8]] {
            switch self {
            case .artNet: CaptureTests.files("artnet").compactMap { try? Array(Data(contentsOf: $0)) }
            case .sacn: CaptureTests.files("sacn").compactMap { try? Array(Data(contentsOf: $0)) }
            case .osc:
                [
                    // a string right after an odd-sized blob: a cut inside the blob's padding once trapped the parser
                    OSCMessage("/layer/1/intensity", [
                        .int32(-5), .float32(0.5), .blob([1, 2, 3]), .string("hi"), .int64(1 << 40), .double(2.5), .timetag(1),
                        .bool(true), .bool(false), .null, .impulse,
                    ]).encoded(),
                    OSCPacket.bundle(OSCBundle(elements: [.message(OSCMessage("/a", [.int32(1)])), .message(OSCMessage("/b"))])).encoded(),
                ]
            case .citp:
                [
                    CITPTests.header(size: 33, "MSEX") + [0x01, 0x02] + Array("CInf".utf8) + [0x03, 0x00, 0x01, 0x01, 0x01, 0x02, 0x01],
                    CITPTests.pinf("PNam", CITPTests.ucs2("Console")),
                    CITPPacket.nack(receivedContentType: "GELT").encoded(),
                ]
            case .webSocket:
                [
                    [0x8A, 0x85, 0x37, 0xFA, 0x21, 0x3D, 0x7F, 0x9F, 0x4D, 0x51, 0x58],  // the RFC's masked pong
                    [0x81, 0x80 | 126, 0, 200, 1, 2, 3, 4] + WebSocketFrame.mask([UInt8](repeating: 0x41, count: 200), key: (1, 2, 3, 4)),
                ]
            case .http:
                [
                    Array("GET /index.html?x=1 HTTP/1.1\r\nHost: a\r\nContent-Length: 0\r\nconnection: close\r\n\r\nrest".utf8),
                    Array("POST /api/ingest HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\n\r\nhello".utf8),
                ]
            case .sync:
                {
                    var buffer: [UInt8] = []
                    SyncPacket(machineID: SyncPacketTests.machine, tick: 1, sendTime: 2, layers: (0..<3).map(SyncPacketTests.layer)).encode(into: &buffer)
                    return [buffer]
                }()
            case .midi:
                [[0x90, 36, 127, 38, 0xF8, 100, 36, 0, 0xB2, 7, 64, 0xF1, 0x12, 0xF0, 0x7F, 0x01, 0x02, 0x01, 0x01] + Array("12.5".utf8) + [0x00, 0x33, 0xF7]]
            }
        }

        func parse(_ bytes: [UInt8]) {
            switch self {
            case .artNet: _ = try? ArtNet.parse(bytes)
            case .sacn: _ = try? SACN.parse(bytes)
            case .osc: _ = try? OSCPacket.parse(bytes)
            case .citp: _ = try? CITPClientMessage.parse(bytes)
            case .webSocket: _ = try? WebSocketFrame.parse(bytes)
            case .http: _ = try? HTTPRequest.parse(bytes)
            case .sync:
                guard let packet = try? SyncPacket.decode(bytes) else { return }
                var out: [UInt8] = []
                packet.encode(into: &out)
            case .midi:
                var parser = MIDIParser()
                _ = parser.feed(bytes)
            }
        }
    }

    @Test(arguments: Parser.allCases) func cutAndMutatedInputNeverTraps(_ parser: Parser) {
        let samples = parser.samples
        #expect(!samples.isEmpty)
        for sample in samples {
            for length in 0...sample.count { parser.parse(Array(sample.prefix(length))) }
            for i in sample.indices {
                for value: UInt8 in [0, 1, 0x7F, 0x80, 0xFF] {
                    var mutated = sample
                    mutated[i] = value
                    parser.parse(mutated)
                }
            }
        }
    }

    @Test func everyMTCQuarterFrameByteIsAccepted() {
        var decoder = MTCDecoder()
        for byte in UInt8.min...UInt8.max { _ = decoder.quarterFrame(byte) }
    }
}
