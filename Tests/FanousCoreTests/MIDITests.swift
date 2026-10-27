// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Testing

@testable import FanousCore

@Suite struct MIDITests {
    @Test func runningStatusRealTimeAndNoteOffByVelocityZero() {
        var parser = MIDIParser()
        // note on ch 1, two more notes under running status, a clock byte in the middle of one, velocity 0 = off
        let messages = parser.feed([0x90, 36, 127, 38, 0xF8, 100, 36, 0])
        #expect(messages == [
            .noteOn(channel: 0, note: 36, velocity: 127), .noteOn(channel: 0, note: 38, velocity: 100), .noteOff(channel: 0, note: 36, velocity: 0),
        ])
        // running status survives across feeds (CoreMIDI packet boundaries)
        #expect(parser.feed([0xB2, 7]) == [])
        #expect(parser.feed([64, 7, 65]) == [.controlChange(channel: 2, controller: 7, value: 64), .controlChange(channel: 2, controller: 7, value: 65)])
        // program change has one data byte; running status keeps working
        #expect(parser.feed([0xC0, 4, 5]) == [.programChange(channel: 0, program: 4), .programChange(channel: 0, program: 5)])
        // system common cancels running status: its data and what follows without a status is dropped
        #expect(parser.feed([0xF1, 0x12, 40, 50]) == [])
        // pitch bend and aftertouch are parsed past, not reported
        #expect(parser.feed([0xE0, 0, 64, 0x80, 60, 0]) == [.noteOff(channel: 0, note: 60, velocity: 0)])
    }

    @Test func showControlFrames() {
        var parser = MIDIParser()
        // GO cue 12.5 list 3 to device 1, lighting format; a running-status CC before it is not disturbed
        let go: [UInt8] = [0xF0, 0x7F, 0x01, 0x02, 0x01, 0x01] + Array("12.5".utf8) + [0x00] + Array("3".utf8) + [0xF7]
        let messages = parser.feed([0xB0, 1, 10] + go)
        #expect(messages.count == 2)
        guard case .showControl(let msc) = messages[1] else { Issue.record("no MSC"); return }
        #expect(msc.knownCommand == .go && msc.cue == "12.5" && msc.cueNumber == 12.5 && msc.list == "3" && msc.path == nil)
        #expect(msc.isAddressed(to: 1) && !msc.isAddressed(to: 2))
        #expect(msc.description == "MSC GO 12.5 · device 1 · format 01")
        // all-call STOP without a cue, RESUME, and a frame split over two feeds
        #expect(parser.feed(MSCMessage(deviceID: 0x7F, format: 0x7F, command: 0x02).sysex) == [.showControl(MSCMessage(deviceID: 0x7F, format: 0x7F, command: 0x02))])
        let resume = MSCMessage(deviceID: 0, command: 0x03, cue: "107")
        #expect(parser.feed(resume.sysex.prefix(5)) == [])
        #expect(parser.feed(resume.sysex.dropFirst(5)) == [.showControl(resume)])
        #expect(MSCMessage(deviceID: 0x7F, command: 1).isAddressed(to: 42))
        // not MSC (universal non-real-time), garbage in a cue field, and a SysEx cut by a status byte
        #expect(parser.feed([0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7]) == [])
        // a cue that is present but no number stays apart from no cue: "1.2.3", a stray byte, an exponent
        #expect(parser.feed([0xF0, 0x7F, 0x00, 0x02, 0x01, 0x01, 0x41, 0xF7]) == [.showControl(MSCMessage(deviceID: 0, command: 1, cue: "A"))])
        for cue in ["1.2.3", "1\u{7}", "1e3", "."] {
            let msc = MSCMessage(deviceID: 0, command: 1, cue: cue)
            #expect(parser.feed(msc.sysex) == [.showControl(msc)])
            #expect(msc.cue != nil && msc.cueNumber == nil, "\(cue)")
        }
        #expect(MSCMessage(deviceID: 0, command: 1).cueNumber == nil && MSCMessage(deviceID: 0, command: 1, cue: "007.50").cueNumber == 7.5)
        #expect(parser.feed([0xF0, 0x7F, 0x00, 0x02, 0x90, 60, 1]) == [.noteOn(channel: 0, note: 60, velocity: 1)])
    }

    @Test func universalPacketsBecomeBytes() {
        // type 2 note on, type 2 program change (two bytes), type 1 clock, then a SysEx over three 64-bit packets
        let sysex = MSCMessage(deviceID: 0x7F, command: 1, cue: "12.5").sysex  // F0 7F 7F 02 01 01 '1' '2' '.' '5' F7
        let body = Array(sysex.dropFirst().dropLast())  // 9 bytes: 6 + 3
        func packet(_ form: UInt32, _ bytes: ArraySlice<UInt8>) -> [UInt32] {
            let b = Array(bytes) + Array(repeating: 0, count: 6 - bytes.count)
            return [0x3000_0000 | form << 20 | UInt32(bytes.count) << 16 | UInt32(b[0]) << 8 | UInt32(b[1]),
                    UInt32(b[2]) << 24 | UInt32(b[3]) << 16 | UInt32(b[4]) << 8 | UInt32(b[5])]
        }
        let words: [UInt32] = [0x2090_247F, 0x20C1_0500, 0x10F8_0000] + packet(1, body[0..<6]) + packet(3, body[6...])
        let bytes = MIDIParser.bytes(ump: words)
        #expect(bytes == [0x90, 0x24, 0x7F, 0xC1, 0x05, 0xF8] + sysex)
        var parser = MIDIParser()
        #expect(parser.feed(bytes).last == .showControl(MSCMessage(deviceID: 0x7F, command: 1, cue: "12.5")))
        // a 128-bit type 5 message is skipped whole
        #expect(MIDIParser.bytes(ump: [0x5000_0000, 1, 2, 3, 0x2080_3C00]) == [0x80, 0x3C, 0x00])
    }
}
