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

@Suite(.cleansTempFiles)
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

    /// B389: the decoder warm-up starts for a library with a ProRes movie the engine plays, and for no other.
    @Test func aLibraryHoldsProResOnlyWithAPlayableProResMovie() {
        func snapshot(_ codec: String, _ status: LibraryItem.Status) -> LibrarySnapshot {
            let item = LibraryItem(
                folder: 1, file: 1, name: "clip", path: "/lib/001_A/001_clip.mov", kind: .movie, status: status, reason: nil,
                metadata: MediaMetadata(width: 1920, height: 1080, frameRate: 25, duration: 10, codec: codec, hasAlpha: false, audioChannels: 0, audioSampleRate: 0, frameCount: 250),
                thumbnail: nil, modified: 0, size: 1)
            return LibrarySnapshot(root: "/lib", rootExists: true, folders: [LibraryFolder(number: 1, name: "A", path: "/lib/001_A", items: [item])], scannedAt: 0, fileCount: 1, invalidCount: 0)
        }
        #expect(snapshot("apch", .playable).holdsProRes)
        #expect(snapshot("ap4h", .playable).holdsProRes)
        #expect(!snapshot("Hap1", .playable).holdsProRes)
        #expect(!snapshot("apch", .needsTranscode).holdsProRes)  // ProRes in another container does not play
        #expect(!snapshot("apch", .probing).holdsProRes)
        #expect(!LibrarySnapshot.empty.holdsProRes)
    }

    /// B389: the index that replaces the engine's on another root starts the warm-up like it (the engine's own hook
    /// read the old index after a root change); a test's index does not. Empty roots: nothing to warm for.
    @Test func aReplacementIndexWarmsDecodersLikeTheOneItReplaces() throws {
        let cache = try tempDir("fanous-warm-cache")
        let index = LibraryIndex(root: try tempDir("fanous-warm-a"), cacheDirectory: cache, logger: testLogger)
        #expect(!index.warmsDecoders)
        let plain = index.replacement(root: try tempDir("fanous-warm-b"))
        defer { plain.stop() }
        #expect(!plain.warmsDecoders)
        index.warmsDecoders = true
        let next = index.replacement(root: try tempDir("fanous-warm-c"))
        defer { next.stop() }
        #expect(next.warmsDecoders)
    }

    /// Numbering, invalid names, duplicates, ignored folders; files are empty so every probe ends "unreadable".
    @Test func scanClassifiesNamesAndDuplicates() throws {
        let root = try tempDir("fanous-library")
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
        let index = LibraryIndex(root: root, cacheDirectory: root.appending(path: ".cache"), logger: testLogger)
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
    @Test(.offPool) func tenThousandFiles() throws {
        let root = try tempDir("fanous-library")
        for folder in 1...40 {
            let dir = root.appending(path: String(format: "%03d_Folder", folder))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in 1...250 {
                FileManager.default.createFile(atPath: dir.appending(path: String(format: "%03d_clip.mov", file)).path, contents: nil)
            }
        }
        let index = LibraryIndex(root: root, cacheDirectory: root.appending(path: ".cache"), logger: testLogger)
        let start = Date()
        index.rescan()
        let elapsed = Date().timeIntervalSince(start)
        let snapshot = index.snapshot
        #expect(snapshot.fileCount == 10_000)
        #expect(snapshot.invalidCount == 0)
        #expect(snapshot.folders.count == 40)
        #expect(elapsed < 5, Comment(rawValue: "scan took \(elapsed) s"))
    }

    /// A root missing at start behind a symlink is watched once it is made (B140): FSEvents never matched it before.
    @Test func aMissingRootBehindASymlinkIsWatchedOnceMade() async throws {
        let base = try tempDir("fanous-library-link")
        try FileManager.default.createDirectory(at: base.appending(path: "real"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: base.appending(path: "link"), withDestinationURL: base.appending(path: "real"))
        let root = base.appending(path: "link/Fanous Library")
        let index = LibraryIndex(root: root, cacheDirectory: base.appending(path: "cache"), logger: testLogger)
        index.start()
        defer { index.stop() }
        #expect(!index.snapshot.rootExists)
        try Self.touch(root.appending(path: "001_Show/001_a.mov"))
        #expect(await waitUntil(every: .milliseconds(50)) { index.snapshot.folders.first?.number == 1 })
        // a missing top-level folder: "//x" would get no events
        let topLevel = "/fanous-no-such-\(UUID().uuidString)/Fanous Library"
        #expect(LibraryIndex.watchPath(URL(fileURLWithPath: topLevel)) == topLevel)
    }

    /// A 2×2 PNG: enough for the still probe to call it playable.
    static func png(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writePNG(cgImage(rgba: [UInt8](repeating: 0, count: 16), width: 2, height: 2), to: url)
    }

    @Test func rootProblems() throws {
        let root = try tempDir("fanous-library")
        try Self.touch(root.appending(path: "file.txt"))
        #expect(LibraryIndex.rootProblem(root.path) == nil)
        #expect(LibraryIndex.rootProblem("Movies/Fanous Library")?.contains("absolute") == true)
        #expect(LibraryIndex.rootProblem(root.appending(path: "missing").path)?.contains("does not exist") == true)
        #expect(LibraryIndex.rootProblem(root.appending(path: "file.txt").path)?.contains("not a folder") == true)
    }

    @Test func ingestTargets() throws {
        let root = try tempDir("fanous-library")
        try Self.touch(root.appending(path: "003_Show/001_a.mov"))
        try Self.touch(root.appending(path: "003_Show/002_b.mov"))
        try Self.touch(root.appending(path: "003_Show/004_d.mov"))
        let index = LibraryIndex(root: root, cacheDirectory: root.appending(path: ".cache"), logger: testLogger)
        index.rescan()
        #expect(LibraryIndex.nextFileNumber(in: root.appending(path: "003_Show")) == 3)
        #expect(LibraryIndex.nextFileNumber(in: root.appending(path: "003_Show"), pending: ["003_c.mov"]) == 5)
        #expect(LibraryIndex.nextFileNumber(in: root.appending(path: "009_Missing")) == 1)
        #expect(index.folderURL(number: 3)?.lastPathComponent == "003_Show")
        #expect(index.folderURL(number: 9) == nil)
        #expect(index.folderURL(number: 9, createAs: "New: Folder")?.lastPathComponent == "009_New_ Folder")
        #expect(index.folderURL(number: 9, createAs: "Other")?.lastPathComponent == "009_New_ Folder", "on disk, not yet indexed")
        try Self.touch(root.appending(path: "005_A"))  // a file, not a folder
        for name in ["5_Dup", "005_Show"] { try FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: false) }
        #expect(index.folderURL(number: 5)?.lastPathComponent == "005_Show")
        index.rescan()
        #expect(index.snapshot.folders.first { $0.number == 5 }?.name == "005_Show", "the folder the index keeps for a duplicate number")
        #expect(index.createFolder(number: 9, name: "Third") == .exists(root.appending(path: "009_New_ Folder")))
        #expect(index.createFolder(number: 10, name: "Ten") == .created(root.appending(path: "010_Ten")))
        #expect(LibraryIndex.destinationName(number: 7, originalName: "12 intro loop.MOV", pathExtension: "mov") == "007_intro loop.mov")
        #expect(LibraryIndex.destinationName(number: 7, originalName: "../../evil.mp4", pathExtension: "mov") == "007_evil.mov")
        #expect(LibraryIndex.destinationName(number: 7, originalName: "123", pathExtension: "png") == "007_media.png")
    }

    /// B141: twenty clients creating one number at once make one folder; the others see it exist.
    @Test func concurrentFolderCreatesMakeOneFolder() async throws {
        let root = try tempDir("fanous-library")
        let index = LibraryIndex(root: root, cacheDirectory: root.appending(path: ".cache"), logger: testLogger)
        let results = await withTaskGroup(of: LibraryIndex.FolderCreate.self) { group in
            for i in 0..<20 { group.addTask { index.createFolder(number: 7, name: "Client \(i)") } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let created = results.compactMap { if case .created(let url) = $0 { url } else { nil } }
        #expect(created.count == 1, "\(results)")
        #expect(results.allSatisfy { $0 == .exists(created[0]) || $0 == .created(created[0]) }, "\(results)")  // any client may win the lock
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { LibraryIndex.prefixNumber($0) == 7 }.count == 1)
    }

    /// B142: a root that cannot be written gives no URL for a folder that does not exist.
    @Test func folderCreateFailsOnAReadOnlyRoot() throws {
        let root = try tempDir("fanous-library")
        let readOnly = root.appending(path: "root")
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnly.path) }
        let index = LibraryIndex(root: readOnly, cacheDirectory: root.appending(path: ".cache"), logger: testLogger)
        #expect(index.createFolder(number: 1, name: "One") == .failed)
        #expect(index.folderURL(number: 1, createAs: "One") == nil)
        #expect(!FileManager.default.fileExists(atPath: readOnly.appending(path: "001_One").path))
    }

    /// B161: the common video containers are listed (they were skipped without a word); text and subtitles stay out.
    @Test func otherVideoContainersAreListed() throws {
        let root = try tempDir("fanous-library")
        for name in ["001_a.webm", "002_b.mpg", "003_c.m2ts", "004_d.WMV", "005_e.flv", "006_f.3gp", "notes.txt", "007_g.srt"] {
            try Self.touch(root.appending(path: "001_Show/\(name)"))
        }
        let index = LibraryIndex(root: root, cacheDirectory: root.appending(path: ".cache"), logger: testLogger)
        index.rescan()
        let items = index.snapshot.folders[0].items
        #expect(items.map(\.name) == ["001_a.webm", "002_b.mpg", "003_c.m2ts", "004_d.WMV", "005_e.flv", "006_f.3gp"])
        #expect(items.allSatisfy { $0.kind == .movie && $0.status == .probing })
        #expect(items.map(\.file) == [1, 2, 3, 4, 5, 6])
    }

    /// B161: a newly listed container never takes a number from an entry listed before, also when its name sorts first;
    /// a sequence folder with a container's extension is no late file and keeps its number as before.
    @Test func newlyListedContainersKeepExistingNumbers() throws {
        let root = try tempDir("fanous-library")
        for name in ["001_0early.webm", "001_clip.mov", "002_gap.webm", "003_clip.mp4", "003_a.flv", "004_x.png"] {
            try Self.touch(root.appending(path: "001_Show/\(name)"))
        }
        try FileManager.default.createDirectory(at: root.appending(path: "001_Show/004_shots.mpg"), withIntermediateDirectories: true)
        let index = LibraryIndex(root: root, cacheDirectory: root.appending(path: ".cache"), logger: testLogger)
        index.rescan()
        let items = index.snapshot.folders[0].items
        let numbered = Dictionary(uniqueKeysWithValues: items.compactMap { item in item.file.map { ($0, item.name) } })
        #expect(numbered == [1: "001_clip.mov", 2: "002_gap.webm", 3: "003_clip.mp4", 4: "004_shots.mpg"])
        let duplicates = items.filter { $0.status == .invalid }.map(\.name).sorted()
        #expect(duplicates == ["001_0early.webm", "003_a.flv", "004_x.png"])
        #expect(items.filter { $0.status == .invalid }.allSatisfy { $0.reason?.contains("duplicate file number") == true })
    }

    /// B161: a numbered file of a newly listed container is a CITP/MSEX media element like an `.mkv` (any probe status),
    /// so the elements after it shift by one; the DMX range keeps the file number.
    @Test func newlyListedContainersAreMSEXElements() throws {
        let root = try tempDir("fanous-library")
        for name in ["001_a.mov", "002_b.mkv", "003_c.webm", "004_d.mov"] { try Self.touch(root.appending(path: "001_Show/\(name)")) }
        let index = LibraryIndex(root: root, cacheDirectory: root.appending(path: ".cache"), logger: testLogger)
        index.rescan()
        let elements = try #require(index.snapshot.msexLibraries.first?.elements)
        #expect(elements.map(\.name) == ["001_a.mov", "002_b.mkv", "003_c.webm", "004_d.mov"])
        #expect(elements.map(\.file) == [1, 2, 3, 4])
    }

    /// A probed library (one playable PNG, one empty `.mov` that cannot be opened) and its cache file; the cache holds the
    /// unreadable entry with `reason` and `version` as given (nil version = as a build from before B220 wrote it).
    private func probedLibrary(reason: String, version: Int?) async throws -> (root: URL, cache: URL, probed: String?) {
        let root = try tempDir("fanous-library")
        try Self.png(root.appending(path: "001_Show/001_still.png"))
        try Self.touch(root.appending(path: "001_Show/002_broken.mov"), bytes: 0)
        let cache = root.appending(path: ".cache")
        let first = LibraryIndex(root: root, cacheDirectory: cache, logger: testLogger)
        first.start()
        #expect(await waitUntil(every: .milliseconds(50)) { first.snapshot.folders.first?.items.allSatisfy { $0.status != .probing } == true })
        first.stop()
        let file = cache.appending(path: "library-index.json")
        var entries = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [String: Any]])
        let probed = first.snapshot.folders.first?.items.last?.reason  // what the first run wrote: the current text
        for (key, var entry) in entries where entry["reason"] != nil {
            entry["reason"] = reason
            entry["reasonsVersion"] = version
            entries[key] = entry
        }
        try JSONSerialization.data(withJSONObject: entries).write(to: file)
        return (root, cache, probed)
    }

    /// B220: a reason cached by an older build is stale, a playable entry is not.
    @Test func staleReasonsAreProbedAgainAndPlayableEntriesAreNot() async throws {
        let (root, cache, current) = try await probedLibrary(reason: "old text", version: nil)
        #expect(current != nil && current != "old text")
        let index = LibraryIndex(root: root, cacheDirectory: cache, logger: testLogger)
        final class Thumbnails: Sendable { let count = Atomic<Int>(0) }
        let thumbnails = Thumbnails()
        index.thumbnailer = { _, _, _ in thumbnails.count.wrappingAdd(1, ordering: .relaxed); return "thumb.jpg" }
        index.rescan()  // no probe thread: what is still .probing now is what a probe would run
        var items = try #require(index.snapshot.folders.first?.items)
        #expect(items.map(\.status) == [.playable, .probing], "the playable entry hits the cache, the stale unreadable one is a miss")
        index.start()
        defer { index.stop() }
        #expect(await waitUntil(every: .milliseconds(50)) { index.snapshot.folders.first?.items.allSatisfy { $0.status != .probing } == true })
        items = try #require(index.snapshot.folders.first?.items)
        #expect(items.map(\.status) == [.playable, .unreadable])
        #expect(items[1].reason == current, "the re-probe wrote the current text")
        #expect(thumbnails.count.load(ordering: .relaxed) == 0, "a cache hit is not thumbnailed again")
    }

    /// B220: written by this version, nothing is probed again.
    @Test func currentReasonsAreCacheHits() async throws {
        let (root, cache, _) = try await probedLibrary(reason: "current text", version: LibraryIndex.reasonsVersion)
        let index = LibraryIndex(root: root, cacheDirectory: cache, logger: testLogger)
        index.rescan()
        let items = try #require(index.snapshot.folders.first?.items)
        #expect(items.map(\.status) == [.playable, .unreadable])
        #expect(items[1].reason == "current text")
    }

    /// B220: the cache file of an older build, without the version field, still decodes.
    @Test func cacheEntriesWithoutAVersionDecode() throws {
        let old = #"{"k":{"status":"unreadable","reason":"Cannot Open"},"p":{"status":"playable"}}"#
        let cache = try JSONDecoder().decode([String: LibraryIndex.CacheEntry].self, from: Data(old.utf8))
        #expect(cache["k"]?.reason == "Cannot Open" && cache["k"]?.reasonsVersion == nil && cache["p"]?.status == .playable)
        let written = try JSONEncoder().encode(cache["k"])
        #expect(try JSONDecoder().decode(LibraryIndex.CacheEntry.self, from: written).reason == "Cannot Open")
    }

    // MARK: B328: cache writes

    /// `count` stills that do not decode (16 zero bytes): a fast probe each, unreadable, cached.
    private func brokenStills(_ count: Int) throws -> (root: URL, cache: URL) {
        let root = try tempDir("fanous-library")
        for n in 1...count { try Self.touch(root.appending(path: String(format: "%03d_Show/%03d_x.png", (n - 1) / 250 + 1, (n - 1) % 250 + 1))) }
        return (root, try tempDir("fanous-library-cache"))
    }

    private func probed(_ index: LibraryIndex) async -> Bool {
        await waitUntil(.seconds(30), every: .milliseconds(20)) { index.snapshot.folders.allSatisfy { $0.items.allSatisfy { $0.status != .probing } } }
    }

    /// 500 probes write the cache three times (at 200, at 400, at the drain), not 500 times; a wake with nothing new writes nothing.
    @Test func probesWriteTheCacheInBatches() async throws {
        let (root, cache) = try brokenStills(500)
        let index = LibraryIndex(root: root, cacheDirectory: cache, logger: testLogger)
        index.saveInterval = 3600  // the count rule alone; the 2 s rule depends on the machine's speed
        index.start()
        defer { index.stop() }
        #expect(await probed(index))
        #expect(await waitUntil(every: .milliseconds(20)) { index.cacheWrites.load(ordering: .relaxed) == 3 })
        print("B328 measure: 500 probes, \(index.cacheWrites.load(ordering: .relaxed)) writes, \(index.cacheBytes.load(ordering: .relaxed)) bytes")
        index.rescan()  // wakes the library thread: nothing to probe, nothing to write
        try await Task.sleep(for: .milliseconds(200))
        #expect(index.cacheWrites.load(ordering: .relaxed) == 3)
        let again = LibraryIndex(root: root, cacheDirectory: cache, logger: testLogger)
        again.rescan()
        #expect(again.snapshot.folders.allSatisfy { $0.items.allSatisfy { $0.status == .unreadable } }, "every probe reached the file")
    }

    /// A gone file's entry goes at the next drain, with its thumbnail; the other file's stay.
    @Test func aGoneFilesEntryAndThumbnailArePruned() async throws {
        let root = try tempDir("fanous-library")
        let gone = root.appending(path: "001_Show/001_gone.png"), kept = root.appending(path: "001_Show/002_kept.png")
        try Self.png(gone)
        try Self.png(kept)
        let index = LibraryIndex(root: root, cacheDirectory: try tempDir("fanous-library-cache"), logger: testLogger)
        index.saveInterval = 3600  // one write per drain, however slow the Mac
        let directory = index.thumbnailDirectory
        index.thumbnailer = { url, _, _ in
            let name = url.lastPathComponent + ".jpg"
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return (try? Data([1]).write(to: directory.appending(path: name))) != nil ? name : nil
        }
        index.start()
        defer { index.stop() }
        #expect(await probed(index))
        #expect(await waitUntil(every: .milliseconds(20)) { index.cacheWrites.load(ordering: .relaxed) == 1 })
        try FileManager.default.removeItem(at: gone)
        index.rescan()
        #expect(await waitUntil(every: .milliseconds(20)) { index.cacheWrites.load(ordering: .relaxed) == 2 })
        let written = try JSONDecoder().decode([String: LibraryIndex.CacheEntry].self, from: Data(contentsOf: index.cacheDirectory.appending(path: "library-index.json")))
        #expect(written.keys.map { String($0.prefix { $0 != "|" }) } == [kept.path])
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "001_gone.png.jpg").path))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "002_kept.png.jpg").path))
    }

    /// Show mode holds the write until it is off; a stop writes what waited, also in show mode.
    @Test func showModeHoldsTheCacheWriteAndAStopWritesIt() async throws {
        let (root, cache) = try brokenStills(3)
        let index = LibraryIndex(root: root, cacheDirectory: cache, logger: testLogger)
        index.paused = true
        index.start()
        defer { index.stop() }
        #expect(await probed(index))
        try await Task.sleep(for: .milliseconds(200))
        #expect(index.cacheWrites.load(ordering: .relaxed) == 0)
        index.paused = false
        #expect(await waitUntil(every: .milliseconds(20)) { index.cacheWrites.load(ordering: .relaxed) == 1 })

        let (root2, cache2) = try brokenStills(3)
        let stopped = LibraryIndex(root: root2, cacheDirectory: cache2, logger: testLogger)
        stopped.paused = true
        stopped.start()
        #expect(await probed(stopped))
        #expect(stopped.cacheWrites.load(ordering: .relaxed) == 0)
        try await offPool { stopped.stop() }
        #expect(stopped.cacheWrites.load(ordering: .relaxed) == 1)
    }

    /// The time rule: with no wait allowed, every probe writes (and the drain has nothing left to write).
    @Test func probesWriteTheCacheAfterTheInterval() async throws {
        let (root, cache) = try brokenStills(3)
        let index = LibraryIndex(root: root, cacheDirectory: cache, logger: testLogger)
        index.saveInterval = 0
        index.start()
        defer { index.stop() }
        #expect(await probed(index))
        #expect(await waitUntil(every: .milliseconds(20)) { index.cacheWrites.load(ordering: .relaxed) == 3 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(index.cacheWrites.load(ordering: .relaxed) == 3)
    }

    /// A scan whose listing failed (a folder that cannot be read: a volume grant reset, an I/O error) prunes nothing: the
    /// entries and thumbnails of the files it could not see stay.
    @Test func aFailedListingPrunesNothing() async throws {
        let root = try tempDir("fanous-library")
        let folder = root.appending(path: "001_Show")
        try Self.png(folder.appending(path: "001_a.png"))
        try Self.png(folder.appending(path: "002_b.png"))
        let index = LibraryIndex(root: root, cacheDirectory: try tempDir("fanous-library-cache"), logger: testLogger)
        index.saveInterval = 3600
        let directory = index.thumbnailDirectory
        index.thumbnailer = { url, _, _ in
            let name = url.lastPathComponent + ".jpg"
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return (try? Data([1]).write(to: directory.appending(path: name))) != nil ? name : nil
        }
        index.start()
        defer { index.stop() }
        #expect(await probed(index))
        #expect(await waitUntil(every: .milliseconds(20)) { index.cacheWrites.load(ordering: .relaxed) == 1 })
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        index.rescan()
        #expect(index.snapshot.fileCount == 0, "the folder cannot be listed")
        try await Task.sleep(for: .milliseconds(300))
        #expect(index.cacheWrites.load(ordering: .relaxed) == 1, "nothing pruned, nothing written")
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "001_a.png.jpg").path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        index.rescan()
        #expect(index.snapshot.folders.first?.items.map(\.status) == [.playable, .playable], "cache hits again")
    }

    /// A root that exists but lists no folder (a stale mountpoint, an empty automount) prunes nothing.
    @Test func anEmptyRootPrunesNothing() async throws {
        let (root, cache) = try brokenStills(2)
        let index = LibraryIndex(root: root, cacheDirectory: cache, logger: testLogger)
        index.saveInterval = 3600
        index.start()
        defer { index.stop() }
        #expect(await probed(index))
        #expect(await waitUntil(every: .milliseconds(20)) { index.cacheWrites.load(ordering: .relaxed) == 1 })
        try FileManager.default.moveItem(at: root.appending(path: "001_Show"), to: root.appending(path: "_away"))
        index.rescan()
        #expect(index.snapshot.folders.isEmpty)
        try await Task.sleep(for: .milliseconds(300))
        #expect(index.cacheWrites.load(ordering: .relaxed) == 1, "nothing pruned, nothing written")
    }

    /// The entries of a root inside this one (`/Show/Act2` under `/Show`, used before) are not this root's to prune.
    @Test func aNestedRootsEntriesAreNotPruned() async throws {
        let outer = try tempDir("fanous-library"), cache = try tempDir("fanous-library-cache")
        try Self.png(outer.appending(path: "Act2/001_A/001_a.png"))
        try Self.png(outer.appending(path: "001_Show/001_b.png"))
        let inner = LibraryIndex(root: outer.appending(path: "Act2"), cacheDirectory: cache, logger: testLogger)
        inner.start()
        #expect(await probed(inner))
        try await offPool { inner.stop() }
        let index = LibraryIndex(root: outer, cacheDirectory: cache, logger: testLogger)
        index.saveInterval = 3600
        index.start()
        defer { index.stop() }
        #expect(await probed(index))
        #expect(await waitUntil(every: .milliseconds(20)) { index.cacheWrites.load(ordering: .relaxed) == 1 })
        let written = try JSONDecoder().decode([String: LibraryIndex.CacheEntry].self, from: Data(contentsOf: cache.appending(path: "library-index.json")))
        #expect(written.keys.contains { $0.hasPrefix(outer.appending(path: "Act2/001_A/001_a.png").path + "|") }, "\(written.keys)")
    }

    /// B51: the replaced index writes what it holds before the replacement reads the cache, and nothing after.
    @Test func aReplacedIndexWritesBeforeTheReplacementReads() async throws {
        let (root, cache) = try brokenStills(2)
        let old = LibraryIndex(root: root, cacheDirectory: cache, logger: testLogger)
        old.paused = true  // holds its writes
        old.start()
        #expect(await probed(old))
        #expect(old.cacheWrites.load(ordering: .relaxed) == 0)
        let next = old.replacement(root: root)
        defer { next.stop() }
        #expect(old.cacheWrites.load(ordering: .relaxed) == 1)
        #expect(next.snapshot.folders.first?.items.map(\.status) == [.unreadable, .unreadable], "the replacement's scan hits the cache")
        // retired: a probe of the old index after the replacement writes nothing, nor does its stop
        old.paused = false
        try Self.touch(root.appending(path: "001_Show/003_x.png"))
        old.rescan()
        #expect(await probed(old))
        try await Task.sleep(for: .milliseconds(200))
        #expect(old.cacheWrites.load(ordering: .relaxed) == 1)
        try await offPool { old.stop() }
        #expect(old.cacheWrites.load(ordering: .relaxed) == 1)
    }

    /// B51: a swap refused after the replacement was made (`Engine.switchLibrary`'s re-check) keeps the old index, which
    /// writes its cache again.
    @Test func aKeptIndexWritesAgainAfterARefusedSwap() async throws {
        let (root, cache) = try brokenStills(2)
        let old = LibraryIndex(root: root, cacheDirectory: cache, logger: testLogger)
        old.saveInterval = 3600
        old.start()
        #expect(await probed(old))
        #expect(await waitUntil(every: .milliseconds(20)) { old.cacheWrites.load(ordering: .relaxed) == 1 })
        let next = old.replacement(root: try tempDir("fanous-library"))
        try await offPool { next.stop() }
        old.keep()
        try Self.touch(root.appending(path: "001_Show/003_x.png"))
        old.rescan()
        #expect(await probed(old))
        try await offPool { old.stop() }
        let written = try JSONDecoder().decode([String: LibraryIndex.CacheEntry].self, from: Data(contentsOf: cache.appending(path: "library-index.json")))
        #expect(written.keys.contains { $0.contains("003_x.png") }, "a probe after a refused swap reaches the cache file")
    }

    /// B51: a write of the old index in flight (entries taken, file not yet renamed) when the replacement is made: the
    /// replacement reads the cache after it lands, so its scan hits what the old index probed.
    @Test func aReplacementWaitsForAWriteInFlight() async throws {
        let (root, cache) = try brokenStills(2)
        let old = LibraryIndex(root: root, cacheDirectory: cache, logger: testLogger)
        old.saveInterval = 3600
        final class Gate: Sendable { let entered = DispatchSemaphore(value: 0) }
        let gate = Gate()
        old.beforeWrite = {
            gate.entered.signal()
            usleep(300_000)
        }
        old.start()
        #expect(try await offPool { gate.entered.wait(timeout: .now() + 10) == .success }, "the drain write")
        let next = try await offPool { old.replacement(root: root) }
        defer { next.stop() }
        #expect(next.snapshot.folders.first?.items.map(\.status) == [.unreadable, .unreadable], "the replacement read the cache before the write landed")
        try await offPool { old.stop() }
    }

    // MARK: B267: a file in work when the engine stopped

    /// Two stills; the cache key of the first, as a scan reads it.
    private func twoStills() throws -> (root: URL, cache: URL, first: URL, key: String) {
        let root = try tempDir("fanous-library")
        let first = root.appending(path: "001_Show/001_poison.png")
        try Self.png(first)
        try Self.png(root.appending(path: "001_Show/002_fine.png"))
        let cache = root.appending(path: ".cache")
        let scan = LibraryIndex(root: root, cacheDirectory: cache, logger: testLogger)
        scan.rescan()
        let item = try #require(scan.snapshot.folders.first?.items.first)
        return (root, cache, first, LibraryIndex.cacheKey(item))
    }

    /// What a previous run left when it stopped inside the probe of `path`.
    private func leaveMarker(_ cache: URL, path: URL, key: String, stops: Int) throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try JSONEncoder().encode(LibraryIndex.ProbeMarker(path: path.path, key: key, stops: stops)).write(to: cache.appending(path: "library-probing.json"))
    }

    /// Counts thumbnailer calls per file name, and reads the marker while the thumbnail is made (the probe is in work).
    private final class Thumbnails: Sendable {
        let made = Mutex<[String]>([])
        let markers = Mutex<[LibraryIndex.ProbeMarker?]>([])
    }

    private func started(_ root: URL, _ cache: URL, _ thumbnails: Thumbnails) async -> LibraryIndex {
        let index = LibraryIndex(root: root, cacheDirectory: cache, logger: testLogger)
        let marker = index.markerFile
        index.thumbnailer = { url, _, _ in
            thumbnails.made.withLock { $0.append(url.lastPathComponent) }
            thumbnails.markers.withLock { $0.append((try? Data(contentsOf: marker)).flatMap { try? JSONDecoder().decode(LibraryIndex.ProbeMarker.self, from: $0) }) }
            return "thumb.jpg"
        }
        index.start()
        // the marker goes just after the item is updated
        _ = await waitUntil(every: .milliseconds(20)) {
            index.snapshot.folders.first?.items.allSatisfy { $0.status != .probing } == true && !FileManager.default.fileExists(atPath: marker.path)
        }
        return index
    }

    /// The file is recorded while it is probed and thumbnailed, and the record is gone after.
    @Test func aProbeIsRecordedWhileItRuns() async throws {
        let (root, cache, first, key) = try twoStills()
        let thumbnails = Thumbnails()
        let index = await started(root, cache, thumbnails)
        defer { index.stop() }
        let markers = thumbnails.markers.withLock { $0 }
        #expect(markers.count == 2)
        #expect(markers.first??.path == first.path && markers.first??.key == key && markers.first??.stops == 0)
        #expect(!FileManager.default.fileExists(atPath: index.markerFile.path), "removed after the probe")
    }

    /// Stopped once: read once more (and fine this time, so nothing stays); stopped twice: unreadable, not read, the rest is.
    @Test func aFileTheEngineStoppedInTwiceIsUnreadableAndNotReadAgain() async throws {
        let (root, cache, first, key) = try twoStills()
        try leaveMarker(cache, path: first, key: key, stops: 0)
        var thumbnails = Thumbnails()
        var index = await started(root, cache, thumbnails)
        index.stop()
        #expect(thumbnails.made.withLock { $0 } == ["001_poison.png", "002_fine.png"], "stopped once: read again")
        #expect(thumbnails.markers.withLock { $0.first??.stops } == 1, "the second try is recorded as one")
        #expect(index.snapshot.folders.first?.items.map(\.status) == [.playable, .playable])

        try FileManager.default.removeItem(at: cache.appending(path: "library-index.json"))
        try leaveMarker(cache, path: first, key: key, stops: 1)
        thumbnails = Thumbnails()
        index = await started(root, cache, thumbnails)
        defer { index.stop() }
        #expect(thumbnails.made.withLock { $0 } == ["002_fine.png"], "the poison file is not read a third time")
        let items = try #require(index.snapshot.folders.first?.items)
        #expect(items.map(\.status) == [.unreadable, .playable])
        #expect(items[0].reason == LibraryIndex.stoppedTwice)
        #expect(!FileManager.default.fileExists(atPath: index.markerFile.path))
        #expect(FileManager.default.fileExists(atPath: first.path), "the file stays where it is")

        // a rescan (the Rescan button) keeps it unreadable; a new copy of the file is read again
        index.rescan()
        #expect(index.snapshot.folders.first?.items.first?.status == .unreadable)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: first.path)
        index.rescan()
        #expect(await waitUntil(every: .milliseconds(20)) { index.snapshot.folders.first?.items.first?.status == .playable })
    }

    /// An update that rewords the reasons does not send a file that stopped the engine twice through two more stops.
    @Test func aStoppedTwiceEntryOutlivesAReasonsVersionChange() throws {
        let (root, cache, _, key) = try twoStills()
        let old = LibraryIndex.CacheEntry(metadata: nil, thumbnail: nil, status: .unreadable, reason: LibraryIndex.stoppedTwice, reasonsVersion: LibraryIndex.reasonsVersion - 1)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try JSONEncoder().encode([key: old]).write(to: cache.appending(path: "library-index.json"))
        let index = LibraryIndex(root: root, cacheDirectory: cache, logger: testLogger)
        index.rescan()
        #expect(index.snapshot.folders.first?.items.map(\.status) == [.unreadable, .probing], "a hit, not probed again")
    }

    /// A second probe of the file in the same run (a rescan while it is read) starts from no stops: one later stop does not
    /// mark it.
    @Test func theStopCountIsUsedOnce() async throws {
        let (root, cache, first, key) = try twoStills()
        try leaveMarker(cache, path: first, key: key, stops: 0)
        let index = LibraryIndex(root: root, cacheDirectory: cache, logger: testLogger)
        #expect(FileManager.default.fileExists(atPath: index.markerFile.path), "kept until the probe overwrites it")
        final class Seen: Sendable { let stops = Mutex<[Int]>([]) }
        let seen = Seen()
        let marker = index.markerFile
        index.thumbnailer = { [weak index] url, _, _ in
            guard url == first, let data = try? Data(contentsOf: marker), let m = try? JSONDecoder().decode(LibraryIndex.ProbeMarker.self, from: data) else { return nil }
            let count = seen.stops.withLock { $0.append(m.stops); return $0.count }
            if count == 1 { index?.rescan() }  // its cache entry is not written yet: queued again
            return nil
        }
        index.start()
        defer { index.stop() }
        #expect(await waitUntil(every: .milliseconds(20)) { seen.stops.withLock { $0.count } == 2 })
        #expect(seen.stops.withLock { $0 } == [1, 0])
    }

    /// A stop of our own that cuts a slow probe off (the join gives up, 10 s in production, then the process exits) blames no one.
    @Test func aStopThatCutsAProbeOffRemovesTheMarker() async throws {
        let (root, cache, first, _) = try twoStills()
        let index = LibraryIndex(root: root, cacheDirectory: cache, logger: testLogger)
        index.joinTimeout = .milliseconds(100)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        index.thumbnailer = { url, _, _ in
            if url == first { release.wait() }
            return nil
        }
        index.start()
        #expect(await waitUntil(every: .milliseconds(20)) { FileManager.default.fileExists(atPath: index.markerFile.path) })
        try await offPool { index.stop() }  // gives up after 100 ms: the probe is held
        #expect(!FileManager.default.fileExists(atPath: index.markerFile.path))
    }

    /// A still the engine stopped in twice is not handed to a decoder as an image mask (decoded at every start, no
    /// console needed): `still` has none for it, like for a missing file; the other still is found.
    @Test func aStoppedTwiceStillIsNoMask() throws {
        let (root, cache, _, key) = try twoStills()
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let entry = LibraryIndex.CacheEntry(metadata: nil, thumbnail: nil, status: .unreadable, reason: LibraryIndex.stoppedTwice, reasonsVersion: LibraryIndex.reasonsVersion)
        try JSONEncoder().encode([key: entry]).write(to: cache.appending(path: "library-index.json"))
        let index = LibraryIndex(root: root, cacheDirectory: cache, logger: testLogger)
        index.rescan()
        #expect(index.still(MediaKey(folder: 1, file: 1)) == nil)
        #expect(index.still(MediaKey(folder: 1, file: 2)) != nil)
    }

    /// A replacement index (B51, made while the engine runs) does not read the live marker of the index it replaces as a
    /// stop: nothing stopped.
    @Test func aReplacementDoesNotReadTheMarkerAsAStop() async throws {
        let (root, cache, first, key) = try twoStills()
        try leaveMarker(cache, path: first, key: key, stops: 1)  // what the old index writes for a file in its second try
        let old = LibraryIndex(root: try tempDir("fanous-library"), cacheDirectory: cache, logger: testLogger, readsStopMarker: false)
        let next = old.replacement(root: root)
        defer { next.stop() }
        #expect(await waitUntil(every: .milliseconds(20)) { next.snapshot.folders.first?.items.allSatisfy { $0.status != .probing } == true })
        #expect(next.snapshot.folders.first?.items.map(\.status) == [.playable, .playable])
    }

    /// A marker under another root is from a run on another root.
    @Test func aMarkerUnderAnotherRootIsLeftAlone() async throws {
        let (root, cache, _, _) = try twoStills()
        let elsewhere = try tempDir("fanous-library").appending(path: "001_Show/001_poison.png")
        try leaveMarker(cache, path: elsewhere, key: "\(elsewhere.path)|0|0|v2", stops: 1)
        let index = LibraryIndex(root: root, cacheDirectory: cache, logger: testLogger)
        index.rescan()
        #expect(index.snapshot.folders.first?.items.map(\.status) == [.probing, .probing])
        #expect(FileManager.default.fileExists(atPath: index.markerFile.path))
    }

    /// A marker kept at a first stop whose file is not probed again (it changed or went) goes when the queue drains, so the
    /// next start does not warn about it again.
    @Test func aKeptMarkerGoesWhenNothingIsInWork() async throws {
        let (root, cache, first, key) = try twoStills()
        let probed = await started(root, cache, Thumbnails())  // both cached: the next start probes nothing
        probed.stop()
        try leaveMarker(cache, path: first, key: key + "-gone", stops: 0)
        let thumbnails = Thumbnails()
        let index = await started(root, cache, thumbnails)
        defer { index.stop() }
        #expect(thumbnails.made.withLock { $0 }.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: index.markerFile.path))
    }
}

