// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Testing

@testable import FanousCore

@Suite struct ArtNetTests {
    /// ArtDmx as a console sends it: sequence 7, port-address net 1 / sub-net 2 / universe 3, 4 slots.
    static let dmxFixture: [UInt8] = Array("Art-Net\0".utf8) + [0x00, 0x50, 0x00, 0x0E, 0x07, 0x00, 0x23, 0x01, 0x00, 0x04, 10, 20, 30, 40]

    @Test func parsesArtDmx() throws {
        guard case .dmx(let dmx) = try ArtNet.parse(Self.dmxFixture) else { return #expect(Bool(false)) }
        #expect(dmx.sequence == 7)
        #expect(dmx.portAddress == 0x123)
        #expect(dmx.universeID == UniverseID.artnet(net: 1, subnet: 2, universe: 3))
        #expect(dmx.data == [10, 20, 30, 40])
    }

    /// ArtTimeCode as a console broadcasts it (Art-Net 4 table, `docs/timecode-out.md` §4): stream 0, 01:00:12:05 at 25.
    static let timeCodeFixture: [UInt8] = Array("Art-Net\0".utf8) + [0x00, 0x97, 0x00, 0x0E, 0x00, 0x00, 5, 12, 0, 1, 1]

    @Test func parsesArtTimeCode() throws {
        guard case .timeCode(let tc) = try ArtNet.parse(Self.timeCodeFixture) else { return #expect(Bool(false)) }
        #expect(tc.streamID == 0)
        #expect(tc.timecode == Timecode(hours: 1, minutes: 0, seconds: 12, frames: 5, rate: .fps25))
        #expect(Self.timeCodeFixture.count == ArtTimeCode.size)
    }

    @Test func roundTripsArtTimeCodeAtEveryType() throws {
        for (rate, type) in [(TimecodeRate.fps24, UInt8(0)), (.fps25, 1), (.fps2997df, 2), (.fps30, 3)] {
            let packet = ArtTimeCode(streamID: 7, timecode: Timecode(hours: 23, minutes: 59, seconds: 59, frames: rate.nominalFrames - 1, rate: rate))
            let bytes = packet.encoded()
            #expect(bytes.count == 19)
            #expect(bytes[18] == type)
            #expect(try ArtNet.parse(bytes) == .timeCode(packet))
        }
        // no non-drop 29.97 type on the wire: sent as SMPTE 30, read back at 30
        let ndf = ArtTimeCode(timecode: Timecode(hours: 0, minutes: 1, seconds: 0, frames: 2, rate: .fps2997ndf)).encoded()
        #expect(ndf[18] == 3)
        guard case .timeCode(let back) = try ArtNet.parse(ndf) else { return #expect(Bool(false)) }
        #expect(back.timecode == Timecode(hours: 0, minutes: 1, seconds: 0, frames: 2, rate: .fps30))
    }

    @Test func refusesArtTimeCodeOutOfRange() {
        var bytes = Self.timeCodeFixture
        bytes[14] = 25  // frames at 25 fps go to 24
        #expect(throws: ArtNet.ParseError.badField) { try ArtNet.parse(bytes) }
        bytes = Self.timeCodeFixture
        bytes[18] = 4  // no such type
        #expect(throws: ArtNet.ParseError.badField) { try ArtNet.parse(bytes) }
        bytes = Self.timeCodeFixture
        bytes[18] = 2
        bytes[15] = 0
        bytes[16] = 1
        bytes[14] = 1  // 00:01:00;01 does not exist at drop frame
        #expect(throws: ArtNet.ParseError.badField) { try ArtNet.parse(bytes) }
        #expect(throws: ArtNet.ParseError.tooShort) { try ArtNet.parse(Array(Self.timeCodeFixture.prefix(18))) }
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
        #expect(try ArtNet.parse(Array("Art-Net\0".utf8) + [0x00, 0x99]) == nil)
    }

    @Test func parsesPollAndIgnoresSync() throws {
        #expect(try ArtNet.parse(ArtPoll(flags: 2).encoded()) == .poll(ArtPoll(flags: 2, diagPriority: 0)))
        #expect(try ArtNet.parse(Array("Art-Net\0".utf8) + [0x00, 0x52, 0, 14, 0, 0]) == nil)
    }

    @Test func pollReplyLayout() {
        let reply = ArtPollReply(
            ipAddress: [192, 168, 1, 10], net: 1, subnet: 2, shortName: "Fanous", longName: "Fanous Media Server",
            nodeReport: "#0001 [0000] OK", ports: [.init(universe: 3, receiving: true), .init(universe: 4, receiving: false)],
            mac: [1, 2, 3, 4, 5, 6])
        let bytes = reply.encoded()
        #expect(bytes.count == 239)
        #expect(Array(bytes[8..<10]) == [0x00, 0x21])
        #expect(Array(bytes[10..<14]) == [192, 168, 1, 10])
        #expect(Array(bytes[14..<16]) == [0x36, 0x19])
        #expect(Array(bytes[16..<18]) == [0, 1])  // firmware version
        #expect(bytes[18] == 1 && bytes[19] == 2)
        #expect(bytes[20] == 0xFF && bytes[21] == 0xFF)  // OEM unknown until registered
        #expect(Array(bytes[24..<26]) == [0xF0, 0x7F])  // ESTA prototype 0x7FF0, little-endian
        #expect(String(decoding: bytes[26..<32], as: UTF8.self) == "Fanous" && bytes[32] == 0)
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
