// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Metal
import Synchronization
import Testing

@testable import FanousEngine

/// B277: file opens run on threads of their own, a few at a time; a file that does not answer holds up only its layer.
@Suite(.cleansTempFiles) struct MediaLoaderTests {
    /// A playback whose `stop()` is counted.
    final class Stoppable: LiveTextureSource {
        let stops = Atomic<Int>(0)
        var latestFrame: LiveFrame? { nil }
        func stop() { stops.wrappingAdd(1, ordering: .relaxed) }
    }

    /// The opener tests stand in: a file whose name is held waits until the test lets it go, one whose name is failing
    /// then throws; running opens are counted.
    final class Opens: Sendable {
        struct Failed: Error {}
        let held = Mutex<Set<String>>([])
        let failing = Mutex<Set<String>>([])
        let started = Mutex<[String]>([])
        let finished = Mutex<[String]>([])
        let running = Atomic<Int>(0)
        let most = Atomic<Int>(0)

        func open(_ url: URL) throws -> MediaLoader.OpenedFile {
            let name = url.lastPathComponent
            started.withLock { $0.append(name) }
            let now = running.wrappingAdd(1, ordering: .relaxed).newValue
            most.max(now, ordering: .relaxed)
            while held.withLock({ $0.contains(name) }) { usleep(1000) }
            running.wrappingSubtract(1, ordering: .relaxed)
            finished.withLock { $0.append(name) }
            if failing.withLock({ $0.contains(name) }) { throw Failed() }
            return .still(DecodedFrame(poolIndex: 0))
        }
    }

    /// `count` layers on a loader whose files 1/1 … 1/9 are `<n>.png` (never read: `opens` stands in for the opener).
    static func loader(layers count: Int, opens: Opens?, deadline: Duration = .seconds(60), media: [MediaEntry]? = nil) throws -> (MediaLoader, [RenderLayer]) {
        let layers = (0..<count).map { RenderLayer(index: $0) }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let entries = media ?? (1...9).map { MediaEntry(folder: 1, file: $0, path: "/nonexistent/\($0).png") }
        let loader = MediaLoader(layers: layers, media: entries, device: device, ringCapacity: 4, logger: testLogger)
        if let opens { loader.openFile = { url, _ in try opens.open(url) } }
        loader.openDeadline = deadline
        return (loader, layers)
    }

    /// What the loader handed `layer` since the last look, as the compositor takes it; nil = nothing new.
    static func take(_ layer: RenderLayer) -> MediaKey? {
        layer.pending.withLock { box -> MediaKey? in
            guard box.set else { return nil }
            defer { box.set = false; box.playback = nil }
            return box.playback?.key ?? MediaKey(packed: 0)
        }
    }

    static func select(_ layer: RenderLayer, _ file: Int, _ loader: MediaLoader) {
        layer.wanted.store(MediaKey(folder: 1, file: file).packed, ordering: .relaxed)
        loader.wake.signal()
    }