/// The LibraryIndexTests that need the GPU or a decoder: local and self-hosted runs only (scripts/test.sh --hosted leaves them out).
@Suite(.cleansTempFiles)
struct LibraryIndexGPUTests {
    /// B161: a newly listed container AVFoundation opens needs transcode; one it has no reader for is unreadable and says so.
    /// B195: the needs-transcode reason names what is wrong, the container (ProRes in a `.3gp`, HAP in a `.qt`) or the codec (H.264).
    @Test func newlyListedContainersProbeToTranscodeOrUnreadable() async throws {
        let folder = try tempDir("fanous-library").appending(path: "001_Show")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await writePatternMovie(to: folder.appending(path: "001_phone.3gp"), size: (64, 64), fps: 25, frames: 2)
        try Data(repeating: 7, count: 4096).write(to: folder.appending(path: "002_web.webm"))
        try Data(repeating: 7, count: 4096).write(to: folder.appending(path: "003_broken.mp4"))
        try await IngestQueueTests.writeH264(to: folder.appending(path: "004_phone.mp4"))
        try await writePatternMovie(to: folder.appending(path: "005_hap.qt"), size: (64, 64), fps: 25, frames: 2, codec: .hap(.hap))
        let index = LibraryIndex(root: folder.deletingLastPathComponent(), cacheDirectory: folder.appending(path: "_cache"), logger: testLogger)
        index.start()
        defer { index.stop() }
        #expect(await waitUntil(every: .milliseconds(50)) { index.snapshot.folders.first?.items.allSatisfy { $0.status != .probing } == true })
        let items = try #require(index.snapshot.folders.first?.items)
        #expect(items.map(\.status) == [.needsTranscode, .unreadable, .unreadable, .needsTranscode, .needsTranscode])
        #expect(items[0].reason == "apch in .3gp: plays only in .mov, transcode re-encodes it", "B195: ProRes is fine, the container is not")
        #expect(items[1].reason == "AVFoundation cannot open .webm files")
        #expect(items[2].reason == "Cannot Open", "a damaged file in a container AVFoundation reads keeps AVFoundation's text")
        #expect(items[3].reason == "avc1 is not ProRes or HAP", "B195: the codec is what is wrong")
        #expect(items[4].reason == "Hap1 in .qt: plays only in .mov, remux it to a .mov on another machine", "macOS cannot decode HAP to transcode it")
        #expect(index.resolve(MediaKey(folder: 1, file: 1)) == nil && index.resolve(MediaKey(folder: 1, file: 2)) == nil)
    }

