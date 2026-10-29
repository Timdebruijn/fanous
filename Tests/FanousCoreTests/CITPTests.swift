// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Testing

@testable import FanousCore

/// The codec is one way: what the server sends is pinned as bytes (`CITPPacket.encoded`), what a console sends
/// is decoded from bytes written out here (`CITPClientMessage.parse`).
@Suite struct CITPTests {
    static let allVersions: [MSEXVersion] = [.v1_0, .v1_1, .v1_2]
    static let uuid = "550e8400-e29b-41d4-a716-446655440000"
    /// Non-ASCII on purpose: accent, symbol and CJK, all in the BMP.
    static let name = "Zoë's Clip ✓ 映像"

    /// CITP header bytes written out by hand: "CITP", version 1.0, RequestIndex, MessageSize, part 0 of 1, ContentType.
    static func header(size: UInt32, _ contentType: String, requestIndex: UInt16 = 0) -> [UInt8] {
        Array("CITP".utf8) + [1, 0] + le16(requestIndex) + le32(size) + [1, 0, 0, 0] + Array(contentType.utf8)
    }

    /// A whole MSEX message: CITP header, MSEX version, cookie, payload.
    static func msex(_ cookie: String, _ payload: [UInt8], version: MSEXVersion = .v1_2) -> [UInt8] {
        header(size: UInt32(26 + payload.count), "MSEX") + [version.major, version.minor] + Array(cookie.utf8) + payload
    }

    /// A whole PINF message: CITP header, cookie, payload.
    static func pinf(_ cookie: String, _ payload: [UInt8]) -> [UInt8] {
        header(size: UInt32(24 + payload.count), "PINF") + Array(cookie.utf8) + payload
    }

    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    /// NUL-terminated little-endian UTF-16.
    static func ucs2(_ text: String) -> [UInt8] { text.utf16.flatMap { le16($0) } + [0, 0] }

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

    // MARK: PINF

    @Test func peerLocationByteExact() throws {
        let packet = CITPPacket.peerLocation(PeerLocation(listeningTCPPort: 5000, type: "MediaServer", name: "Fanous", state: "Idle"))
        let expected: [UInt8] =
            [
                0x43, 0x49, 0x54, 0x50,  // "CITP"
                0x01, 0x00,  // version 1.0
                0x00, 0x00,  // RequestIndex
                0x32, 0x00, 0x00, 0x00,  // MessageSize = 50
                0x01, 0x00, 0x00, 0x00,  // MessagePartCount 1, MessagePart 0
                0x50, 0x49, 0x4E, 0x46,  // ContentType "PINF"
                0x50, 0x4C, 0x6F, 0x63,  // PINF ContentType "PLoc"
                0x88, 0x13,  // ListeningTCPPort = 5000
            ] + Array("MediaServer\0Fanous\0Idle\0".utf8)
        #expect(packet.encoded() == expected)
        #expect(expected.count == 50)
    }

    @Test func peerNameDecodes() throws {
        #expect(try CITPClientMessage.parse(Self.pinf("PNam", Array("Eos – Büro\0".utf8))) == .peerName("Eos – Büro"))
    }

    @Test func requestIndexGoesIntoTheHeader() throws {
        let bytes = CITPPacket.peerLocation(PeerLocation(listeningTCPPort: 0, type: "t", name: "n", state: "s")).encoded(requestIndex: 513)
        #expect(try CITPHeader.parse(bytes).requestIndex == 513)
        #expect(Array(bytes[6..<8]) == [0x01, 0x02])
    }

    // MARK: MSEX 1.2-only handshake

    @Test func clientInformationDecodes() throws {
        // Versions are u16 with major in the high byte, little endian: minor comes first on the wire.
        let bytes = Self.header(size: 33, "MSEX") + [0x01, 0x02] + Array("CInf".utf8) + [0x03, 0x00, 0x01, 0x01, 0x01, 0x02, 0x01]
        #expect(try CITPClientMessage.parse(bytes) == .clientInformation(ClientInformation(supportedVersions: [.v1_0, .v1_1, .v1_2])))
    }

