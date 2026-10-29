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
            return input.latestFrame != nil
        }
        #expect(arrived)
        #expect(output.hasClients)
        let received = try #require(input.latestFrame?.texture0)
        #expect(received.width == Self.size && received.height == Self.size)
        #expect(input.frames > 0)

        var bytes = [UInt8](repeating: 0, count: pattern.count)
        received.getBytes(&bytes, bytesPerRow: Self.size * 4, from: MTLRegionMake2D(0, 0, Self.size, Self.size), mipmapLevel: 0)
        let row = Self.size * 4
        let reversed = (0..<Self.size).reversed().flatMap { y in pattern[(y * row)..<((y + 1) * row)] }
        #expect(bytes == reversed)
        #expect(bytes != pattern)
        #expect(input.latestFrame?.bottomUp == true && input.latestFrame?.kind == .rgba)

        // The directory learns about servers through distributed notifications, which need the main run loop.
        #expect(Self.wait(seconds: 2) { input.servers.contains { $0.serverName == name } })

        input.disconnect()
        #expect(input.latestFrame == nil)
    }

    /// B109: one publish of an `rgba16Float` texture (the canvas format; `flipped`, so Syphon's draw, never its blit)
    /// allocates exactly 4 on the calling thread in an optimised build: the encoder (2) and the completion handler block
    /// (2). The render pass descriptor is made once (`VENDORED.md` local change 6); made per frame it added 4 (8 in all).
    /// A ratchet: fewer (or a hook that sees nothing) fails too, so the number here is updated with the change.
    @Test(.enabled(if: MallocCounter.availableOrRequired, "malloc_logger not exported by libsystem_malloc on this macOS"))
    func mallocCounterSyphonPublishReusesItsRenderPass() throws {
        try #require(MallocCounter.available, "malloc_logger not exported by libsystem_malloc on this macOS")
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }  // no GPU: skip
        let output = try SyphonOutput(name: "FanousTest-\(UUID().uuidString)", device: device)
        defer { output.stop() }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalContext.canvasFormat, width: 64, height: 64, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        let canvas = try #require(device.makeTexture(descriptor: descriptor))
        var allocations = 0
        for _ in 0..<20 {  // warm-up: the surface, Metal's caches
            let commandBuffer = try #require(queue.makeCommandBuffer())
            allocations = MallocCounter.count { output.publish(texture: canvas, commandBuffer: commandBuffer) }
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }
        #if !DEBUG
            #expect(allocations == 4, "one Syphon publish: \(allocations) allocations on the calling thread")
        #endif
        print("Syphon publish: \(allocations) allocations on the calling thread")
    }

    /// B106: a message callback already past CFMessagePort's validity check went on to use a receiver its owner had
    /// just invalidated and released. Messages stream in from another thread while the receiver is invalidated and
    /// dropped, 100 times; the payload takes a while to unarchive, which holds the window open between the check and
    /// the callback's use of the receiver. Before the fix the process died here on every run.
    @Test func receiverOutlivesACallbackInFlightWhenInvalidated() async throws {
        let rounds = 100
        let (created, delivered, freed) = try await offPool {  // blocks on semaphores for about a second
            guard let receiverClass = NSClassFromString("SyphonMessageReceiver") else { return (0, 0, 0) }
            class_addProtocol(receiverClass, SyphonMessageReceiving.self)
            guard let receiverType = receiverClass as? SyphonMessageReceiving.Type else { return (0, 0, 0) }
            var created = 0, delivered = 0, freed = 0
            for _ in 0..<rounds {
                let name = "FanousTest-\(UUID().uuidString)"
                let firstMessage = DispatchSemaphore(value: 0), senderDone = DispatchSemaphore(value: 0)
                var receiver = receiverType.init(
                    forName: name, protocol: "SyphonMessagingProtocolCFMessage_v1", allowedClasses: NSSet(objects: NSArray.self, NSString.self),
                    handler: { _, _ in firstMessage.signal() })
                guard receiver != nil else { continue }
                created += 1
                Thread.detachNewThread {  // send until the port goes invalid
                    let payload = try! NSKeyedArchiver.archivedData(withRootObject: (0..<2000).map { "\($0)" } as NSArray, requiringSecureCoding: true)
                    if let remote = CFMessagePortCreateRemote(nil, name as CFString) {
                        while CFMessagePortSendRequest(remote, 1, payload as CFData, 1, 0, nil, nil) == kCFMessagePortSuccess {}
                        CFMessagePortInvalidate(remote)
                    }
                    senderDone.signal()
                }
                if firstMessage.wait(timeout: .now() + 2) == .success { delivered += 1 }
                weak let released = receiver
                receiver?.invalidate()
                receiver = nil
                senderDone.wait()
                if Self.wait(seconds: 2, until: { released == nil }) { freed += 1 }  // the port's reference went with -invalidate
            }
            return (created, delivered, freed)
        }
        #expect(created == rounds)
        #expect(delivered == rounds)
        #expect(freed == rounds)
    }

    // MARK: numbered servers (B61)

    static func info(_ app: String, _ server: String = "", _ uuid: String) -> LiveCatalog.Entry {
        LiveCatalog.Entry(kind: .syphon, file: 0, source: app, name: server, runtimeID: uuid)
    }

    /// The directory's servers reach the catalog as entries: app → source, server name → name, directory id → runtimeID.
    @Test func catalogReadsTheDirectoryAsEntries() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }  // no GPU: skip
        let name = "FanousTest-\(UUID().uuidString)"
        let output = try SyphonOutput(name: name, device: device)
        let input = SyphonInput(device: device)  // keeps the directory listening
        defer {
            input.disconnect()
            output.stop()
        }
        // The directory learns about servers through distributed notifications, which need the main run loop.
        #expect(Self.wait(seconds: 2) { LiveCatalog.syphonDirectory.contains { $0.name == name } })
        let info = try #require(SyphonInput.directoryServers.first { $0.serverName == name })
        let entry = try #require(LiveCatalog.syphonDirectory.first { $0.name == name })
        #expect(entry.kind == .syphon && entry.source == info.appName && !entry.source.isEmpty)
        #expect(entry.runtimeID == output.uuid && entry.runtimeID == info.uuid)
    }

    @Test func catalogNumbersServersInAnnounceOrderAndKeepsNumbersWhenTheyGo() {
        var list: [LiveCatalog.Entry] = []
        #expect(LiveCatalog.assign(&list, running: [Self.info("Resolume", "Out", "a"), Self.info("Simple Server", "", "b")]))
        #expect(list.map(\.file) == [150, 151])
        #expect(list.map(\.label) == ["Resolume/Out", "Simple Server"])
        #expect(list.allSatisfy { $0.running })
        #expect(!LiveCatalog.assign(&list, running: [Self.info("Resolume", "Out", "a"), Self.info("Simple Server", "", "b")]))

        // a gone server keeps its number; a new one takes the next, never the gone one's
        #expect(LiveCatalog.assign(&list, running: [Self.info("Simple Server", "", "b"), Self.info("fanousd", "Fanous – Canvas", "c")]))
        #expect(list.map(\.file) == [150, 151, 152])
        #expect(list[0].runtimeID == nil && !list[0].running && list[0].label == "Resolume/Out")
        #expect(list[2].label == "fanousd/Fanous – Canvas")

        // back under the same name with a new id: its old number
        #expect(LiveCatalog.assign(&list, running: [Self.info("Resolume", "Out", "a2"), Self.info("Simple Server", "", "b"), Self.info("fanousd", "Fanous – Canvas", "c")]))
        #expect(list.count == 3 && list[0].runtimeID == "a2")

        // two servers with one name (two engines' canvases) get a number each; a rename keeps the number
        #expect(LiveCatalog.assign(&list, running: [Self.info("fanousd", "Fanous – Canvas", "c"), Self.info("fanousd", "Fanous – Canvas", "d"), Self.info("Simple Server", "Renamed", "b")]))
        #expect(list.map(\.file) == [150, 151, 152, 153])
        #expect(list[1].label == "Simple Server/Renamed" && list[3].runtimeID == "d" && list[0].runtimeID == nil)
    }

    @Test func catalogHasTwentyNumbers() {
        var list: [LiveCatalog.Entry] = []
        _ = LiveCatalog.assign(&list, running: (0..<25).map { Self.info("App", "S\($0)", "u\($0)") })
        #expect(list.count == 20 && list.last?.file == 169 && list.last?.name == "S19")
        // full: a gone server still holds its number, a new one gets none
        _ = LiveCatalog.assign(&list, running: [Self.info("Other", "", "x")])
        #expect(list.count == 20 && list.allSatisfy { !$0.running })
    }

    // MARK: numbers kept in the project (B69)

    @Test func numberingSurvivesARestartThroughTheProject() {
        let first = LiveCatalog(.syphon)
        first.update(running: [Self.info("Resolume", "Out", "a"), Self.info("Simple Server", "", "b"), Self.info("MadMapper", "", "c")])
        let project: JSONValue = ["syphon": ProjectDocument.liveValue(first.entries)]

        // the next engine starts from the project: every number held, gone until its server announces
        let next = LiveCatalog(.syphon, numbers: ProjectDocument.liveNumbers(.syphon, from: project))
        #expect(next.entries.map(\.file) == [150, 151, 152])
        #expect(next.entries.allSatisfy { $0.gone && !$0.running })
        #expect(next.entry(file: 151)?.label == "Simple Server")

        // they answer in another order, with new ids: each takes its own number back by name
        next.update(running: [Self.info("MadMapper", "", "c2"), Self.info("Resolume", "Out", "a2")])
        #expect(next.entry(file: 150)?.runtimeID == "a2" && next.entry(file: 152)?.runtimeID == "c2")
        #expect(next.entry(file: 151)?.gone == true && next.entry(file: 150)?.gone == false)
        // a new server gets the lowest free number, not a held one
        next.update(running: [Self.info("MadMapper", "", "c2"), Self.info("Resolume", "Out", "a2"), Self.info("New", "", "n")])
        #expect(next.entry(file: 153)?.label == "New")

        // forgetting 151 (the project without it) frees the number for the next new server
        let forgotten = next.entries.filter { $0.file != 151 }
        #expect(next.adopt(forgotten))
        #expect(next.entry(file: 151) == nil)
        next.update(running: [Self.info("MadMapper", "", "c2"), Self.info("Resolume", "Out", "a2"), Self.info("New", "", "n"), Self.info("Later", "", "l")])
        #expect(next.entry(file: 151)?.label == "Later")

        // a project entry on a running server's number loses: the running server keeps it
        #expect(!next.adopt([LiveCatalog.Entry(kind: .syphon, file: 150, source: "Elsewhere", name: "")] + next.entries.filter { $0.file != 150 }))
        #expect(next.entry(file: 150)?.runtimeID == "a2")
    }

    /// Undo or a loaded version bringing back a name that runs on another number: dropped, or that server would move to
    /// the lower number at the next restart. A gone twin the catalog already holds (two canvases, one name) stays.
    @Test func adoptDropsANewEntryWithARunningServersName() {
        let catalog = LiveCatalog(.syphon)
        catalog.update(running: [Self.info("Other", "", "o"), Self.info("fanousd", "Fanous – Canvas", "x"), Self.info("fanousd", "Fanous – Canvas", "y")])
        catalog.update(running: [Self.info("Other", "", "o"), Self.info("fanousd", "Fanous – Canvas", "x")])
        #expect(catalog.entry(file: 152)?.running == false)  // the twin that stopped
        let restored = catalog.entries + [LiveCatalog.Entry(kind: .syphon, file: 160, source: "fanousd", name: "Fanous – Canvas")]
        #expect(!catalog.adopt(restored))
        #expect(catalog.entries.map(\.file) == [150, 151, 152])
        // nothing running under that name: a restored entry is taken as gone
        #expect(catalog.adopt(restored + [LiveCatalog.Entry(kind: .syphon, file: 161, source: "Gone App", name: "")]))
        #expect(catalog.entry(file: 161)?.gone == true)
    }

    @Test func aTwentyFirstServerWaitsForAForgottenNumber() {
        let full = (150...169).map { LiveCatalog.Entry(kind: .syphon, file: $0, source: "App", name: "S\($0)") }
        let catalog = LiveCatalog(.syphon, numbers: full)
        catalog.update(running: [Self.info("Other", "", "x")])
        #expect(catalog.entries.count == 20 && catalog.entry(file: 150)?.label == "App/S150")
        #expect(catalog.unnumbered == ["Other"])
        // forget 160: the waiting server gets it without announcing again
        #expect(catalog.adopt(full.filter { $0.file != 160 }))
        #expect(catalog.entry(file: 160)?.runtimeID == "x" && catalog.unnumbered.isEmpty)
    }

    final class FakeLive: LiveTextureSource, @unchecked Sendable {
        let uuid: String?
        let stopped = Atomic<Bool>(false)
        init(uuid: String?) { self.uuid = uuid }
        var latestFrame: LiveFrame? { nil }
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
        let catalog = LiveCatalog(.syphon)
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
        #expect(catalog.entry(file: 150)?.runtimeID == "a2")

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
        #expect(playback(1) === connected && catalog.entry(file: 150)?.file == 150)
    }

    @Test func loaderSaysCouldNotConnectWhenARunningServerRefuses() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = RenderLayer(index: 0)
        let loader = MediaLoader(layers: [layer], media: [], device: device, ringCapacity: 4, logger: Logger(label: "test"))
        loader.liveFactory = { _, _ in nil }
        let catalog = LiveCatalog(.syphon)
        catalog.update(running: [Self.info("App", "", "a")])
        loader.syphonCatalog = catalog
        loader.start()
        defer { loader.stop() }
        layer.wanted.store(MediaKey(folder: 0, file: 150).packed, ordering: .relaxed)
        loader.wake.signal()
        #expect(Self.wait(seconds: 5) { layer.mediaStatus.withLock { $0.error == "could not connect" && $0.name == "Syphon: App" } })
    }

    @Test func catalogLeavesTheEnginesOwnServerOut() {
        let catalog = LiveCatalog(.syphon, excluding: "own")
        catalog.update(running: [Self.info("fanousd", "Fanous – Canvas", "own"), Self.info("Resolume", "Out", "a")])
        #expect(catalog.entries.map(\.label) == ["Resolume/Out"])
        #expect(catalog.entry(file: 150)?.runtimeID == "a")
    }
}

/// The private SyphonMessageReceiver API, reached through the Objective-C runtime (its header is not public).
@objc private protocol SyphonMessageReceiving {
    @objc(initForName:protocol:allowedClasses:handler:)
    init?(forName name: String, protocol protocolName: String, allowedClasses: NSSet, handler: @escaping (AnyObject?, UInt32) -> Void)
    func invalidate()
}
