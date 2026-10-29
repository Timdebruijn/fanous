// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import Logging
import Network
import Synchronization
import Testing

@testable import FanousEngine

/// Loopback: a console-side TCP client talks MSEX to `CITPServer` (version negotiation, library, elements,
/// thumbnails, layer status, streaming frames).
struct CITPServerTests {
    static let logger = Logger(label: "test")
    static let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xD9]

    static func library() -> LibrarySnapshot {
        let clip = LibraryItem(
            folder: 1, file: 3, name: "Intro", path: "/lib/001_Bench/003_Intro.mov", kind: .movie, status: .playable, reason: nil,
            metadata: MediaMetadata(width: 1920, height: 1080, frameRate: 25, duration: 10, codec: "Hap1", hasAlpha: false, audioChannels: 0, audioSampleRate: 0, frameCount: 250),
            thumbnail: "intro.jpg", modified: 0, size: 1)
        let bad = LibraryItem(folder: 1, file: nil, name: "notes.txt", path: "/lib/001_Bench/notes.txt", kind: .other, status: .invalid, reason: "name", metadata: nil, thumbnail: nil, modified: 0, size: 1)
        return LibrarySnapshot(
            root: "/lib", rootExists: true,
            folders: [
                LibraryFolder(number: 1, name: "Bench", path: "/lib/001_Bench", items: [clip, bad]), LibraryFolder(number: nil, name: "junk", path: "/lib/junk", items: []),
            ], scannedAt: 0, fileCount: 2, invalidCount: 1)
    }

    /// A console's MSEX message as bytes (the codec does not encode the client direction): CITP header with
    /// RequestIndex 7, MSEX 1.2, cookie, payload.
    static func msex(_ cookie: String, _ payload: [UInt8]) -> [UInt8] {
        CITPHeader(requestIndex: 7, messageSize: UInt32(26 + payload.count), contentType: "MSEX").encode() + [1, 2] + Array(cookie.utf8) + payload
    }

    /// RqSt for `source` at `fps` (0 stops it), JPEG, 5 s timeout.
    static func requestStream(_ source: UInt16, width: UInt16, height: UInt16, fps: UInt8) -> [UInt8] {
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        return msex("RqSt", le16(source) + Array("JPEG".utf8) + le16(width) + le16(height) + [fps, 5])
    }

    /// What the server should answer, as bytes (MSEX 1.2, InResponseTo 7 unless it is unsolicited).
    static func reply(_ packet: CITPPacket, requestIndex: UInt16 = 7) -> [UInt8] { packet.encoded(version: .v1_2, requestIndex: requestIndex) }

    /// A blocking client: send raw messages, collect whole received messages until `wait` finds one or the time runs out.
    final class Client: @unchecked Sendable {
        let connection: NWConnection
        let queue = DispatchQueue(label: "test.citp.client")
        let received = Mutex<[[UInt8]]>([])
        private var buffer: [UInt8] = []
        private let semaphore = DispatchSemaphore(value: 0)

        init(port: UInt16) {
            connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            connection.start(queue: queue)
            receive()
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, done, error in
                if let data { buffer.append(contentsOf: data) }
                while buffer.count >= CITPHeader.size, let header = try? CITPHeader.parse(buffer), buffer.count >= Int(header.messageSize) {
                    let message = Array(buffer[0..<Int(header.messageSize)])
                    buffer.removeFirst(message.count)
                    received.withLock { $0.append(message) }
                    semaphore.signal()
                }
                if done || error != nil { return }
                receive()
            }
        }

        func send(_ bytes: [UInt8]) {
            connection.send(content: Data(bytes), completion: .idempotent)
        }

        /// Whether `expected` arrived (byte for byte), waiting up to `timeout`.
        func wait(_ timeout: TimeInterval = 3, for expected: [UInt8]) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                if received.withLock({ $0.contains(expected) }) { return true }
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { return false }
                _ = semaphore.wait(timeout: .now() + remaining)
            }
        }
    }

    /// The PLoc beacon reaches a listener joined to the 2014 group on this host. Needs a default route and an
    /// outgoing-UDP firewall rule for the test runner (Little Snitch holds the first datagram of a new binary),
    /// so it only runs with `FANOUS_NET_TESTS=1`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FANOUS_NET_TESTS"] != nil)) func peerLocationBeaconReachesAMulticastListener() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = CITPMulticast.port.bigEndian
        sin.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &sin) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        #expect(bound == 0, "bind 4809: errno \(errno)")
        var membership = ip_mreq(imr_multiaddr: in_addr(s_addr: inet_addr(CITPMulticast.addressSince2014)), imr_interface: in_addr(s_addr: INADDR_ANY))
        #expect(setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &membership, socklen_t(MemoryLayout<ip_mreq>.size)) == 0, "join: errno \(errno)")
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let server = CITPServer(
            name: "beacon-test", uuid: "550e8400-e29b-41d4-a716-446655440000",
            providers: CITPServer.Providers(layers: { [] }, library: Self.library, thumbnail: { _ in nil }, frame: { _ in nil }), logger: Self.logger)
        try server.start()
        defer { server.stop() }
        var buffer = [UInt8](repeating: 0, count: 512)
        var found = false
        for _ in 0..<4 where !found {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { break }
            let port = server.status.withLock { $0.port }
            found = Array(buffer[0..<n]) == CITPPacket.peerLocation(PeerLocation(listeningTCPPort: port, type: "MediaServer", name: "beacon-test", state: "Running")).encoded()
        }
        #expect(found, "no PLoc within 3 s (no default route, or a firewall holds the engine's UDP)")
    }

    @Test func msexSessionOverLoopback() throws {
        let frames = Mutex(0)
        let sources = [VideoSource(sourceIdentifier: 0, name: "Canvas", width: 640, height: 360), VideoSource(sourceIdentifier: 1, name: "Layer 1", layerNumber: 0, width: 160, height: 90)]
        let server = CITPServer(
            name: "test", uuid: "550e8400-e29b-41d4-a716-446655440000",
            providers: CITPServer.Providers(
                layers: { [CITPServer.LayerInfo(index: 1, folder: 1, file: 3, name: "Intro", positionMs: 400, lengthMs: 10_000, fps: 25, flags: LayerStatus.playing)] },
                library: Self.library, thumbnail: { $0 == "intro.jpg" ? Self.jpeg : nil },
                frame: { source in
                    frames.withLock { $0 += 1 }
                    return source == 1 ? (Self.jpeg, 160, 90) : (Self.jpeg, 640, 360)  // layer 1's thumbnail, else the canvas
                },
                sources: { sources },
                layerCount: { 1 }),
            logger: Self.logger)
        try server.start()
        defer { server.stop() }
        var port: UInt16 = 0
        for _ in 0..<100 where port == 0 {
            port = server.status.withLock { $0.port }
            if port == 0 { usleep(20_000) }
        }
        #expect(port > 0)
        #expect(server.activeTimers == (false, false), "nobody connected: no periodic timers")
        let client = Client(port: port)

        client.send(Self.msex("CInf", [4, 0, 1, 1, 1, 2, 1, 0, 2]))  // 1.0, 1.1, 1.2, 2.0
        let info = ServerInformation(
            version: .v1_2, uuid: "550e8400-e29b-41d4-a716-446655440000", productName: "Fanous", productVersionMajor: CITPServer.productVersion.0,
            productVersionMinor: CITPServer.productVersion.1, productVersionBugfix: CITPServer.productVersion.2, supportedVersions: [.v1_0, .v1_1, .v1_2],
            supportedLibraryTypes: 1, thumbnailFormats: ["JPEG", "RGB8"], streamFormats: ["JPEG"], layerDMXSources: ["Layer 1"])
        #expect(client.wait(for: Self.reply(.serverInformation(info))), "SInf in the highest common version, never above 1.2")
        #expect(server.wantsFrames.load(ordering: .relaxed) == false)
        #expect(server.activeTimers == (true, false), "negotiated: layer status runs, no frames yet")

        client.send(Self.msex("GELI", [1, 0, 0, 0, 0, 0, 0]))  // media, below the root, all libraries
        let bench = ElementLibrary(id: .topLevel(1), serialNumber: 2, dmxRangeMin: 1, dmxRangeMax: 1, name: "Bench", elementCount: 1)
        #expect(
            client.wait(for: Self.reply(.elementLibraryInformation(ElementLibraryInformation(libraries: [bench])))),
            "invalid folder names are not libraries")

        client.send(Self.msex("GEIn", [1, 1, 1, 0, 0, 0, 0]))  // media, library 1, all elements
        let intro = MediaElement(number: 3, dmxRangeMin: 3, dmxRangeMax: 3, name: "Intro", width: 1920, height: 1080, length: 250, fps: 25)
        #expect(client.wait(for: Self.reply(.mediaElementInformation(MediaElementInformation(libraryID: .topLevel(1), elements: [intro])))))

        client.send(Self.msex("GETh", Array("JPEG".utf8) + [0x40, 0x01, 0xB4, 0x00, 0, 1, 1, 1, 0, 0, 1, 0, 3]))  // 320 x 180, library 1, element 3
        let thumbnail = ElementThumbnail(
            libraryID: .topLevel(1), elementNumber: 3, width: UInt16(Thumbnailer.width), height: UInt16(Thumbnailer.width * 1080 / 1920), buffer: Self.jpeg)
        #expect(client.wait(for: Self.reply(.elementThumbnail(thumbnail))))

        let status = LayerStatus(
            layerNumber: 0, mediaLibraryID: .topLevel(1), mediaNumber: 3, mediaName: "Intro", mediaPosition: 400, mediaLength: 10_000, mediaFPS: 25,
            statusFlags: LayerStatus.playing)
        #expect(client.wait(1, for: Self.reply(.layerStatus([status]), requestIndex: 0)))

        client.send(Self.requestStream(0, width: 640, height: 360, fps: 10))
        let frame = StreamFrame(mediaServerUUID: "550e8400-e29b-41d4-a716-446655440000", sourceIdentifier: 0, frameWidth: 640, frameHeight: 360, buffer: Self.jpeg)
        #expect(client.wait(2, for: Self.reply(.streamFrame(frame), requestIndex: 0)))
        #expect(server.wantsFrames.load(ordering: .relaxed) == true && server.wantsLayerFrames.load(ordering: .relaxed) == false)
        #expect(server.status.withLock { $0.streams } == 1)
        #expect(server.activeTimers == (true, true), "streaming: frame timer runs")

        // per-layer streams (B29/B41): the sources, then layer 1's live thumbnail
        client.send(Self.msex("GVSr", []))
        #expect(client.wait(1, for: Self.reply(.videoSources(sources))))
        client.send(Self.requestStream(1, width: 160, height: 90, fps: 4))
        let layerFrame = StreamFrame(mediaServerUUID: "550e8400-e29b-41d4-a716-446655440000", sourceIdentifier: 1, frameWidth: 160, frameHeight: 90, buffer: Self.jpeg)
        #expect(client.wait(2, for: Self.reply(.streamFrame(layerFrame), requestIndex: 0)))
        #expect(server.wantsLayerFrames.load(ordering: .relaxed) == true && server.status.withLock { $0.streams } == 2)
        client.send(Self.requestStream(1, width: 160, height: 90, fps: 0))
        for _ in 0..<50 where server.wantsLayerFrames.load(ordering: .relaxed) { usleep(20_000) }
        #expect(server.wantsLayerFrames.load(ordering: .relaxed) == false && server.wantsFrames.load(ordering: .relaxed) == true, "the canvas stream stays")
        #expect(CITPServer.layer(ofSource: 0, layerCount: 2) == nil && CITPServer.layer(ofSource: 2, layerCount: 2) == 1 && CITPServer.layer(ofSource: 3, layerCount: 2) == nil)

        client.send(Self.msex("XXXX", []))
        #expect(client.wait(1, for: Self.reply(.nack(Nack(receivedContentType: "XXXX")))))

        client.send(Self.requestStream(0, width: 640, height: 360, fps: 0))
        for _ in 0..<50 where server.status.withLock({ $0.streams }) > 0 { usleep(20_000) }
        #expect(server.status.withLock { $0.streams } == 0 && server.wantsFrames.load(ordering: .relaxed) == false, "fps 0 stops the stream")
        #expect(server.activeTimers == (true, false), "stream over: frame timer stopped")
        client.connection.cancel()
        for _ in 0..<100 where server.activeTimers.status { usleep(20_000) }
        #expect(server.activeTimers == (false, false), "console gone: no periodic timers")
    }
}