    @Test func nackKeepsInResponseTo() throws {
        // Nack only exists in 1.2: an older requested version is lifted to 1.2.
        let bytes = CITPPacket.nack(Nack(receivedContentType: "GELT")).encoded(version: .v1_1, requestIndex: 42)
        #expect(bytes == Self.header(size: 30, "MSEX", requestIndex: 42) + [0x01, 0x02] + Array("Nack".utf8) + Array("GELT".utf8))
        #expect(try CITPHeader.parse(bytes).requestIndex == 42)
    }

    // MARK: SInf

    static let serverInfo = ServerInformation(
        version: .v1_2, uuid: uuid, productName: name, productVersionMajor: 0, productVersionMinor: 9, productVersionBugfix: 3,
        supportedVersions: [.v1_0, .v1_1, .v1_2], supportedLibraryTypes: 1, thumbnailFormats: ["RGB8", "JPEG", "PNG "],
        streamFormats: ["JPEG", "RGB8", "fJPG"], layerDMXSources: ["ArtNet/0/0/1", "sACN/0/1/1"])

    @Test func serverInformation12ByteExact() throws {
        let packet = CITPPacket.serverInformation(
            ServerInformation(
                uuid: Self.uuid, productName: "A", productVersionMajor: 2, productVersionMinor: 3, productVersionBugfix: 4,
                supportedVersions: [.v1_0, .v1_2], supportedLibraryTypes: 1, thumbnailFormats: ["JPEG", "RGB8"], streamFormats: ["JPEG"],
                layerDMXSources: ["x"]))
        var payload = Array(Self.uuid.utf8) + [0x41, 0x00, 0x00, 0x00]  // UUID, ProductName "A" (ucs2)
        payload += [0x02, 0x03, 0x04]  // ProductVersionMajor/Minor/Bugfix
        payload += [0x02, 0x00, 0x01, 0x02, 0x01]  // SupportedMSEXVersions 1.0, 1.2
        payload += [0x01, 0x00]  // SupportedLibraryTypes
        payload += [0x02] + Array("JPEGRGB8".utf8) + [0x01] + Array("JPEG".utf8)  // ThumbnailFormats, StreamFormats
        payload += [0x01, 0x78, 0x00]  // LayerCount, DMXSource "x"
        #expect(packet.encoded() == Self.msex("SInf", payload))
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
    }

    @Test func serverInformationCarriesUUIDOnlyIn12() throws {
        let long = CITPPacket.serverInformation(Self.serverInfo).encoded(version: .v1_2)
        #expect(Array(long[26..<62]) == Array(Self.uuid.utf8))

        // 1.0/1.1 layout is just name, product version, layers: the UUID and 1.2 lists are dropped.
        let short = CITPPacket.serverInformation(Self.serverInfo).encoded(version: .v1_1)
        let payload = Self.ucs2(Self.name) + [0, 9, 2] + Array("ArtNet/0/0/1\0sACN/0/1/1\0".utf8)
        #expect(short == Self.msex("SInf", payload, version: .v1_1))
    }

    // MARK: LSta

    @Test func layerStatusByteExact() throws {
        let layer = LayerStatus(
            layerNumber: 0, physicalOutput: 1, mediaLibraryType: 1, mediaLibraryID: .topLevel(2), mediaNumber: 5, mediaName: "A",
            mediaPosition: 120, mediaLength: 4800, mediaFPS: 25, statusFlags: LayerStatus.playing | LayerStatus.playbackLooping)
        let tail: [UInt8] = [5] + Self.ucs2("A") + Self.le32(120) + Self.le32(4800) + [25] + Self.le32(5)
        // count, layer, output, then 1.2: library type + MSEXLibraryId; 1.0/1.1: the library number alone.
        #expect(CITPPacket.layerStatus([layer]).encoded() == Self.msex("LSta", [1, 0, 1, 1, 1, 2, 0, 0] + tail))
        for version: MSEXVersion in [.v1_0, .v1_1] {
            #expect(CITPPacket.layerStatus([layer]).encoded(version: version) == Self.msex("LSta", [1, 0, 1, 2] + tail, version: version))
        }
    }