    /// The real opener on a FIFO: AVFoundation's open blocks until something writes, as on a volume that does not
    /// answer. Another layer's file opens meanwhile, and a playback the compositor let go of is stopped. On the old
    /// single loader thread both waited until the FIFO was released.
    @Test func aFileThatDoesNotAnswerHoldsUpOnlyItsOwnLayer() async throws {
        let dir = try tempDir("loader")
        let fifo = dir.appending(path: "hang.mov"), still = dir.appending(path: "still.png")
        try #require(mkfifo(fifo.path, 0o644) == 0)
        try writePNG(try cgImage(rgba: [255, 0, 0, 255], width: 1, height: 1), to: still)
        let (loader, layers) = try Self.loader(
            layers: 3, opens: nil, media: [MediaEntry(folder: 1, file: 1, path: fifo.path), MediaEntry(folder: 1, file: 2, path: still.path)])
        loader.start()
        defer { loader.stop() }
        // a write end opened and closed lets every blocked reader of the FIFO go (the open then fails): the cleanup
        let release = {
            let fd = open(fifo.path, O_WRONLY | O_NONBLOCK)  // fails at once (ENXIO) while no reader waits
            if fd >= 0 { close(fd) }
        }
        defer { release() }
        Self.select(layers[0], 1, loader)
        Self.select(layers[1], 2, loader)
        #expect(await waitUntil(.seconds(5)) { Self.take(layers[1]) == MediaKey(folder: 1, file: 2) }, "layer 2 waited for layer 1's file")
        let retired = Stoppable()
        layers[2].retired.withLock { $0.append(LayerPlayback(key: MediaKey(folder: 1, file: 3), live: retired)) }
        loader.wake.signal()
        #expect(await waitUntil(.seconds(5)) { retired.stops.load(ordering: .relaxed) == 1 }, "a retired playback was not stopped")
        #expect(Self.take(layers[0]) == nil, "the FIFO answered")
        // let it go: the open fails and the layer says so
        #expect(await waitUntil {
            release()
            return layers[0].mediaStatus.withLock { $0.error } != nil
        })
        #expect(Self.take(layers[0]) == MediaKey(packed: 0))
    }

    /// An open that does not answer within the deadline is given up: the layer says so, keeps its picture (nothing is
    /// handed over) and loads the next selection. When the given-up open answers later, it is dropped: the layer's last
    /// selection wins whatever order the opens answer in.
    @Test func aGivenUpOpenLetsTheLayerLoadAnotherAndItsLateAnswerIsDropped() async throws {
        let opens = Opens()
        opens.held.withLock { $0 = ["1.png"] }
        let (loader, layers) = try Self.loader(layers: 1, opens: opens, deadline: .milliseconds(50))
        loader.start()
        defer { loader.stop() }
        defer { opens.held.withLock { $0 = [] } }
        Self.select(layers[0], 1, loader)
        #expect(await waitUntil { layers[0].mediaStatus.withLock { $0.file == 1 && $0.error == "not answering: the volume is slow or gone" } })
        #expect(Self.take(layers[0]) == nil, "a given-up open handed something over")
        Self.select(layers[0], 2, loader)
        #expect(await waitUntil { Self.take(layers[0]) == MediaKey(folder: 1, file: 2) }, "the layer did not load the next file")
        #expect(layers[0].mediaStatus.withLock { $0.file == 2 && $0.error == nil })
        opens.held.withLock { $0 = [] }
        #expect(await waitUntil { opens.finished.withLock { $0 } == ["2.png", "1.png"] })
        // nothing to wait for: a late answer that is dropped changes nothing; three loader passes
        try await Task.sleep(for: .milliseconds(300))
        #expect(Self.take(layers[0]) == nil, "the late answer replaced the newer selection")
        #expect(layers[0].mediaStatus.withLock { $0.file } == 2)
    }

    /// A given-up open that answers while it is still the layer's last selection plays (a disk that spun up late).
    @Test func aGivenUpOpenStillPlaysWhenItAnswers() async throws {
        let opens = Opens()
        opens.held.withLock { $0 = ["1.png"] }
        let (loader, layers) = try Self.loader(layers: 1, opens: opens, deadline: .milliseconds(50))
        loader.start()
        defer { loader.stop() }
        defer { opens.held.withLock { $0 = [] } }
        Self.select(layers[0], 1, loader)
        #expect(await waitUntil { layers[0].mediaStatus.withLock { $0.error } != nil })
        opens.held.withLock { $0 = [] }
        #expect(await waitUntil { Self.take(layers[0]) == MediaKey(folder: 1, file: 1) })
        #expect(layers[0].mediaStatus.withLock { $0.kind == "still" && $0.error == nil })
    }

    /// The last selection wins also when the newer one has not started: an open that answers after the layer moved on
    /// is dropped, whether it was given up (its newer file waits for the one open thread) or still in flight (its newer
    /// file waits for it). The dropped one is never handed over; nothing replaces it while the newer file is held.
    @Test(arguments: [true, false])
    func anAnswerTheLayerMovedAwayFromIsDropped(givenUp: Bool) async throws {
        let opens = Opens()
        opens.held.withLock { $0 = ["1.png", "2.png"] }
        let (loader, layers) = try Self.loader(layers: 1, opens: opens, deadline: givenUp ? .milliseconds(50) : .seconds(60))
        loader.maxOpenThreads = 1
        loader.start()
        defer { loader.stop() }
        defer { opens.held.withLock { $0 = [] } }
        Self.select(layers[0], 1, loader)
        #expect(await waitUntil { opens.started.withLock { $0 } == ["1.png"] })
        if givenUp { #expect(await waitUntil { layers[0].mediaStatus.withLock { $0.error } != nil }) }
        Self.select(layers[0], 2, loader)
        try await Task.sleep(for: .milliseconds(100))  // nothing to wait for: 2 cannot start while 1 holds the one thread
        opens.held.withLock { $0.remove("1.png") }
        #expect(await waitUntil { opens.started.withLock { $0 } == ["1.png", "2.png"] }, "1's answer was not taken")
        #expect(Self.take(layers[0]) == nil, "the open the layer moved away from was handed over")
        opens.held.withLock { $0 = [] }
        #expect(await waitUntil { Self.take(layers[0]) == MediaKey(folder: 1, file: 2) })
    }

    /// A given-up open that fails later writes the layer's status but hands nothing over: the layer keeps the picture it
    /// kept at the give-up. A failure within the deadline still hands over no media (B299, unchanged).
    @Test func aGivenUpOpenThatFailsKeepsThePicture() async throws {
        let opens = Opens()
        opens.held.withLock { $0 = ["1.png"] }
        opens.failing.withLock { $0 = ["1.png", "2.png"] }
        let (loader, layers) = try Self.loader(layers: 1, opens: opens, deadline: .milliseconds(50))
        loader.start()
        defer { loader.stop() }
        defer { opens.held.withLock { $0 = [] } }
        Self.select(layers[0], 1, loader)
        #expect(await waitUntil { layers[0].mediaStatus.withLock { $0.error } == "not answering: the volume is slow or gone" })
        opens.held.withLock { $0 = [] }
        #expect(await waitUntil { layers[0].mediaStatus.withLock { $0.file == 1 && $0.error != nil && $0.error != "not answering: the volume is slow or gone" } })
        try await Task.sleep(for: .milliseconds(300))  // nothing to wait for: no hand-off follows the status
        #expect(Self.take(layers[0]) == nil, "a late failure cut the layer to black")
        Self.select(layers[0], 2, loader)
        #expect(await waitUntil { Self.take(layers[0]) == MediaKey(packed: 0) }, "a failure within the deadline hands over no media")
    }

    /// A selection that is not a file (clear, a missing number, a live input) is handed over at once while an open is in
    /// flight on the layer, and the open's late answer is dropped.
    @Test func aSelectionThatIsNotAFileDoesNotWaitForAnOpen() async throws {
        let opens = Opens()
        opens.held.withLock { $0 = ["1.png"] }
        let (loader, layers) = try Self.loader(layers: 1, opens: opens)
        loader.start()
        defer { loader.stop() }
        defer { opens.held.withLock { $0 = [] } }
        Self.select(layers[0], 1, loader)
        #expect(await waitUntil { opens.started.withLock { $0 } == ["1.png"] })
        layers[0].wanted.store(0, ordering: .relaxed)
        loader.wake.signal()
        #expect(await waitUntil(.seconds(2)) { Self.take(layers[0]) == MediaKey(packed: 0) }, "a clear waited for the open")
        layers[0].wanted.store(MediaKey(folder: 2, file: 1).packed, ordering: .relaxed)  // no such file: "missing"
        loader.wake.signal()
        #expect(await waitUntil(.seconds(2)) { Self.take(layers[0]) == MediaKey(packed: 0) })
        #expect(layers[0].mediaStatus.withLock { $0.kind } == "missing")
        opens.held.withLock { $0 = [] }
        #expect(await waitUntil { opens.finished.withLock { $0 } == ["1.png"] })
        try await Task.sleep(for: .milliseconds(300))  // nothing to wait for: the dropped answer changes nothing
        #expect(Self.take(layers[0]) == nil, "the late answer replaced the newer selection")
        #expect(layers[0].mediaStatus.withLock { $0.kind } == "missing")
    }

    /// After a non-file selection the layer no longer waits for its open: the deadline does not write "not answering"
    /// over the new selection's status.
    @Test func aGiveUpDoesNotWriteOverANewerSelection() async throws {
        let opens = Opens()
        opens.held.withLock { $0 = ["1.png"] }
        let (loader, layers) = try Self.loader(layers: 1, opens: opens, deadline: .milliseconds(100))
        loader.start()
        defer { loader.stop() }
        defer { opens.held.withLock { $0 = [] } }
        Self.select(layers[0], 1, loader)
        #expect(await waitUntil { opens.started.withLock { $0 } == ["1.png"] })
        layers[0].wanted.store(MediaKey(folder: 2, file: 1).packed, ordering: .relaxed)
        loader.wake.signal()
        #expect(await waitUntil { layers[0].mediaStatus.withLock { $0.kind } == "missing" })
        try await Task.sleep(for: .milliseconds(300))  // past the deadline of the open
        #expect(layers[0].mediaStatus.withLock { $0.kind == "missing" && $0.folder == 2 })
    }

    /// A thread stuck in an open keeps no stopped loader alive (the layers, the mixer, live inputs).
    @Test func aStuckOpenKeepsNoStoppedLoaderAlive() async throws {
        let opens = Opens()
        opens.held.withLock { $0 = ["1.png"] }
        defer { opens.held.withLock { $0 = [] } }
        weak var gone: MediaLoader?
        do {
            let (loader, layers) = try Self.loader(layers: 1, opens: opens)
            gone = loader
            loader.start()
            Self.select(layers[0], 1, loader)
            #expect(await waitUntil { opens.started.withLock { $0 } == ["1.png"] })
            loader.stop()
        }
        #expect(await waitUntil { gone == nil }, "the open thread holds the stopped loader")
    }

    /// At most `maxOpens` opens run within their deadline, and at most `maxOpenThreads` threads are in opens at all
    /// (given-up ones included); every layer gets its file once they answer.
    @Test(arguments: [(Duration.seconds(60), 2), (.milliseconds(20), 3)])
    func opensAreBounded(deadline: Duration, bound: Int) async throws {
        let opens = Opens()
        opens.held.withLock { $0 = Set((1...6).map { "\($0).png" }) }
        let (loader, layers) = try Self.loader(layers: 6, opens: opens, deadline: deadline)
        loader.maxOpens = 2
        loader.maxOpenThreads = 3
        loader.start()
        defer { loader.stop() }
        defer { opens.held.withLock { $0 = [] } }
        for layer in layers { Self.select(layer, layer.index + 1, loader) }
        #expect(await waitUntil { opens.started.withLock { $0.count } == bound })
        try await Task.sleep(for: .milliseconds(300))  // nothing to wait for: no further open starts
        #expect(opens.started.withLock { $0.count } == bound, "more opens ran than the bound")
        opens.held.withLock { $0 = [] }
        var got: [MediaKey?] = Array(repeating: nil, count: 6)
        #expect(await waitUntil {
            for layer in layers where got[layer.index] == nil { got[layer.index] = Self.take(layer) }
            return !got.contains(nil)
        })
        #expect(got == (1...6).map { MediaKey(folder: 1, file: $0) })
        #expect(opens.most.load(ordering: .relaxed) == bound)
    }
}
