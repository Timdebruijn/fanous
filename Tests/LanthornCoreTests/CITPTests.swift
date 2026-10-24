// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Testing

@testable import LanthornCore

@Suite struct CITPTests {
    static let allVersions: [MSEXVersion] = [.v1_0, .v1_1, .v1_2]
    static let uuid = "550e8400-e29b-41d4-a716-446655440000"
    /// Non-ASCII on purpose: accent, symbol and CJK, all in the BMP.
    static let name = "Zoë's Clip ✓ 映像"

    /// CITP header bytes written out by hand: "CITP", version 1.0, RequestIndex, MessageSize, part 0 of 1, ContentType.
    static func header(size: UInt32, _ contentType: String, requestIndex: UInt16 = 0) -> [UInt8] {
        Array("CITP".utf8) + [1, 0] + le16(requestIndex) + le32(size) + [1, 0, 0, 0] + Array(contentType.utf8)
    }

    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }

    static func roundTrip(_ packet: CITPPacket, _ version: MSEXVersion = .v1_2) throws -> CITPPacket {
        try CITPPacket.parse(packet.encoded(version: version))
    }

    // MARK: header

    @Test func headerLayoutAndRoundTrip() throws {
        let header = CITPHeader(requestIndex: 0x0102, messagePartCount: 3, messagePart: 1, messageSize: 0x0A0B0C0D, contentType: "MSEX")
        let bytes = header.encode()
        #expect(bytes == [
            0x43, 0x49, 0x54, 0x50,  // "CITP"
            0x01, 0x00,  // version 1.0
            0x02, 0x01,  // RequestIndex
            0x0D, 0x0C, 0x0B, 0x0A,  // MessageSize
            0x03, 0x00,  // MessagePartCount
            0x01, 0x00,  // MessagePart
            0x4D, 0x53, 0x45, 0x58,  // "MSEX"
        ])
        #expect(bytes.count == CITPHeader.size)
        #expect(try CITPHeader.parse(bytes) == header)
        #expect(try CITPHeader.parse(bytes + [9, 9]) == header)  // trailing bytes are not the header's business
    }

    @Test func multicastConstants() {
        #expect(CITPMulticast.address == "224.0.0.180")
        #expect(CITPMulticast.addressSince2014 == "239.224.0.180")
        #expect(CITPMulticast.port == 4809)
    }

    // MARK: PINF

    @Test func peerLocationByteExact() throws {
        let packet = CITPPacket.peerLocation(PeerLocation(listeningTCPPort: 5000, type: "MediaServer", name: "Lanthorn", state: "Idle"))
        let expected: [UInt8] =
            [
                0x43, 0x49, 0x54, 0x50,  // "CITP"
                0x01, 0x00,  // version 1.0
                0x00, 0x00,  // RequestIndex
                0x34, 0x00, 0x00, 0x00,  // MessageSize = 52
                0x01, 0x00, 0x00, 0x00,  // MessagePartCount 1, MessagePart 0
                0x50, 0x49, 0x4E, 0x46,  // ContentType "PINF"
                0x50, 0x4C, 0x6F, 0x63,  // PINF ContentType "PLoc"
                0x88, 0x13,  // ListeningTCPPort = 5000
            ] + Array("MediaServer\0Lanthorn\0Idle\0".utf8)
        #expect(packet.encoded() == expected)
        #expect(expected.count == 52)
        #expect(try CITPPacket.parse(expected) == packet)
    }

    @Test func peerLocationAndNameRoundTrip() throws {
        let location = CITPPacket.peerLocation(PeerLocation(listeningTCPPort: 0, type: "LightingConsole", name: "Eos – Büro", state: ""))
        #expect(try Self.roundTrip(location) == location)
        let name = CITPPacket.peerName("Lanthorn")
        #expect(name.encoded() == Self.header(size: 33, "PINF") + Array("PNam".utf8) + Array("Lanthorn\0".utf8))
        #expect(try Self.roundTrip(name) == name)
    }

    @Test func requestIndexGoesIntoTheHeader() throws {
        let bytes = CITPPacket.peerName("x").encoded(requestIndex: 513)
        #expect(try CITPHeader.parse(bytes).requestIndex == 513)
        #expect(Array(bytes[6..<8]) == [0x01, 0x02])
    }

    // MARK: MSEX 1.2-only handshake

    @Test func clientInformationByteExact() throws {
        // Versions are u16 with major in the high byte, little endian: minor comes first on the wire.
        let packet = CITPPacket.clientInformation(ClientInformation(supportedVersions: [.v1_0, .v1_1, .v1_2]))
        let expected =
            Self.header(size: 33, "MSEX") + [0x01, 0x02] + Array("CInf".utf8) + [0x03, 0x00, 0x01, 0x01, 0x01, 0x02, 0x01]
        #expect(packet.encoded() == expected)
        #expect(try CITPPacket.parse(expected) == packet)
        // CInf only exists in 1.2: an older requested version is lifted to 1.2.
        #expect(packet.encoded(version: .v1_0) == expected)
    }

    @Test func nackRoundTripKeepsInResponseTo() throws {
        let packet = CITPPacket.nack(Nack(receivedContentType: "GELT"))
        let bytes = packet.encoded(version: .v1_1, requestIndex: 42)
        #expect(bytes == Self.header(size: 30, "MSEX", requestIndex: 42) + [0x01, 0x02] + Array("Nack".utf8) + Array("GELT".utf8))
        #expect(try CITPHeader.parse(bytes).requestIndex == 42)
        #expect(try CITPPacket.parse(bytes) == packet)
    }

    // MARK: SInf

    static func serverInfo(_ version: MSEXVersion) -> ServerInformation {
        var info = ServerInformation(
            version: version, productName: name, productVersionMajor: 0, productVersionMinor: 9,
            layerDMXSources: ["ArtNet/0/0/1", "sACN/0/1/1"])
        if version >= .v1_2 {
            info.uuid = uuid
            info.productVersionBugfix = 3
            info.supportedVersions = [.v1_0, .v1_1, .v1_2]
            info.supportedLibraryTypes = 1
            info.thumbnailFormats = ["RGB8", "JPEG", "PNG "]
            info.streamFormats = ["JPEG", "RGB8", "fJPG"]
        }
        return info
    }

    @Test(arguments: allVersions) func serverInformationRoundTrip(version: MSEXVersion) throws {
        let packet = CITPPacket.serverInformation(Self.serverInfo(version))
        #expect(try Self.roundTrip(packet, version) == packet)
    }

    @Test func serverInformationCarriesUUIDOnlyIn12() throws {
        let long = CITPPacket.serverInformation(Self.serverInfo(.v1_2)).encoded(version: .v1_2)
        #expect(Array(long[26..<62]) == Array(Self.uuid.utf8))
        guard case .serverInformation(let parsed) = try CITPPacket.parse(long) else { Issue.record("not SInf"); return }
        #expect(parsed.uuid == Self.uuid)
        #expect(parsed.version == .v1_2)

        // 1.0/1.1 layout is just name, product version, layers: the UUID and 1.2 lists are dropped.
        let short = CITPPacket.serverInformation(Self.serverInfo(.v1_2)).encoded(version: .v1_1)
        guard case .serverInformation(let old) = try CITPPacket.parse(short) else { Issue.record("not SInf"); return }
        #expect(old.version == .v1_1)
        #expect(old.uuid == "")
        #expect(old.supportedVersions.isEmpty && old.thumbnailFormats.isEmpty)
        #expect(old.productName == Self.name)
        #expect(old.layerDMXSources == ["ArtNet/0/0/1", "sACN/0/1/1"])
    }

    @Test func serverInformation10ByteExact() throws {
        let packet = CITPPacket.serverInformation(
            ServerInformation(version: .v1_0, productName: "A", productVersionMajor: 2, productVersionMinor: 3, layerDMXSources: ["x"]))
        let expected =
            Self.header(size: 26 + 4 + 2 + 1 + 2, "MSEX") + [0x01, 0x00] + Array("SInf".utf8)
            + [0x41, 0x00, 0x00, 0x00]  // ProductName "A" (ucs2, NUL terminated)
            + [0x02, 0x03]  // ProductVersionMajor/Minor
            + [0x01]  // LayerCount
            + [0x78, 0x00]  // DMXSource "x"
        #expect(packet.encoded(version: .v1_0) == expected)
        #expect(try CITPPacket.parse(expected) == packet)
    }

    // MARK: LSta

    @Test func layerStatusWithTwoLayers() throws {
        func layers(_ version: MSEXVersion) -> [LayerStatus] {
            let wide = version >= .v1_2
            return [
                LayerStatus(
                    layerNumber: 0, physicalOutput: 1, mediaLibraryType: 1, mediaLibraryID: .topLevel(2), mediaNumber: 5,
                    mediaName: Self.name, mediaPosition: 120, mediaLength: 4800, mediaFPS: 25,
                    statusFlags: wide ? LayerStatus.playing | LayerStatus.playbackLooping : LayerStatus.playing),
                LayerStatus(layerNumber: 1, physicalOutput: 1, mediaNumber: 1, mediaName: "", statusFlags: 0),
            ]
        }
        for version in Self.allVersions {
            let packet = CITPPacket.layerStatus(layers(version))
            #expect(try Self.roundTrip(packet, version) == packet)
        }
        // 1.2 swaps the 1-byte library number for type (1) + MSEXLibraryId (4): 4 bytes more per layer.
        let sizes = Self.allVersions.map { CITPPacket.layerStatus(layers($0)).encoded(version: $0).count }
        #expect(sizes[0] == sizes[1])
        #expect(sizes[2] == sizes[0] + 2 * 4)

        let deep = LayerStatus(layerNumber: 3, mediaLibraryType: 2, mediaLibraryID: MSEXLibraryID(level: 2, level1: 4, level2: 7), mediaName: "fx")
        #expect(try Self.roundTrip(.layerStatus([deep])) == .layerStatus([deep]))
    }

    // MARK: element libraries and elements

    @Test(arguments: allVersions) func libraryRequestsRoundTrip(version: MSEXVersion) throws {
        let parent: MSEXLibraryID = version >= .v1_1 ? MSEXLibraryID(level: 1, level1: 2) : MSEXLibraryID()
        let geli = CITPPacket.getElementLibraryInformation(
            GetElementLibraryInformation(version: version, libraryType: 1, parentID: parent, libraryNumbers: [0, 1, 7]))
        #expect(try Self.roundTrip(geli, version) == geli)
        let all = CITPPacket.getElementLibraryInformation(GetElementLibraryInformation(version: version))
        #expect(try Self.roundTrip(all, version) == all)

        let gein = CITPPacket.getElementInformation(
            GetElementInformation(version: version, libraryType: 1, libraryID: .topLevel(2), elementNumbers: [4, 5, 6]))
        #expect(try Self.roundTrip(gein, version) == gein)

        // Fixed part of each layout (everything but the number list), from the spec field tables.
        let geliFixed = [2, 6, 7][Self.allVersions.firstIndex(of: version)!]
        let geinFixed = [3, 6, 7][Self.allVersions.firstIndex(of: version)!]
        #expect(geli.encoded(version: version).count == 26 + geliFixed + 3)
        #expect(gein.encoded(version: version).count == 26 + geinFixed + 3)
    }

    @Test(arguments: allVersions) func elementLibraryInformationRoundTrip(version: MSEXVersion) throws {
        let library = ElementLibrary(
            id: .topLevel(3), serialNumber: version >= .v1_2 ? 99 : 0, dmxRangeMin: 1, dmxRangeMax: 20, name: Self.name,
            libraryCount: version >= .v1_1 ? 4 : 0, elementCount: 12)
        let packet = CITPPacket.elementLibraryInformation(ElementLibraryInformation(version: version, libraryType: 1, libraries: [library]))
        let bytes = packet.encoded(version: version)
        #expect(try CITPPacket.parse(bytes) == packet)
        // Per entry: 4 / 8 / 14 fixed bytes plus the ucs2 name; header: type + u8/u8/u16 count.
        let nameBytes = (Self.name.utf16.count + 1) * 2
        let expected = 26 + [2, 2, 3][Self.allVersions.firstIndex(of: version)!] + [4, 8, 14][Self.allVersions.firstIndex(of: version)!] + nameBytes
        #expect(bytes.count == expected)
    }

    @Test func nestedLibraryIdsSurvive1_1AndUp() throws {
        let deep = MSEXLibraryID(level: 3, level1: 9, level2: 8, level3: 7)
        let packet = CITPPacket.elementLibraryInformation(
            ElementLibraryInformation(
                version: .v1_2, libraryType: 2, libraries: [ElementLibrary(id: deep, serialNumber: 1, name: "Effects / Blur", elementCount: 300)]))
        #expect(try Self.roundTrip(packet) == packet)
    }

    @Test(arguments: allVersions) func mediaElementInformationRoundTrip(version: MSEXVersion) throws {
        let elements = [
            MediaElement(
                number: 1, serialNumber: version >= .v1_2 ? 5 : 0, dmxRangeMin: 0, dmxRangeMax: 9, name: Self.name,
                versionTimestamp: 1_700_000_000, width: 1920, height: 1080, length: 250, fps: 25),
            MediaElement(number: 2, name: "plain.mov", width: 640, height: 360, length: 10, fps: 30),
        ]
        let packet = CITPPacket.mediaElementInformation(MediaElementInformation(version: version, libraryID: .topLevel(2), elements: elements))
        let bytes = packet.encoded(version: version)
        #expect(try CITPPacket.parse(bytes) == packet)
        // Per element: 20 fixed bytes (24 with SerialNumber in 1.2) plus the name; header: library ref + count.
        let index = Self.allVersions.firstIndex(of: version)!
        let names = [Self.name, "plain.mov"].map { ($0.utf16.count + 1) * 2 }.reduce(0, +)
        let element = version >= .v1_2 ? 24 : 20
        #expect(bytes.count == 26 + [2, 5, 6][index] + 2 * element + names)
    }

    @Test(arguments: allVersions) func thumbnailRequestAndResponseRoundTrip(version: MSEXVersion) throws {
        let request = CITPPacket.getElementThumbnail(
            GetElementThumbnail(
                version: version, format: version >= .v1_2 ? "PNG " : "JPEG", width: 160, height: 90,
                flags: GetElementThumbnail.preserveAspectRatio, libraryType: 1, libraryID: .topLevel(2), elementNumbers: [1, 2, 3]))
        #expect(try Self.roundTrip(request, version) == request)
        // Fixed part: 12 / 15 / 16 bytes (spec totals) plus the 3 element numbers.
        let index = Self.allVersions.firstIndex(of: version)!
        #expect(request.encoded(version: version).count == 26 + [12, 15, 16][index] + 3)

        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4, 0xFF, 0xD9]
        let thumb = CITPPacket.elementThumbnail(
            ElementThumbnail(version: version, libraryType: 1, libraryID: .topLevel(2), elementNumber: 7, width: 160, height: 90, buffer: jpeg))
        #expect(try Self.roundTrip(thumb, version) == thumb)
        // 13 fixed bytes in 1.0, 16 in 1.1 and (no separate layout in the spec) 1.2.
        #expect(thumb.encoded(version: version).count == 26 + [13, 16, 16][index] + jpeg.count)
    }

    // MARK: streaming

    @Test func requestStreamRoundTrip() throws {
        for version in Self.allVersions {
            let packet = CITPPacket.requestStream(
                RequestStream(version: version, sourceIdentifier: 3, frameFormat: "JPEG", frameWidth: 320, frameHeight: 180, fps: 10, timeout: 5))
            #expect(try Self.roundTrip(packet, version) == packet)
        }
        let bytes = CITPPacket.requestStream(RequestStream(sourceIdentifier: 3, frameWidth: 320, frameHeight: 180, fps: 10, timeout: 5)).encoded()
        #expect(Array(bytes[26...]) == [3, 0] + Array("JPEG".utf8) + [0x40, 0x01, 0xB4, 0x00, 10, 5])
    }

    @Test func streamFrameWithJPEGBlob() throws {
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0] + (0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 31) } + [0xFF, 0xD9]
        for version in Self.allVersions {
            let packet = CITPPacket.streamFrame(
                StreamFrame(
                    version: version, mediaServerUUID: version >= .v1_2 ? Self.uuid : "", sourceIdentifier: 1, frameFormat: "JPEG",
                    frameWidth: 320, frameHeight: 180, buffer: jpeg))
            let bytes = packet.encoded(version: version)
            #expect(try CITPPacket.parse(bytes) == packet)
            // 12 fixed bytes, plus the 36-byte UUID in 1.2.
            #expect(bytes.count == 26 + (version >= .v1_2 ? 36 : 0) + 12 + jpeg.count)
        }
        let bytes = CITPPacket.streamFrame(StreamFrame(mediaServerUUID: Self.uuid, sourceIdentifier: 1, frameWidth: 1, frameHeight: 1, buffer: jpeg)).encoded()
        #expect(Array(bytes[26..<62]) == Array(Self.uuid.utf8))
        #expect(Array(bytes.suffix(2)) == [0xFF, 0xD9])
    }

    @Test func oversizedBufferIsCutToTheSizeField() throws {
        let big = [UInt8](repeating: 7, count: 70_000)
        let bytes = CITPPacket.streamFrame(StreamFrame(sourceIdentifier: 1, frameWidth: 1, frameHeight: 1, buffer: big)).encoded()
        guard case .streamFrame(let frame) = try CITPPacket.parse(bytes) else { Issue.record("not StFr"); return }
        #expect(frame.buffer.count == 0xFFFF)
    }

    // MARK: robustness

    @Test func messageSizeEqualsEncodedLength() throws {
        let packets: [CITPPacket] = [
            .peerName("a"), .peerLocation(PeerLocation(listeningTCPPort: 1, type: "t", name: "n", state: "s")),
            .clientInformation(ClientInformation(supportedVersions: [.v1_2])), .serverInformation(Self.serverInfo(.v1_2)),
            .nack(Nack(receivedContentType: "GELT")), .layerStatus([LayerStatus(layerNumber: 0, mediaName: Self.name)]),
            .getElementLibraryInformation(GetElementLibraryInformation()),
            .elementLibraryInformation(ElementLibraryInformation(libraries: [ElementLibrary(id: .topLevel(1), name: Self.name)])),
            .getElementInformation(GetElementInformation(libraryID: .topLevel(1))),
            .mediaElementInformation(MediaElementInformation(libraryID: .topLevel(1), elements: [MediaElement(number: 0, name: Self.name)])),
            .getElementThumbnail(GetElementThumbnail(width: 1, height: 1, libraryID: .topLevel(1))),
            .elementThumbnail(ElementThumbnail(libraryID: .topLevel(1), elementNumber: 0, width: 1, height: 1, buffer: [1, 2, 3])),
            .requestStream(RequestStream(sourceIdentifier: 0, frameWidth: 1, frameHeight: 1, fps: 1, timeout: 1)),
            .streamFrame(StreamFrame(sourceIdentifier: 0, frameWidth: 1, frameHeight: 1, buffer: [1])),
            .unknown(contentType: "SDMX", body: [1, 2, 3]),
        ]
        for packet in packets {
            for version in Self.allVersions {
                let bytes = packet.encoded(version: version)
                let header = try CITPHeader.parse(bytes)
                #expect(Int(header.messageSize) == bytes.count)
                #expect(header.messagePartCount == 1 && header.messagePart == 0)
                // parse -> encode reproduces the bytes (CInf/Nack stay 1.2, SInf drops what the version lacks).
                let parsed = try CITPPacket.parse(bytes)
                #expect(parsed.encoded(version: version) == bytes)
            }
        }
    }

    @Test func truncatedPacketsThrow() throws {
        let packet = CITPPacket.peerLocation(PeerLocation(listeningTCPPort: 5000, type: "MediaServer", name: "Lanthorn", state: "Idle"))
        let bytes = packet.encoded()
        #expect(throws: CITPError.truncated) { try CITPPacket.parse([]) }
        #expect(throws: CITPError.truncated) { try CITPPacket.parse(Array(bytes.prefix(19))) }
        #expect(throws: CITPError.truncated) { try CITPPacket.parse(Array(bytes.dropLast())) }

        // MessageSize is consistent with the bytes, but the body ends inside a string / a counted buffer.
        func shrunk(_ bytes: [UInt8], by n: Int) -> [UInt8] {
            var cut = Array(bytes.dropLast(n))
            cut.replaceSubrange(8..<12, with: Self.le32(UInt32(cut.count)))
            return cut
        }
        #expect(throws: CITPError.truncated) { try CITPPacket.parse(shrunk(bytes, by: 1)) }
        let frame = CITPPacket.streamFrame(StreamFrame(sourceIdentifier: 1, frameWidth: 2, frameHeight: 2, buffer: [UInt8](repeating: 1, count: 100)))
        #expect(throws: CITPError.truncated) { try CITPPacket.parse(shrunk(frame.encoded(), by: 10)) }
        let sinf = CITPPacket.serverInformation(Self.serverInfo(.v1_2))
        for n in [1, 5, 30] {
            #expect(throws: CITPError.truncated) { try CITPPacket.parse(shrunk(sinf.encoded(), by: n)) }
        }
    }

    @Test func malformedHeadersThrow() {
        var bytes = CITPPacket.peerName("x").encoded()
        let ok = bytes
        bytes[0] = 0x58
        #expect(throws: CITPError.badHeader) { try CITPPacket.parse(bytes) }
        bytes = ok
        bytes[4] = 2  // CITP major version
        #expect(throws: CITPError.badHeader) { try CITPPacket.parse(bytes) }
        bytes = ok
        bytes.replaceSubrange(8..<12, with: Self.le32(19))
        #expect(throws: CITPError.badSize) { try CITPPacket.parse(bytes) }
        bytes = ok
        bytes.replaceSubrange(12..<14, with: Self.le16(2))
        #expect(throws: CITPError.fragmented) { try CITPPacket.parse(bytes) }
        let futureMSEX = Self.header(size: 26, "MSEX") + [2, 0] + Array("CInf".utf8)
        #expect(throws: CITPError.unsupportedVersion) { try CITPPacket.parse(futureMSEX) }
    }

    @Test func unknownContentTypesRoundTrip() throws {
        // Another CITP layer entirely.
        let sdmx = Self.header(size: 29, "SDMX", requestIndex: 7) + [1, 2, 3, 4, 5, 6, 7, 8, 9]
        let parsedSDMX = try CITPPacket.parse(sdmx)
        #expect(parsedSDMX == .unknown(contentType: "SDMX", body: [1, 2, 3, 4, 5, 6, 7, 8, 9]))
        #expect(parsedSDMX.encoded(requestIndex: 7) == sdmx)

        // An MSEX message this codec does not model (EEIn): spec says ignore it, bytes are kept.
        let eein = Self.header(size: 31, "MSEX") + [1, 1] + Array("EEIn".utf8) + [0xDE, 0xAD, 0xBE, 0xEF, 0x00]
        let parsedEEIn = try CITPPacket.parse(eein)
        #expect(parsedEEIn == .unknown(contentType: "MSEX", body: [1, 1] + Array("EEIn".utf8) + [0xDE, 0xAD, 0xBE, 0xEF, 0x00]))
        #expect(parsedEEIn.encoded(version: .v1_2) == eein)

        // An unknown PINF message.
        let pinf = Self.header(size: 26, "PINF") + Array("Zzzz".utf8) + [1, 2]
        let parsedPINF = try CITPPacket.parse(pinf)
        #expect(parsedPINF == .unknown(contentType: "PINF", body: Array("Zzzz".utf8) + [1, 2]))
        #expect(parsedPINF.encoded() == pinf)
    }

    @Test func trailingBytesAfterMessageSizeAreIgnored() throws {
        let packet = CITPPacket.peerName("x")
        #expect(try CITPPacket.parse(packet.encoded() + [1, 2, 3]) == packet)
    }
}
