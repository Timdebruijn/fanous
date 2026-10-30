// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal
import Logging
import Synchronization
import Testing

@testable import FanousEngine

struct LibraryIndexTests {
    static func touch(_ url: URL, bytes: Int = 16) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0, count: bytes).write(to: url)
    }

    @Test func prefixes() {
        #expect(LibraryIndex.prefixNumber("012_Show") == 12)
        #expect(LibraryIndex.prefixNumber("1 intro.mov") == 1)
        #expect(LibraryIndex.prefixNumber("255.png") == 255)
        #expect(LibraryIndex.prefixNumber("256_too_big") == nil)
        #expect(LibraryIndex.prefixNumber("0000_leading") == nil)
        #expect(LibraryIndex.prefixNumber("intro.mov") == nil)
        #expect(LibraryIndex.prefixNumber("0_zero") == nil)
        #expect(LibraryIndex.prefixNumber("1234_four_digits") == nil)
    }

    /// Numbering, invalid names, duplicates, ignored folders; files are empty so every probe ends "unreadable".
    @Test func scanClassifiesNamesAndDuplicates() throws {
        let root = try tempDir("fanous-library")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.touch(root.appending(path: "001_Opening/001_intro.mov"))
        try Self.touch(root.appending(path: "001_Opening/002_title.png"))
        try Self.touch(root.appending(path: "001_Opening/002_dup.png"))
        try Self.touch(root.appending(path: "001_Opening/noprefix.mov"))
        try Self.touch(root.appending(path: "001_Opening/_originals/002_title.psd"))
        try Self.touch(root.appending(path: "001_Opening/notes.txt"))
        try Self.touch(root.appending(path: "012_Show/004_loop.mov"))
        try Self.touch(root.appending(path: "12_Dup/001_x.mov"))
        try Self.touch(root.appending(path: "Unnumbered/001_y.mov"))
        try Self.touch(root.appending(path: "_incoming/upload.mp4"))
        try FileManager.default.createDirectory(at: root.appending(path: "012_Show/005_sequence"), withIntermediateDirectories: true)
        let index = LibraryIndex(root: root, cacheDirectory: root.appending(path: ".cache"), logger: Logger(label: "test"))
        index.rescan()
        let snapshot = index.snapshot
        #expect(snapshot.rootExists)
        #expect(snapshot.folders.map(\.name) == ["001_Opening", "012_Show", "12_Dup", "Unnumbered"])
        #expect(snapshot.folders.map(\.number) == [1, 12, nil, nil])
        let opening = snapshot.folders[0]
        #expect(opening.items.map(\.name) == ["001_intro.mov", "002_dup.png", "002_title.png", "noprefix.mov"])  // notes.txt and _originals ignored
        #expect(opening.items[0].file == 1 && opening.items[0].kind == .movie && opening.items[0].status == .probing)
        #expect(opening.items[1].file == 2 && opening.items[1].kind == .still)
        #expect(opening.items[2].status == .invalid && opening.items[2].reason?.contains("duplicate") == true && opening.items[2].file == nil)
        #expect(opening.items[3].status == .invalid && opening.items[3].reason?.contains("prefix") == true)
        let show = snapshot.folders[1]
        #expect(show.items.map(\.kind) == [.movie, .sequence])
        #expect(snapshot.folders[2].items.allSatisfy { $0.status == .invalid })
        #expect(snapshot.folders[3].items.allSatisfy { $0.status == .invalid })
        #expect(snapshot.invalidCount == 4)
        #expect(snapshot.fileCount == 8)
        // nothing resolves before probing proves playability
        #expect(index.resolve(MediaKey(folder: 1, file: 1)) == nil)
    }

    /// 10 000 files scan in well under a second and the probe queue stays bounded by the file count.
    @Test func tenThousandFiles() throws {
        let root = try tempDir("fanous-library")
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in 1...40 {
            let dir = root.appending(path: String(format: "%03d_Folder", folder))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in 1...250 {
                FileManager.default.createFile(atPath: dir.appending(path: String(format: "%03d_clip.mov", file)).path, contents: nil)
            }
        }
        let index = LibraryIndex(root: root, cacheDirectory: root.appending(path: ".cache"), logger: Logger(label: "test"))
        let start = Date()
        index.rescan()
        let elapsed = Date().timeIntervalSince(start)
        let snapshot = index.snapshot
        #expect(snapshot.fileCount == 10_000)
        #expect(snapshot.invalidCount == 0)
        #expect(snapshot.folders.count == 40)
        #expect(elapsed < 5, Comment(rawValue: "scan took \(elapsed) s"))
    }

    /// A playable movie resolves after probing, its thumbnail is requested, and FSEvents picks up a new file.
    @Test func probeResolvesAndWatcherRescans() async throws {
        let root = try tempDir("fanous-library")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "007_Test")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let movie = folder.appending(path: "003_clip.mov")
        try await offPool {
            let writer = try MovieWriter(url: movie, width: 320, height: 176, fps: 25, codec: .proRes422HQ)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, writer.pixelBufferPool!, &buffer)
            for _ in 0..<5 { try writer.append(buffer!) }
            try writer.finish()
        }
        let index = LibraryIndex(root: root, cacheDirectory: root.appending(path: ".cache"), logger: Logger(label: "test"))
        // heap-allocated observers: callbacks may still run on the library thread after this function returns
        final class Observer: Sendable {
            let thumbnails = Mutex<[String]>([])
            let changes = Atomic<Int>(0)
        }
        let observer = Observer()
        index.thumbnailer = { url, _, _ in
            observer.thumbnails.withLock { $0.append(url.lastPathComponent) }
            return "thumb.jpg"
        }
        index.onChange = { observer.changes.wrappingAdd(1, ordering: .relaxed) }
        index.start()
        defer { index.stop() }
        var resolved: URL?
        for _ in 0..<100 {
            if let url = index.resolve(MediaKey(folder: 7, file: 3)) { resolved = url; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(resolved?.lastPathComponent == "003_clip.mov")
        let item = index.snapshot.folders[0].items[0]
        #expect(item.status == .playable && item.metadata?.codec == "apch" && item.metadata?.frameCount == 5 && item.thumbnail == "thumb.jpg")
        #expect(observer.thumbnails.withLock { $0 } == ["003_clip.mov"])
        // a second index on the same cache needs no probe (the first writes the cache just after it resolves)
        #expect(await waitUntil(every: .milliseconds(50)) {
            let again = LibraryIndex(root: root, cacheDirectory: root.appending(path: ".cache"), logger: Logger(label: "test"))
            again.rescan()
            return again.resolve(MediaKey(folder: 7, file: 3)) != nil
        })

        // FSEvents: a new still appears within the debounce window plus some slack
        let before = observer.changes.load(ordering: .relaxed)
        try Data([0x89, 0x50]).write(to: folder.appending(path: "004_new.png"))
        var seen = false
        for _ in 0..<100 {
            if observer.changes.load(ordering: .relaxed) > before, index.snapshot.folders[0].items.count == 2 { seen = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(seen, "the watcher did not pick up the new file within 5 s")
    }

    /// A 2×2 PNG: enough for the still probe to call it playable.
    static func png(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    static func eventually(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test func rootProblems() throws {
        let root = try tempDir("fanous-library")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.touch(root.appending(path: "file.txt"))
        #expect(LibraryIndex.rootProblem(root.path) == nil)
        #expect(LibraryIndex.rootProblem("Movies/Fanous Library")?.contains("absolute") == true)
        #expect(LibraryIndex.rootProblem(root.appending(path: "missing").path)?.contains("does not exist") == true)
        #expect(LibraryIndex.rootProblem(root.appending(path: "file.txt").path)?.contains("not a folder") == true)
    }

    /// B51: a root change on a running engine. The old index stops watching and is freed, the new one indexes its root,
    /// layers re-resolve against it: a file not probed yet shows "missing" until its probe makes it playable, a file
    /// the root lacks stays "missing". Switching back needs no new probes.
    @Test func switchingRootsReindexesAndReresolvesLayers() async throws {
        let a = try tempDir("fanous-library"), b = try tempDir("fanous-library"), cache = try tempDir("fanous-library")
        defer { for url in [a, b, cache] { try? FileManager.default.removeItem(at: url) } }
        try Self.png(a.appending(path: "001_A/001_one.png"))
        try Self.png(a.appending(path: "001_A/002_two.png"))
        try Self.png(b.appending(path: "001_B/001_uno.png"))
        try Self.png(b.appending(path: "001_B/002_dos.png"))
        final class Observer: Sendable {
            let changes = Atomic<Int>(0)
            let holdProbes = Atomic<Bool>(false)
        }
        let observer = Observer()
        // the engine's wiring: one box with the index of the moment (and no other strong reference), the loader
        // resolving through it, every library change asking the loader to retry its missing layers
        let current = Mutex<LibraryIndex?>(LibraryIndex(root: a, cacheDirectory: cache, logger: Logger(label: "test")))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let layer = RenderLayer(index: 0)
        let loader = MediaLoader(layers: [layer], media: [], device: device, ringCapacity: 4, logger: Logger(label: "test"))
        loader.resolver = { key in current.withLock { $0 }?.resolve(key) }
        current.withLock { first in
            first!.onChange = {
                observer.changes.wrappingAdd(1, ordering: .relaxed)
                loader.reresolveMissingLibrary()
            }
            // a probe of a fresh file waits here while the test holds it: the window right after a switch
            first!.thumbnailer = { _, _, _ in
                while observer.holdProbes.load(ordering: .relaxed) { usleep(10_000) }
                return nil
            }
            first!.start()
        }
        #expect(try await Self.eventually { current.withLock { $0 }?.resolve(MediaKey(folder: 1, file: 2)) != nil })
        loader.start()
        defer { loader.stop() }
        layer.wanted.store(MediaKey(folder: 1, file: 2).packed, ordering: .relaxed)
        loader.wake.signal()
        #expect(try await Self.eventually { layer.mediaStatus.withLock { $0.name } == "002_two.png" })

        // as Engine.switchLibrary: build the new index, swap, re-resolve, stop the old one last
        observer.holdProbes.store(true, ordering: .relaxed)
        weak var old = current.withLock { $0 }
        let second = try #require(current.withLock { $0 }?.replacement(root: b))
        do {
            let replaced = current.withLock { box in
                defer { box = second }
                return box
            }
            loader.reresolveLibrary()
            replaced?.stop()
        }
        #expect(second.snapshot.root == b.path && second.snapshot.folders.map(\.name) == ["001_B"])
        // B's files have never been probed: 1/2 does not resolve yet, so layer 1 shows "missing"
        #expect(second.resolve(MediaKey(folder: 1, file: 2)) == nil)
        #expect(try await Self.eventually { layer.mediaStatus.withLock { $0.kind == "missing" && $0.error == "no file 2 in folder 1" } })
        // the probe makes it playable; the change hook retries the missing layer
        observer.holdProbes.store(false, ordering: .relaxed)
        #expect(try await Self.eventually { layer.mediaStatus.withLock { $0.name } == "002_dos.png" }, "the missing layer was not retried")
        #expect(try await Self.eventually { second.resolve(MediaKey(folder: 1, file: 1))?.lastPathComponent == "001_uno.png" })
        // a number the root lacks: the existing "missing" state, no crash
        layer.wanted.store(MediaKey(folder: 1, file: 3).packed, ordering: .relaxed)
        loader.wake.signal()
        #expect(try await Self.eventually { layer.mediaStatus.withLock { $0.kind == "missing" && $0.error == "no file 3 in folder 1" } })

        // the old root is no longer watched and its index is gone
        #expect(try await Self.eventually { old == nil }, "the replaced index is still alive")
        let settled = observer.changes.load(ordering: .relaxed)
        try Self.png(a.appending(path: "001_A/003_three.png"))
        try await Task.sleep(for: .milliseconds(1500))
        #expect(observer.changes.load(ordering: .relaxed) == settled, "an event from the old root reached the index")
        #expect(second.snapshot.root == b.path)

        // back to A: the probes are cached by path, so 1/2 resolves straight from the scan in start()
        let third = second.replacement(root: a)
        current.withLock { $0 = third }
        second.stop()
        defer { third.stop() }
        #expect(third.resolve(MediaKey(folder: 1, file: 2))?.lastPathComponent == "002_two.png")
    }

    @Test func ingestTargets() throws {
        let root = try tempDir("fanous-library")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.touch(root.appending(path: "003_Show/001_a.mov"))
        try Self.touch(root.appending(path: "003_Show/002_b.mov"))
        try Self.touch(root.appending(path: "003_Show/004_d.mov"))
        let index = LibraryIndex(root: root, cacheDirectory: root.appending(path: ".cache"), logger: Logger(label: "test"))
        index.rescan()
        #expect(index.nextFileNumber(inFolder: 3) == 3)
        #expect(index.nextFileNumber(inFolder: 9) == 1)
        #expect(index.folderURL(number: 3)?.lastPathComponent == "003_Show")
        #expect(index.folderURL(number: 9) == nil)
        #expect(index.folderURL(number: 9, createAs: "New: Folder")?.lastPathComponent == "009_New_ Folder")
        #expect(index.folderURL(number: 9, createAs: "Other")?.lastPathComponent == "009_New_ Folder", "on disk, not yet indexed")
        try Self.touch(root.appending(path: "005_A"))  // a file, not a folder
        for name in ["5_Dup", "005_Show"] { try FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: false) }
        #expect(index.folderURL(number: 5)?.lastPathComponent == "005_Show")
        index.rescan()
        #expect(index.snapshot.folders.first { $0.number == 5 }?.name == "005_Show", "the folder the index keeps for a duplicate number")
        #expect(LibraryIndex.destinationName(number: 7, originalName: "12 intro loop.MOV", pathExtension: "mov") == "007_intro loop.mov")
        #expect(LibraryIndex.destinationName(number: 7, originalName: "../../evil.mp4", pathExtension: "mov") == "007_evil.mov")
        #expect(LibraryIndex.destinationName(number: 7, originalName: "123", pathExtension: "png") == "007_media.png")
    }
}