    /// B264: a movie header with timescale 0 reads as a NaN duration (measured: `asset.duration` 0/0, `.seconds` NaN, the
    /// track's `timeRange` too). The probe's frame count trapped on it at every start, since no cache entry was written;
    /// now the file is not playable and says why, and opening it for playback throws instead of trapping.
    @Test func aMovieWithoutADurationIsUnreadable() async throws {
        let folder = try tempDir("fanous-library").appending(path: "001_Show")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let movie = folder.appending(path: "001_no_duration.mov")
        try await writePatternMovie(to: movie, size: (64, 64), fps: 25, frames: 2)
        try patchAtom(movie, "mvhd", at: 20, to: 0)
        let index = LibraryIndex(root: folder.deletingLastPathComponent(), cacheDirectory: folder.appending(path: "_cache"), logger: testLogger)
        index.start()
        defer { index.stop() }
        #expect(await waitUntil(every: .milliseconds(50)) { index.snapshot.folders.first?.items.first.map { $0.status != .probing } == true })
        let item = try #require(index.snapshot.folders.first?.items.first)
        #expect(item.status == .unreadable && item.reason == "unknown duration")
        let device = try #require(MTLCreateSystemDefaultDevice())
        await #expect { _ = try await MovieSource.open(url: movie, device: device, poolSize: 2) } throws: { "\($0)" == "unknown duration" }
    }