    // MARK: element libraries and elements

    @Test(arguments: allVersions) func libraryRequestsDecode(version: MSEXVersion) throws {
        let count: [UInt8] = version >= .v1_2 ? [3, 0] : [3]
        let none: [UInt8] = version >= .v1_2 ? [0, 0] : [0]
        let id: [UInt8] = version >= .v1_1 ? [1, 2, 0, 0] : [2]
        let parent: [UInt8] = version >= .v1_1 ? id : []  // 1.0 has only the root, no ParentLibraryId
        let geli = Self.msex("GELI", [1] + parent + count + [0, 1, 7], version: version)
        let parentID: MSEXLibraryID = version >= .v1_1 ? .topLevel(2) : MSEXLibraryID()
        #expect(
            try CITPClientMessage.parse(geli)
                == .getElementLibraryInformation(GetElementLibraryInformation(version: version, libraryType: 1, parentID: parentID, libraryNumbers: [0, 1, 7])))
        let all = Self.msex("GELI", [1] + (version >= .v1_1 ? [0, 0, 0, 0] : []) + none, version: version)
        #expect(try CITPClientMessage.parse(all) == .getElementLibraryInformation(GetElementLibraryInformation(version: version)))

        let gein = Self.msex("GEIn", [1] + id + count + [4, 5, 6], version: version)
        #expect(
            try CITPClientMessage.parse(gein)
                == .getElementInformation(GetElementInformation(version: version, libraryType: 1, libraryID: .topLevel(2), elementNumbers: [4, 5, 6])))
    }

    @Test func elementLibraryInformationByteExact() throws {
        let library = ElementLibrary(
            id: MSEXLibraryID(level: 3, level1: 9, level2: 8, level3: 7), serialNumber: 99, dmxRangeMin: 1, dmxRangeMax: 20, name: "A",
            libraryCount: 4, elementCount: 300)
        let packet = CITPPacket.elementLibraryInformation(ElementLibraryInformation(libraryType: 2, libraries: [library]))
        let payload: [UInt8] = [2, 1, 0, 3, 9, 8, 7] + Self.le32(99) + [1, 20] + Self.ucs2("A") + [4, 0, 0x2C, 0x01]
        #expect(packet.encoded() == Self.msex("ELIn", payload))
    }

    @Test(arguments: allVersions) func elementLibraryInformationSize(version: MSEXVersion) throws {
        let library = ElementLibrary(id: .topLevel(3), serialNumber: 99, dmxRangeMin: 1, dmxRangeMax: 20, name: Self.name, libraryCount: 4, elementCount: 12)
        let bytes = CITPPacket.elementLibraryInformation(ElementLibraryInformation(version: version, libraryType: 1, libraries: [library])).encoded(version: version)
        // Per entry: 4 / 8 / 14 fixed bytes plus the ucs2 name; header: type + u8/u8/u16 count.
        let index = Self.allVersions.firstIndex(of: version)!
        #expect(bytes.count == 26 + [2, 2, 3][index] + [4, 8, 14][index] + Self.ucs2(Self.name).count)
    }

    @Test func mediaElementInformationByteExact() throws {
        let element = MediaElement(
            number: 1, serialNumber: 5, dmxRangeMin: 0, dmxRangeMax: 9, name: "A", versionTimestamp: 1_700_000_000, width: 1920, height: 1080,
            length: 250, fps: 25)
        let packet = CITPPacket.mediaElementInformation(MediaElementInformation(libraryID: .topLevel(2), elements: [element]))
        var payload: [UInt8] = [1, 2, 0, 0, 1, 0]  // MSEXLibraryId, element count
        payload += [1] + Self.le32(5) + [0, 9] + Self.ucs2("A")  // number, serial, DMX range, name
        payload += Self.le32(1_700_000_000) + [0, 0, 0, 0]  // version timestamp (u64)
        payload += Self.le16(1920) + Self.le16(1080) + Self.le32(250) + [25]
        #expect(packet.encoded() == Self.msex("MEIn", payload))
    }

    @Test(arguments: allVersions) func mediaElementInformationSize(version: MSEXVersion) throws {
        let elements = [
            MediaElement(number: 1, serialNumber: 5, dmxRangeMax: 9, name: Self.name, versionTimestamp: 1_700_000_000, width: 1920, height: 1080, length: 250, fps: 25),
            MediaElement(number: 2, name: "plain.mov", width: 640, height: 360, length: 10, fps: 30),
        ]
        let bytes = CITPPacket.mediaElementInformation(MediaElementInformation(version: version, libraryID: .topLevel(2), elements: elements)).encoded(version: version)
        // Per element: 20 fixed bytes (24 with SerialNumber in 1.2) plus the name; header: library ref + count.
        let index = Self.allVersions.firstIndex(of: version)!
        let names = Self.ucs2(Self.name).count + Self.ucs2("plain.mov").count
        #expect(bytes.count == 26 + [2, 5, 6][index] + 2 * (version >= .v1_2 ? 24 : 20) + names)
    }

    @Test(arguments: allVersions) func thumbnailRequestDecodesAndResponseEncodes(version: MSEXVersion) throws {
        let format = version >= .v1_2 ? "PNG " : "JPEG"
        let id: [UInt8] = version >= .v1_1 ? [1, 2, 0, 0] : [2]
        let count: [UInt8] = version >= .v1_2 ? [3, 0] : [3]
        let request = Self.msex("GETh", Array(format.utf8) + Self.le16(160) + Self.le16(90) + [1, 1] + id + count + [1, 2, 3], version: version)
        let expected = GetElementThumbnail(
            version: version, format: format, width: 160, height: 90, flags: GetElementThumbnail.preserveAspectRatio, libraryType: 1,
            libraryID: .topLevel(2), elementNumbers: [1, 2, 3])
        #expect(try CITPClientMessage.parse(request) == .getElementThumbnail(expected))
        // Fixed part: 12 / 15 / 16 bytes (spec totals) plus the 3 element numbers.
        let index = Self.allVersions.firstIndex(of: version)!
        #expect(request.count == 26 + [12, 15, 16][index] + 3)

        // EThn has 13 fixed bytes in 1.0, 16 in 1.1 and (no separate layout in the spec) 1.2.
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4, 0xFF, 0xD9]
        let thumb = CITPPacket.elementThumbnail(
            ElementThumbnail(version: version, libraryType: 1, libraryID: .topLevel(2), elementNumber: 7, width: 160, height: 90, buffer: jpeg))
        let payload: [UInt8] = [1] + id + [7] + Array("JPEG".utf8) + Self.le16(160) + Self.le16(90) + Self.le16(UInt16(jpeg.count)) + jpeg
        #expect(thumb.encoded(version: version) == Self.msex("EThn", payload, version: version))
        #expect(payload.count == [13, 16, 16][index] + jpeg.count)
    }

    // MARK: streaming

    /// GVSr has no payload; VSrc lists the sources (same layout in every version).
    @Test func videoSources() throws {
        for version in Self.allVersions {
            #expect(try CITPClientMessage.parse(Self.msex("GVSr", [], version: version)) == .getVideoSources)
        }
        let bytes = CITPPacket.videoSources([VideoSource(sourceIdentifier: 1, name: "L", layerNumber: 0, width: 160, height: 90)]).encoded()
        #expect(Array(bytes[22..<26]) == Array("VSrc".utf8))
        #expect(Array(bytes[26...]) == [1, 0, 1, 0, 0x4C, 0, 0, 0, 0xFF, 0, 0, 0, 0xA0, 0, 0x5A, 0])
    }

    @Test func requestStreamDecodes() throws {
        for version in Self.allVersions {
            let bytes = Self.msex("RqSt", [3, 0] + Array("JPEG".utf8) + [0x40, 0x01, 0xB4, 0x00, 10, 5], version: version)
            let expected = RequestStream(version: version, sourceIdentifier: 3, frameFormat: "JPEG", frameWidth: 320, frameHeight: 180, fps: 10, timeout: 5)
            #expect(try CITPClientMessage.parse(bytes) == .requestStream(expected))
        }
    }

    @Test func streamFrameWithJPEGBlob() throws {
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0] + (0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 31) } + [0xFF, 0xD9]
        for version in Self.allVersions {
            let packet = CITPPacket.streamFrame(
                StreamFrame(
                    version: version, mediaServerUUID: version >= .v1_2 ? Self.uuid : "", sourceIdentifier: 1, frameFormat: "JPEG",
                    frameWidth: 320, frameHeight: 180, buffer: jpeg))
            // 12 fixed bytes, plus the 36-byte UUID in 1.2.
            let uuid = version >= .v1_2 ? Array(Self.uuid.utf8) : []
            let payload = uuid + [1, 0] + Array("JPEG".utf8) + Self.le16(320) + Self.le16(180) + Self.le16(UInt16(jpeg.count)) + jpeg
            #expect(packet.encoded(version: version) == Self.msex("StFr", payload, version: version))
        }
    }

    @Test func oversizedBufferIsCutToTheSizeField() throws {
        let big = [UInt8](repeating: 7, count: 70_000)
        let bytes = CITPPacket.streamFrame(StreamFrame(sourceIdentifier: 1, frameWidth: 1, frameHeight: 1, buffer: big)).encoded()
        #expect(Array(bytes[72..<74]) == [0xFF, 0xFF])  // after the UUID, source, format, width and height
        #expect(bytes.count == 26 + 36 + 12 + 0xFFFF)
    }

    // MARK: robustness

    static let serverPackets: [CITPPacket] = [
        .peerLocation(PeerLocation(listeningTCPPort: 1, type: "t", name: "n", state: "s")), .serverInformation(serverInfo),
        .nack(Nack(receivedContentType: "GELT")), .layerStatus([LayerStatus(layerNumber: 0, mediaName: name)]),
        .elementLibraryInformation(ElementLibraryInformation(libraries: [ElementLibrary(id: .topLevel(1), name: name)])),
        .mediaElementInformation(MediaElementInformation(libraryID: .topLevel(1), elements: [MediaElement(number: 0, name: name)])),
        .elementThumbnail(ElementThumbnail(libraryID: .topLevel(1), elementNumber: 0, width: 1, height: 1, buffer: [1, 2, 3])),
        .videoSources([VideoSource(sourceIdentifier: 0, name: "Canvas", width: 1, height: 1)]),
        .streamFrame(StreamFrame(sourceIdentifier: 0, frameWidth: 1, frameHeight: 1, buffer: [1])),
    ]

    @Test func messageSizeEqualsEncodedLength() throws {
        for packet in Self.serverPackets {
            for version in Self.allVersions {
                let bytes = packet.encoded(version: version)
                let header = try CITPHeader.parse(bytes)
                #expect(Int(header.messageSize) == bytes.count)
                #expect(header.messagePartCount == 1 && header.messagePart == 0)
            }
        }
    }

    /// What only a server sends is refused, not taken for an unknown message (the server would Nack it).
    @Test func serverMessagesAreNotDecoded() {
        for packet in Self.serverPackets {
            for version in Self.allVersions {
                #expect(throws: CITPError.serverMessage) { try CITPClientMessage.parse(packet.encoded(version: version)) }
            }
        }
    }

    @Test func truncatedPacketsThrow() throws {
        let request = Self.msex("RqSt", [3, 0] + Array("JPEG".utf8) + [0x40, 0x01, 0xB4, 0x00, 10, 5])
        #expect(throws: CITPError.truncated) { try CITPClientMessage.parse([]) }
        #expect(throws: CITPError.truncated) { try CITPClientMessage.parse(Array(request.prefix(19))) }
        #expect(throws: CITPError.truncated) { try CITPClientMessage.parse(Array(request.dropLast())) }

        // MessageSize is consistent with the bytes, but the body ends inside a field / a string / a counted list.
        func shrunk(_ bytes: [UInt8], by n: Int) -> [UInt8] {
            var cut = Array(bytes.dropLast(n))
            cut.replaceSubrange(8..<12, with: Self.le32(UInt32(cut.count)))
            return cut
        }
        for n in [1, 5] {
            #expect(throws: CITPError.truncated) { try CITPClientMessage.parse(shrunk(request, by: n)) }
        }
        #expect(throws: CITPError.truncated) { try CITPClientMessage.parse(shrunk(Self.pinf("PNam", Array("Fanous\0".utf8)), by: 1)) }
        let thumbnails = Self.msex("GETh", Array("JPEG".utf8) + [1, 0, 1, 0, 0, 1, 1, 1, 0, 0, 3, 0, 1, 2, 3])
        #expect(throws: CITPError.truncated) { try CITPClientMessage.parse(shrunk(thumbnails, by: 1)) }
    }

    @Test func malformedHeadersThrow() {
        let ok = Self.pinf("PNam", Array("x\0".utf8))
        var bytes = ok
        bytes[0] = 0x58
        #expect(throws: CITPError.badHeader) { try CITPClientMessage.parse(bytes) }
        bytes = ok
        bytes[4] = 2  // CITP major version
        #expect(throws: CITPError.badHeader) { try CITPClientMessage.parse(bytes) }
        bytes = ok
        bytes.replaceSubrange(8..<12, with: Self.le32(19))
        #expect(throws: CITPError.badSize) { try CITPClientMessage.parse(bytes) }
        bytes = ok
        bytes.replaceSubrange(12..<14, with: Self.le16(2))
        #expect(throws: CITPError.fragmented) { try CITPClientMessage.parse(bytes) }
        let futureMSEX = Self.header(size: 26, "MSEX") + [2, 0] + Array("CInf".utf8)
        #expect(throws: CITPError.unsupportedVersion) { try CITPClientMessage.parse(futureMSEX) }
    }

    @Test func unknownContentTypesKeepTheirBody() throws {
        // Another CITP layer entirely.
        let sdmx = Self.header(size: 29, "SDMX", requestIndex: 7) + [1, 2, 3, 4, 5, 6, 7, 8, 9]
        #expect(try CITPClientMessage.parse(sdmx) == .unknown(contentType: "SDMX", body: [1, 2, 3, 4, 5, 6, 7, 8, 9]))

        // An MSEX message this codec does not model (EEIn): spec says ignore it, bytes are kept.
        let eein = Self.header(size: 31, "MSEX") + [1, 1] + Array("EEIn".utf8) + [0xDE, 0xAD, 0xBE, 0xEF, 0x00]
        #expect(try CITPClientMessage.parse(eein) == .unknown(contentType: "MSEX", body: [1, 1] + Array("EEIn".utf8) + [0xDE, 0xAD, 0xBE, 0xEF, 0x00]))

        // An unknown PINF message.
        let pinf = Self.header(size: 26, "PINF") + Array("Zzzz".utf8) + [1, 2]
        #expect(try CITPClientMessage.parse(pinf) == .unknown(contentType: "PINF", body: Array("Zzzz".utf8) + [1, 2]))
    }

    @Test func trailingBytesAfterMessageSizeAreIgnored() throws {
        #expect(try CITPClientMessage.parse(Self.pinf("PNam", Array("x\0".utf8)) + [1, 2, 3]) == .peerName("x"))
    }
}
