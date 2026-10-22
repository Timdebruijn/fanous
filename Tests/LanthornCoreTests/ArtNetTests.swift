// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Testing

@testable import LanthornCore

@Suite struct ArtNetTests {
    /// ArtDmx as a console sends it: sequence 7, port-address net 1 / sub-net 2 / universe 3, 4 slots.
    static let dmxFixture: [UInt8] = Array("Art-Net\0".utf8) + [0x00, 0x50, 0x00, 0x0E, 0x07, 0x00, 0x23, 0x01, 0x00, 0x04, 10, 20, 30, 40]

    @Test func parsesArtDmx() throws {
        guard case .dmx(let dmx) = try ArtNet.parse(Self.dmxFixture) else { return #expect(Bool(false)) }
        #expect(dmx.sequence == 7)
        #expect(dmx.net == 1 && dmx.subnet == 2 && dmx.universe == 3)
        #expect(dmx.portAddress == 0x123)
        #expect(dmx.universeID == UniverseID.artnet(net: 1, subnet: 2, universe: 3))
        #expect(dmx.data == [10, 20, 30, 40])
    }

    @Test func roundTripsAndPadsOddLengths() throws {
        let packet = ArtDmx(sequence: 1, portAddress: 0x7FFF, data: [1, 2, 3])
        let bytes = packet.encoded()
        #expect(bytes.count == 18 + 4)
        guard case .dmx(let parsed) = try ArtNet.parse(bytes) else { return #expect(Bool(false)) }
        #expect(parsed.data == [1, 2, 3, 0])
        #expect(parsed.portAddress == 0x7FFF)
        let full = ArtDmx(portAddress: 0, data: [UInt8](repeating: 255, count: 512)).encoded()
        #expect(full.count == 530)
    }

    @Test func rejectsBadPackets() throws {
        #expect(throws: ArtNet.ParseError.tooShort) { try ArtNet.parse([1, 2, 3]) }
        #expect(throws: ArtNet.ParseError.badHeader) { try ArtNet.parse(Array("Art-Nat\0".utf8) + [0, 0x50, 0, 14]) }
        var short = Self.dmxFixture
        short[17] = 200  // claims 200 slots, only 4 present
        #expect(throws: ArtNet.ParseError.badLength) { try ArtNet.parse(short) }
        var old = Self.dmxFixture
        old[11] = 13
        #expect(throws: ArtNet.ParseError.badVersion) { try ArtNet.parse(old) }
        #expect(try ArtNet.parse(Array("Art-Net\0".utf8) + [0x00, 0x99]) == .other(opCode: 0x9900))
    }

    @Test func parsesPollAndSync() throws {
        #expect(try ArtNet.parse(ArtPoll(flags: 2).encoded()) == .poll(ArtPoll(flags: 2, diagPriority: 0)))
        #expect(try ArtNet.parse(Array("Art-Net\0".utf8) + [0x00, 0x52, 0, 14, 0, 0]) == .sync)
    }

    @Test func pollReplyLayout() {
        let reply = ArtPollReply(
            ipAddress: [192, 168, 1, 10], net: 1, subnet: 2, shortName: "Lanthorn", longName: "Lanthorn Media Server",
            nodeReport: "#0001 [0000] OK", ports: [.init(universe: 3, receiving: true), .init(universe: 4, receiving: false)],
            mac: [1, 2, 3, 4, 5, 6])
        let bytes = reply.encoded()
        #expect(bytes.count == 239)
        #expect(Array(bytes[8..<10]) == [0x00, 0x21])
        #expect(Array(bytes[10..<14]) == [192, 168, 1, 10])
        #expect(Array(bytes[14..<16]) == [0x36, 0x19])
        #expect(bytes[18] == 1 && bytes[19] == 2)
        #expect(bytes[20] == 0xFF && bytes[21] == 0xFF)  // OEM unknown until registered
        #expect(String(decoding: bytes[26..<34], as: UTF8.self) == "Lanthorn")
        #expect(bytes[43] == 0)  // short name null-terminated within 18
        #expect(bytes[173] == 2)  // NumPortsLo
        #expect(bytes[174] == 0x80 && bytes[175] == 0x80)  // PortTypes: output
        #expect(bytes[182] == 0x80 && bytes[183] == 0x00)  // GoodOutput
        #expect(bytes[190] == 3 && bytes[191] == 4)  // SwOut
        #expect(bytes[200] == ArtPollReply.styleMediaServer)
        #expect(Array(bytes[201..<207]) == [1, 2, 3, 4, 5, 6])
        #expect(bytes[211] == 1)  // BindIndex
        #expect(bytes[212] == 0x08)  // Status2: 15-bit port-address
    }

    @Test func groupsUniversesIntoReplies() {
        let universes = (0..<6).map { UniverseID(.artnet, $0) } + [UniverseID.artnet(net: 1, subnet: 0, universe: 0), UniverseID(.sacn, 1)]
        let replies = ArtPollReply.replies(universes: universes, ipAddress: [10, 0, 0, 1], shortName: "L", longName: "L", nodeReport: "")
        #expect(replies.count == 3)
        #expect(replies[0].ports.map(\.universe) == [0, 1, 2, 3] && replies[0].bindIndex == 1)
        #expect(replies[1].ports.map(\.universe) == [4, 5] && replies[1].bindIndex == 2)
        #expect(replies[2].net == 1 && replies[2].ports.map(\.universe) == [0] && replies[2].bindIndex == 3)
        #expect(ArtPollReply.replies(universes: [], ipAddress: [10, 0, 0, 1], shortName: "L", longName: "L", nodeReport: "").count == 1)
    }
}