    /// B264: an edit list of 2^32 − 1 s at movie timescale 1 is taken as the track's length (measured: `asset.duration`
    /// 4294967295/1, 25 fps, ~1.1e11 frames). Such a count traps playback's frame arithmetic, so the probe refuses any
    /// count beyond Int32 like a missing duration; before, it was listed playable.
    @Test func aMovieLongerThanPlaybackCanCountIsUnreadable() async throws {
        let folder = try tempDir("fanous-library").appending(path: "001_Show")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let movie = folder.appending(path: "001_endless.mov")
        try await writePatternMovie(to: movie, size: (64, 64), fps: 25, frames: 2)
        try patchAtom(movie, "mvhd", at: 20, to: 1)
        try patchAtom(movie, "mvhd", at: 24, to: .max)
        try patchAtom(movie, "tkhd", at: 28, to: .max)
        try patchAtom(movie, "elst", at: 16, to: .max)  // the one segment's duration, in the movie timescale
        let index = LibraryIndex(root: folder.deletingLastPathComponent(), cacheDirectory: folder.appending(path: "_cache"), logger: testLogger)
        index.start()
        defer { index.stop() }
        #expect(await waitUntil(every: .milliseconds(50)) { index.snapshot.folders.first?.items.first.map { $0.status != .probing } == true })
        let item = try #require(index.snapshot.folders.first?.items.first)
        #expect(item.status == .unreadable && item.reason == "unknown duration", "listed \(item.status), \(item.metadata?.frameCount ?? -1) frames")
        let device = try #require(MTLCreateSystemDefaultDevice())
        await #expect { _ = try await MovieSource.open(url: movie, device: device, poolSize: 2) } throws: { "\($0)" == "unknown duration" }
    }

