// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreVideo
import Foundation
import Logging
import Synchronization
import Testing

@testable import FanousEngine

struct LibraryIndexTests {
    static func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "fanous-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

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
        let root = try Self.temporaryRoot()
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
        let root = try Self.temporaryRoot()
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
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "007_Test")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let movie = folder.appending(path: "003_clip.mov")
        let writer = try MovieWriter(url: movie, width: 320, height: 176, fps: 25, codec: .proRes422HQ)
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, writer.pixelBufferPool!, &buffer)
        for _ in 0..<5 { try writer.append(buffer!) }
        try writer.finish()
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
        // a second index on the same cache needs no probe
        let again = LibraryIndex(root: root, cacheDirectory: root.appending(path: ".cache"), logger: Logger(label: "test"))
        again.rescan()
        #expect(again.resolve(MediaKey(folder: 7, file: 3)) != nil)

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

    @Test func ingestTargets() throws {
        let root = try Self.temporaryRoot()
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
        #expect(LibraryIndex.destinationName(number: 7, originalName: "12 intro loop.MOV", pathExtension: "mov") == "007_intro loop.mov")
        #expect(LibraryIndex.destinationName(number: 7, originalName: "../../evil.mp4", pathExtension: "mov") == "007_evil.mov")
        #expect(LibraryIndex.destinationName(number: 7, originalName: "123", pathExtension: "png") == "007_media.png")
    }
}
