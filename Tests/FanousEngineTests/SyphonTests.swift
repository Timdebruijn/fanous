// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Logging
import Metal
import Synchronization
import Testing

@testable import FanousEngine

@Suite struct SyphonTests {
    @Test func sceneSpecSplitsOnTheFirstSlash() {
        #expect(SceneConfig.syphonSpec("Some App/Server name")! == ("Some App", "Server name"))
        #expect(SceneConfig.syphonSpec("Simple Server/")! == ("Simple Server", ""))
        #expect(SceneConfig.syphonSpec("A/B/C")! == ("A", "B/C"))
        #expect(SceneConfig.syphonSpec("App") == nil)
        #expect(SceneConfig.syphonSpec("/Server") == nil)
        #expect(SceneConfig.syphonSpec("/") == nil)
    }

    static let size = 64

    /// B = x*4, G = y*4, R = 0x80, A = 0xFF: every row and column differs, so a flip in either axis shows.
    static func pattern() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                bytes[i] = UInt8(x * 4)
                bytes[i + 1] = UInt8(y * 4)
                bytes[i + 2] = 0x80
                bytes[i + 3] = 0xFF
            }
        }
        return bytes
    }

    /// Polls `condition` every 10 ms until it holds or `seconds` have passed.
    static func wait(seconds: Double, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    /// Syphon surfaces are in OpenGL order (row 0 at the bottom), so a published Metal texture arrives with its
    /// rows reversed and the compositor samples a Syphon input bottom-up; an OpenGL client such as the Syphon
    /// Simple Client then shows the canvas upright (checked by eye 2026-10-26). bgra8Unorm matches the surface
    /// format, rgba8Unorm takes the conversion path; both go through Syphon's flip draw.
    @Test(arguments: [MTLPixelFormat.bgra8Unorm, .rgba8Unorm])
    func publishedTextureArrivesBottomUpInASurfaceAndTheInputSaysSo(format: MTLPixelFormat) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }  // no GPU: skip
        let name = "FanousTest-\(UUID().uuidString)"
        let output = try SyphonOutput(name: name, device: device)
        let input = SyphonInput(device: device)
        defer {
            input.disconnect()
            output.stop()
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: Self.size, height: Self.size, mipmapped: false)
        descriptor.usage = [.shaderRead]
        let source = try #require(device.makeTexture(descriptor: descriptor))
        let pattern = Self.pattern()
        var sourceBytes = pattern
        if format == .rgba8Unorm {  // same colours, red and blue swapped in memory
            for i in stride(from: 0, to: sourceBytes.count, by: 4) { sourceBytes.swapAt(i, i + 2) }
        }
        source.replace(region: MTLRegionMake2D(0, 0, Self.size, Self.size), mipmapLevel: 0, withBytes: sourceBytes, bytesPerRow: Self.size * 4)

        try input.connect(description: output.serverDescription)

        // The client registers for frames asynchronously, so keep publishing until one arrives.
        let arrived = Self.wait(seconds: 3) {
            guard let commandBuffer = queue.makeCommandBuffer() else { return false }
            output.publish(texture: source, commandBuffer: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            return input.latestTexture != nil
        }
        #expect(arrived)
        #expect(output.hasClients)
        let received = try #require(input.latestTexture)
        #expect(received.width == Self.size && received.height == Self.size)
        #expect(input.frames > 0)

        var bytes = [UInt8](repeating: 0, count: pattern.count)
        received.getBytes(&bytes, bytesPerRow: Self.size * 4, from: MTLRegionMake2D(0, 0, Self.size, Self.size), mipmapLevel: 0)
        let row = Self.size * 4
        let reversed = (0..<Self.size).reversed().flatMap { y in pattern[(y * row)..<((y + 1) * row)] }
        #expect(bytes == reversed)
        #expect(bytes != pattern)
        #expect(input.bottomUp)

        // The directory learns about servers through distributed notifications, which need the main run loop.
        #expect(Self.wait(seconds: 2) { input.servers.contains { $0.serverName == name } })

        input.disconnect()
        #expect(input.latestTexture == nil)
    }

    // MARK: numbered servers (B61)

    static func info(_ app: String, _ server: String = "", _ uuid: String) -> SyphonInput.ServerInfo {
        SyphonInput.ServerInfo(appName: app, serverName: server, uuid: uuid)
    }

    @Test func catalogNumbersServersInAnnounceOrderAndKeepsNumbersWhenTheyGo() {
        var list: [SyphonCatalog.Server] = []
        #expect(SyphonCatalog.assign(&list, running: [Self.info("Resolume", "Out", "a"), Self.info("Simple Server", "", "b")]))
        #expect(list.map(\.file) == [150, 151])
        #expect(list.map(\.name) == ["Resolume/Out", "Simple Server"])
        #expect(list.allSatisfy { $0.running })
        #expect(!SyphonCatalog.assign(&list, running: [Self.info("Resolume", "Out", "a"), Self.info("Simple Server", "", "b")]))

        // a gone server keeps its number; a new one takes the next, never the gone one's
        #expect(SyphonCatalog.assign(&list, running: [Self.info("Simple Server", "", "b"), Self.info("fanousd", "Fanous – Canvas", "c")]))
        #expect(list.map(\.file) == [150, 151, 152])
        #expect(list[0].uuid == nil && !list[0].running && list[0].name == "Resolume/Out")
        #expect(list[2].name == "fanousd/Fanous – Canvas")

        // back under the same name with a new id: its old number
        #expect(SyphonCatalog.assign(&list, running: [Self.info("Resolume", "Out", "a2"), Self.info("Simple Server", "", "b"), Self.info("fanousd", "Fanous – Canvas", "c")]))
        #expect(list.count == 3 && list[0].uuid == "a2")

        // two servers with one name (two engines' canvases) get a number each; a rename keeps the number
        #expect(SyphonCatalog.assign(&list, running: [Self.info("fanousd", "Fanous – Canvas", "c"), Self.info("fanousd", "Fanous – Canvas", "d"), Self.info("Simple Server", "Renamed", "b")]))
        #expect(list.map(\.file) == [150, 151, 152, 153])
        #expect(list[1].name == "Simple Server/Renamed" && list[3].uuid == "d" && list[0].uuid == nil)
    }

    @Test func catalogHasTwentyNumbers() {
        var list: [SyphonCatalog.Server] = []
        _ = SyphonCatalog.assign(&list, running: (0..<25).map { Self.info("App", "S\($0)", "u\($0)") })
        #expect(list.count == 20 && list.last?.file == 169 && list.last?.server == "S19")
        // full: a gone server still holds its number, a new one gets none
        _ = SyphonCatalog.assign(&list, running: [Self.info("Other", "", "x")])
        #expect(list.count == 20 && list.allSatisfy { !$0.running })
    }

    final class FakeLive: LiveTextureSource, @unchecked Sendable {
        let uuid: String?
        let stopped = Atomic<Bool>(false)
        init(uuid: String?) { self.uuid = uuid }
        var latestTexture: MTLTexture? { nil }
        func stop() { stopped.store(true, ordering: .relaxed) }
    }

    /// Folder 0 file 150+ resolves through the catalog to a live input made by the factory with the server's id; a gone
    /// server says "not running" and keeps the playback, its return connects again without a new selection, and a
    /// scene entry on the same number wins.
    @Test func loaderResolvesNumberedServersAndReconnects() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layers = [RenderLayer(index: 0), RenderLayer(index: 1)]
        let loader = MediaLoader(
            layers: layers, media: [MediaEntry(folder: 0, file: 151, syphon: "Scene App/Fixed")], device: device, ringCapacity: 4, logger: Logger(label: "test"))
        let calls = Mutex<[String]>([])
        loader.liveFactory = { spec, uuid in
            calls.withLock { $0.append("\(spec)|\(uuid ?? "-")") }
            return FakeLive(uuid: uuid)
        }
        let catalog = SyphonCatalog()
        catalog.onChange = { [loader] in loader.syphonServersChanged() }
        loader.syphonCatalog = catalog
        catalog.update(running: [Self.info("Resolume", "Out", "a"), Self.info("Other", "", "b")])
        loader.start()
        defer { loader.stop() }

        func playback(_ i: Int) -> FakeLive? { layers[i].pending.withLock { $0.playback?.live as? FakeLive } }
        func status(_ i: Int) -> LayerMediaStatus { layers[i].mediaStatus.withLock { $0 } }
        func eventually(_ condition: () -> Bool) -> Bool { Self.wait(seconds: 5, until: condition) }
        layers[0].wanted.store(MediaKey(folder: 0, file: 150).packed, ordering: .relaxed)
        layers[1].wanted.store(MediaKey(folder: 0, file: 151).packed, ordering: .relaxed)
        loader.wake.signal()
        #expect(eventually { playback(0)?.uuid == "a" && status(0).name == "Syphon: Resolume/Out" })
        #expect(status(0).kind == "live" && status(0).error == nil)
        // the scene's entry on 151 wins over the catalog's "Other"
        #expect(eventually { status(1).name == "Syphon: Scene App/Fixed" })
        #expect(calls.withLock { $0 }.contains("Scene App/Fixed|-"))

        // the server goes: "not running", the last picture stays (same playback, not stopped)
        let first = try #require(playback(0))
        catalog.update(running: [Self.info("Other", "", "b")])
        #expect(eventually { status(0).error == "not running" })
        #expect(status(0).name == "Syphon: Resolume/Out" && status(0).kind == "live")
        #expect(playback(0) === first && !first.stopped.load(ordering: .relaxed))

        // it comes back with a new id: connected again without selecting the file again
        catalog.update(running: [Self.info("Other", "", "b"), Self.info("Resolume", "Out", "a2")])
        #expect(eventually { playback(0)?.uuid == "a2" && status(0).error == nil })
        #expect(catalog.server(file: 150)?.uuid == "a2")

        // a number no server has: missing; a gone server picked anew: not running, nothing to show
        layers[1].wanted.store(MediaKey(folder: 0, file: 160).packed, ordering: .relaxed)
        loader.wake.signal()
        #expect(eventually { status(1).kind == "missing" && status(1).error == "no Syphon server numbered 160 (folder 0, 150–169)" })
        catalog.update(running: [Self.info("Other", "", "b")])
        layers[1].wanted.store(MediaKey(folder: 0, file: 150).packed, ordering: .relaxed)
        loader.wake.signal()
        #expect(eventually { status(1).error == "not running" && status(1).name == "Syphon: Resolume/Out" && playback(1) == nil })
        // ... and connects when it starts
        catalog.update(running: [Self.info("Other", "", "b"), Self.info("Resolume", "Out", "a3")])
        #expect(eventually { playback(1)?.uuid == "a3" && status(1).error == nil })

        // a rename while playing shows without a new selection (same connection, same number)
        let connected = try #require(playback(1))
        catalog.update(running: [Self.info("Other", "", "b"), Self.info("Resolume", "Main", "a3")])
        #expect(eventually { status(1).name == "Syphon: Resolume/Main" })
        #expect(playback(1) === connected && catalog.server(file: 150)?.file == 150)
    }

    @Test func loaderSaysCouldNotConnectWhenARunningServerRefuses() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = RenderLayer(index: 0)
        let loader = MediaLoader(layers: [layer], media: [], device: device, ringCapacity: 4, logger: Logger(label: "test"))
        loader.liveFactory = { _, _ in nil }
        let catalog = SyphonCatalog()
        catalog.update(running: [Self.info("App", "", "a")])
        loader.syphonCatalog = catalog
        loader.start()
        defer { loader.stop() }
        layer.wanted.store(MediaKey(folder: 0, file: 150).packed, ordering: .relaxed)
        loader.wake.signal()
        #expect(Self.wait(seconds: 5) { layer.mediaStatus.withLock { $0.error == "could not connect" && $0.name == "Syphon: App" } })
    }

    @Test func catalogLeavesTheEnginesOwnServerOut() {
        let catalog = SyphonCatalog(excluding: "own")
        catalog.update(running: [Self.info("fanousd", "Fanous – Canvas", "own"), Self.info("Resolume", "Out", "a")])
        #expect(catalog.servers.map(\.name) == ["Resolume/Out"])
        #expect(catalog.server(file: 150)?.uuid == "a")
    }
}
