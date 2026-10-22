// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Testing

@testable import LanthornCore

/// Every datagram recorded from real console software must keep parsing.
@Suite struct CaptureTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/captures")

    static func files(_ protocolName: String) -> [URL] {
        let directory = root.appending(path: protocolName)
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "bin" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test func artnetCapturesParse() throws {
        for file in Self.files("artnet") {
            let bytes = Array(try Data(contentsOf: file))
            let packet = try ArtNet.parse(bytes)
            if case .dmx(let dmx) = packet {
                #expect(dmx.data.count >= 2 && dmx.data.count <= 512, Comment(rawValue: file.lastPathComponent))
                #expect(dmx.encoded().count == bytes.count || dmx.data.count % 2 == 1, Comment(rawValue: file.lastPathComponent))
            }
            if case .other = packet { Issue.record("unknown Art-Net opcode in \(file.lastPathComponent)") }
        }
    }

    @Test func sacnCapturesParse() throws {
        var merger = SACNUniverseMerger()
        for file in Self.files("sacn") {
            let bytes = Array(try Data(contentsOf: file))
            let packet = try SACN.parse(bytes)
            if case .data(let data) = packet {
                #expect(data.universe >= 1 && Int(data.universe) <= SACN.maxUniverse, Comment(rawValue: file.lastPathComponent))
                #expect(data.encoded() == bytes, Comment(rawValue: "re-encoding \(file.lastPathComponent) is byte-identical"))
                _ = merger.apply(data, at: 0)
            }
        }
    }

    @Test func oscCapturesParse() throws {
        for file in Self.files("osc") {
            let bytes = Array(try Data(contentsOf: file))
            let packet = try OSCPacket.parse(bytes)
            #expect(packet.encoded() == bytes, Comment(rawValue: "re-encoding \(file.lastPathComponent) is byte-identical"))
        }
    }
}