    /// A playable movie resolves after probing, its thumbnail is requested, and FSEvents picks up a new file.
    @Test func probeResolvesAndWatcherRescans() async throws {
        let root = try tempDir("fanous-library")
        let folder = root.appending(path: "007_Test")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let movie = folder.appending(path: "003_clip.mov")
        try await writePatternMovie(to: movie, size: (320, 176), fps: 25, frames: 5)
        let index = LibraryIndex(root: root, cacheDirectory: root.appending(path: ".cache"), logger: testLogger)
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
            let again = LibraryIndex(root: root, cacheDirectory: root.appending(path: ".cache"), logger: testLogger)
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

    /// B51: a root change on a running engine. The old index stops watching and is freed, the new one indexes its root,
    /// layers re-resolve against it: a file not probed yet shows "missing" until its probe makes it playable, a file
    /// the root lacks stays "missing". Switching back needs no new probes.
    @Test func switchingRootsReindexesAndReresolvesLayers() async throws {
        let a = try tempDir("fanous-library"), b = try tempDir("fanous-library"), cache = try tempDir("fanous-library")
        try LibraryIndexTests.png(a.appending(path: "001_A/001_one.png"))
        try LibraryIndexTests.png(a.appending(path: "001_A/002_two.png"))
        try LibraryIndexTests.png(b.appending(path: "001_B/001_uno.png"))
        try LibraryIndexTests.png(b.appending(path: "001_B/002_dos.png"))
        final class Observer: Sendable {
            let changes = Atomic<Int>(0)
            let holdProbes = Atomic<Bool>(false)
        }
        let observer = Observer()
        // the engine's wiring: one box with the index of the moment (and no other strong reference), the loader
        // resolving through it, every library change asking the loader to retry its missing layers
        let current = Mutex<LibraryIndex?>(LibraryIndex(root: a, cacheDirectory: cache, logger: testLogger))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let layer = RenderLayer(index: 0)
        let loader = MediaLoader(layers: [layer], media: [], device: device, ringCapacity: 4, logger: testLogger)
        loader.resolver = { key in current.withLock { $0 }?.resolve(key) }
        current.withLock { first in
            first!.onChange = {
                observer.changes.wrappingAdd(1, ordering: .relaxed)
                loader.changed(.missingLibrary)
            }
            // a probe of a fresh file waits here while the test holds it: the window right after a switch
            first!.thumbnailer = { _, _, _ in
                while observer.holdProbes.load(ordering: .relaxed) { usleep(10_000) }
                return nil
            }
            first!.start()
        }
        #expect(await waitUntil { current.withLock { $0 }?.resolve(MediaKey(folder: 1, file: 2)) != nil })
        loader.start()
        defer { loader.stop() }
        layer.wanted.store(MediaKey(folder: 1, file: 2).packed, ordering: .relaxed)
        loader.wake.signal()
        #expect(await waitUntil { layer.mediaStatus.withLock { $0.name } == "002_two.png" })

        // as Engine.switchLibrary: build the new index, swap, re-resolve, stop the old one last
        observer.holdProbes.store(true, ordering: .relaxed)
        weak let old = current.withLock { $0 }
        let second = try #require(current.withLock { $0 }?.replacement(root: b))
        do {
            let replaced = current.withLock { box in
                defer { box = second }
                return box
            }
            loader.changed(.library)
            replaced?.stop()
        }
        #expect(second.snapshot.root == b.path && second.snapshot.folders.map(\.name) == ["001_B"])
        // B's files have never been probed: 1/2 does not resolve yet, so layer 1 shows "missing"
        #expect(second.resolve(MediaKey(folder: 1, file: 2)) == nil)
        #expect(await waitUntil { layer.mediaStatus.withLock { $0.kind == "missing" && $0.error == "no file 2 in folder 1" } })
        // the probe makes it playable; the change hook retries the missing layer
        observer.holdProbes.store(false, ordering: .relaxed)
        #expect(await waitUntil { layer.mediaStatus.withLock { $0.name } == "002_dos.png" }, "the missing layer was not retried")
        #expect(await waitUntil { second.resolve(MediaKey(folder: 1, file: 1))?.lastPathComponent == "001_uno.png" })
        // a number the root lacks: the existing "missing" state, no crash
        layer.wanted.store(MediaKey(folder: 1, file: 3).packed, ordering: .relaxed)
        loader.wake.signal()
        #expect(await waitUntil { layer.mediaStatus.withLock { $0.kind == "missing" && $0.error == "no file 3 in folder 1" } })

        // the old root is no longer watched and its index is gone
        #expect(await waitUntil { old == nil }, "the replaced index is still alive")
        let settled = observer.changes.load(ordering: .relaxed)
        try LibraryIndexTests.png(a.appending(path: "001_A/003_three.png"))
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
}
