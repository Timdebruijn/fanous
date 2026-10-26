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

    /// A blocking client: send one packet, collect decoded packets until `until` is satisfied or the time runs out.
    final class Client: @unchecked Sendable {
        let connection: NWConnection
        let queue = DispatchQueue(label: "test.citp.client")
        let received = Mutex<[CITPPacket]>([])
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
                    if let packet = try? CITPPacket.parse(message) { received.withLock { $0.append(packet) } }
                    semaphore.signal()
                }
                if done || error != nil { return }
                receive()
            }
        }

        func send(_ packet: CITPPacket, requestIndex: UInt16 = 7) {
            connection.send(content: Data(packet.encoded(version: .v1_2, requestIndex: requestIndex)), completion: .idempotent)
        }

        /// The first received packet matching `pick`, waiting up to `timeout`.
        func wait<T: Sendable>(_ timeout: TimeInterval = 3, _ pick: (CITPPacket) -> T?) -> T? {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                if let found = received.withLock({ $0.compactMap(pick).first }) { return found }
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { return nil }
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
            providers: CITPServer.Providers(layers: { [] }, library: Self.library, thumbnail: { _ in nil }, frame: { nil }), logger: Self.logger)
        try server.start()
        defer { server.stop() }
        var buffer = [UInt8](repeating: 0, count: 512)
        var packet: CITPPacket?
        for _ in 0..<4 where packet == nil {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { break }
            if case .peerLocation(let location)? = try? CITPPacket.parse(Array(buffer[0..<n])), location.name == "beacon-test" { packet = .peerLocation(location) }
        }
        let location = try #require(packet, "no PLoc within 3 s (no default route, or a firewall holds the engine's UDP)")
        if case .peerLocation(let l) = location {
            #expect(l.listeningTCPPort == server.status.withLock { $0.port } && l.type == "MediaServer" && l.state == "Running")
        }
    }

    @Test func msexSessionOverLoopback() throws {
        let frames = Mutex(0)
        let server = CITPServer(
            name: "test", uuid: "550e8400-e29b-41d4-a716-446655440000",
            providers: CITPServer.Providers(
                layers: { [CITPServer.LayerInfo(index: 1, folder: 1, file: 3, name: "Intro", positionMs: 400, lengthMs: 10_000, fps: 25, flags: LayerStatus.playing)] },
                library: Self.library, thumbnail: { $0 == "intro.jpg" ? Self.jpeg : nil },
                frame: {
                    frames.withLock { $0 += 1 }
                    return (Self.jpeg, 640, 360)
                }), logger: Self.logger)
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

        client.send(.clientInformation(ClientInformation(supportedVersions: [.v1_0, .v1_1, .v1_2, MSEXVersion(major: 2, minor: 0)])))
        let info = try #require(client.wait { if case .serverInformation(let i) = $0 { return i } else { return nil } })
        #expect(info.version == .v1_2, "highest common version, never above 1.2")
        #expect(info.productName == "Fanous" && info.layerDMXSources == ["Layer 1"] && info.streamFormats == ["JPEG"])
        #expect(server.wantsFrames.load(ordering: .relaxed) == false)
        #expect(server.activeTimers == (true, false), "negotiated: layer status runs, no frames yet")

        client.send(.getElementLibraryInformation(GetElementLibraryInformation()))
        let libraries = try #require(client.wait { if case .elementLibraryInformation(let l) = $0 { return l } else { return nil } })
        #expect(libraries.libraries.map(\.name) == ["Bench"], "invalid folder names are not libraries")
        #expect(libraries.libraries.first?.id == .topLevel(1) && libraries.libraries.first?.elementCount == 1)

        client.send(.getElementInformation(GetElementInformation(libraryID: .topLevel(1))))
        let elements = try #require(client.wait { if case .mediaElementInformation(let e) = $0 { return e } else { return nil } })
        let element = try #require(elements.elements.first)
        #expect(elements.elements.count == 1 && element.number == 3 && element.name == "Intro" && element.width == 1920 && element.length == 250 && element.fps == 25)

        client.send(.getElementThumbnail(GetElementThumbnail(width: 320, height: 180, libraryID: .topLevel(1), elementNumbers: [3])))
        let thumbnail = try #require(client.wait { if case .elementThumbnail(let t) = $0 { return t } else { return nil } })
        #expect(thumbnail.buffer == Self.jpeg && thumbnail.format == "JPEG" && thumbnail.elementNumber == 3)

        let status = try #require(client.wait(1) { if case .layerStatus(let s) = $0 { return s } else { return nil } })
        #expect(status.count == 1 && status.first?.layerNumber == 0 && status.first?.mediaName == "Intro" && status.first?.statusFlags == LayerStatus.playing)

        client.send(.requestStream(RequestStream(sourceIdentifier: 0, frameFormat: "JPEG", frameWidth: 640, frameHeight: 360, fps: 10, timeout: 5)))
        let frame = try #require(client.wait(2) { if case .streamFrame(let f) = $0 { return f } else { return nil } })
        #expect(frame.buffer == Self.jpeg && frame.frameWidth == 640 && frame.frameFormat == "JPEG")
        #expect(server.wantsFrames.load(ordering: .relaxed) == true)
        #expect(server.status.withLock { $0.streams } == 1)
        #expect(server.activeTimers == (true, true), "streaming: frame timer runs")

        client.send(.unknown(contentType: "MSEX", body: [1, 2] + Array("XXXX".utf8)))
        let nack = try #require(client.wait(1) { if case .nack(let n) = $0 { return n } else { return nil } })
        #expect(nack.receivedContentType == "XXXX")

        client.send(.requestStream(RequestStream(sourceIdentifier: 0, frameFormat: "JPEG", frameWidth: 640, frameHeight: 360, fps: 0, timeout: 5)))
        for _ in 0..<50 where server.status.withLock({ $0.streams }) > 0 { usleep(20_000) }
        #expect(server.status.withLock { $0.streams } == 0 && server.wantsFrames.load(ordering: .relaxed) == false, "fps 0 stops the stream")
        #expect(server.activeTimers == (true, false), "stream over: frame timer stopped")
        client.connection.cancel()
        for _ in 0..<100 where server.activeTimers.status { usleep(20_000) }
        #expect(server.activeTimers == (false, false), "console gone: no periodic timers")
    }
}
