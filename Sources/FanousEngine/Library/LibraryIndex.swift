// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import CoreServices
import Foundation
import FanousCore
import Logging
import Synchronization

/// One entry of the library (DESIGN.md §8.1): a numbered file, a sequence
/// directory, or something invalid that the Media screen shows in red.
public struct LibraryItem: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case movie, still, sequence, other }
    public enum Status: String, Codable, Sendable { case playable, needsTranscode, invalid, unreadable, probing }

    public var id: String { path }
    public var folder: Int
    public var file: Int?  // nil = invalid name
    public var name: String
    public var path: String
    public var kind: Kind
    public var status: Status
    public var reason: String?  // why invalid / unreadable
    public var metadata: MediaMetadata?
    public var thumbnail: String?  // file name in the cache's thumbnails directory
    public var modified: Double
    public var size: Int
}

public struct MediaMetadata: Codable, Sendable, Equatable {
    public var width = 0
    public var height = 0
    public var frameRate = 0.0
    public var duration = 0.0
    public var codec = ""  // four-character code or "png" etc.
    public var hasAlpha = false
    public var audioChannels = 0
    public var audioSampleRate = 0.0
    public var frameCount = 0
}

public struct LibraryFolder: Codable, Sendable, Equatable {
    public var number: Int?  // nil = invalid folder name
    public var name: String
    public var path: String
    public var items: [LibraryItem]
}

public struct LibrarySnapshot: Codable, Sendable, Equatable {
    public var root: String
    public var rootExists: Bool
    public var folders: [LibraryFolder]
    public var scannedAt: Double
    public var fileCount: Int
    public var invalidCount: Int

    /// For clients below operator (B25): no root, and paths relative to it (still unique, so UI keys keep working).
    public func redacted() -> LibrarySnapshot {
        func relative(_ path: String) -> String { path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : URL(fileURLWithPath: path).lastPathComponent }
        var copy = self
        copy.root = ""
        for f in copy.folders.indices {
            copy.folders[f].path = relative(copy.folders[f].path)
            for i in copy.folders[f].items.indices { copy.folders[f].items[i].path = relative(copy.folders[f].items[i].path) }
        }
        return copy
    }
}

/// Library index: numbered folders and files under one root, kept current
/// with FSEvents, metadata and thumbnails cached per path + mtime + size.
/// Resolution for the media loader is a dictionary lookup under a mutex.
public final class LibraryIndex: @unchecked Sendable {
    public static let movieExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "mxf"]
    static let playableCodecs: Set<String> = ["apch", "apcn", "apcs", "apco", "ap4h", "ap4x", "Hap1", "Hap5", "HapY", "HapM", "HapA", "HapR"]

    public let root: URL
    public let cacheDirectory: URL
    private let logger: Logger
    private let state = Mutex(State())
    private let probeWake = DispatchSemaphore(value: 0)
    private let probeExited = DispatchSemaphore(value: 0)
    private let running = Atomic<Bool>(false)
    private var probeThread: Thread?
    private var stream: FSEventStreamRef?
    private let eventQueue = DispatchQueue(label: "org.fanous.library.fsevents", qos: .utility)
    private var rescanPending = false
    public var onChange: (@Sendable () -> Void)?
    /// Makes thumbnails (needs the GPU decoders); installed by the engine. Returns the written file name.
    public var thumbnailer: (@Sendable (URL, MediaMetadata, LibraryItem.Kind) -> String?)?

    struct State {
        var snapshot = LibrarySnapshot(root: "", rootExists: false, folders: [], scannedAt: 0, fileCount: 0, invalidCount: 0)
        var byKey: [MediaKey: String] = [:]
        var cache: [String: CacheEntry] = [:]  // key = path|mtime|size
        var pendingProbes: [String] = []
    }

    struct CacheEntry: Codable { var metadata: MediaMetadata?; var thumbnail: String?; var status: LibraryItem.Status; var reason: String? }

    public init(root: URL, cacheDirectory: URL, logger: Logger) {
        self.root = root
        self.cacheDirectory = cacheDirectory
        self.logger = logger
        state.withLock { $0.snapshot.root = root.path }
        loadCache()
    }

    // MARK: Public

    public var snapshot: LibrarySnapshot { state.withLock { $0.snapshot } }

    /// Path for a DMX folder/file pair; nil = not present or not playable (DESIGN.md §7.4).
    public func resolve(_ key: MediaKey) -> URL? { state.withLock { $0.byKey[key] }.map { URL(fileURLWithPath: $0) } }

    public func start() {
        running.store(true, ordering: .relaxed)
        let thread = Thread { [self] in probeLoop() }
        thread.name = "org.fanous.library"
        thread.qualityOfService = .utility
        thread.start()
        probeThread = thread
        rescan()
        watch()
    }

    /// Stops the watcher and joins the probe thread (a probe in flight finishes first), so nothing runs afterwards.
    public func stop() {
        guard running.exchange(false, ordering: .relaxed) else { return }
        probeWake.signal()
        _ = probeExited.wait(timeout: .now() + .seconds(10))
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    /// Full rescan of the root (fast: directory listings only; probes run on the library thread afterwards).
    public func rescan() {
        let fm = FileManager.default
        var folders: [LibraryFolder] = []
        var byKey: [MediaKey: String] = [:]
        var fileCount = 0, invalidCount = 0
        var probes: [String] = []
        let rootExists = fm.fileExists(atPath: root.path)
        // plain code-point order decides who wins a duplicate number ("012_Show" before "12_Dup"): deterministic on every machine
        let folderNames = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") && !$0.hasPrefix("_") }.sorted()
        var seenFolders: Set<Int> = []
        let cache = state.withLock { $0.cache }
        for folderName in folderNames {
            let folderURL = root.appending(path: folderName)
            guard (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            var number = Self.prefixNumber(folderName)
            var folderReason: String?
            if let n = number, !seenFolders.insert(n).inserted {
                folderReason = "duplicate folder number \(n)"
                number = nil
            } else if number == nil {
                folderReason = "no 1–255 prefix"
            }
            var items: [LibraryItem] = []
            var seenFiles: Set<Int> = []
            let names = ((try? fm.contentsOfDirectory(atPath: folderURL.path)) ?? []).filter { !$0.hasPrefix(".") && !$0.hasPrefix("_") }.sorted()
            for name in names {
                let url = folderURL.appending(path: name)
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]) else { continue }
                let isDirectory = values.isDirectory == true
                let ext = url.pathExtension.lowercased()
                let kind: LibraryItem.Kind =
                    isDirectory ? .sequence : StillSource.extensions.contains(ext) ? .still : Self.movieExtensions.contains(ext) ? .movie : .other
                if kind == .other && !isDirectory { continue }  // sidecars, text files: not media
                let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                let size = values.fileSize ?? 0
                var item = LibraryItem(
                    folder: number ?? 0, file: Self.prefixNumber(name), name: name, path: url.path, kind: kind, status: .probing, reason: nil,
                    metadata: nil, thumbnail: nil, modified: modified, size: size)
                fileCount += 1
                if let reason = folderReason {
                    item.status = .invalid
                    item.reason = "folder: \(reason)"
                } else if item.file == nil {
                    item.status = .invalid
                    item.reason = "no 1–255 prefix"
                } else if !seenFiles.insert(item.file!).inserted {
                    item.status = .invalid
                    item.reason = "duplicate file number \(item.file!)"
                    item.file = nil
                }
                if item.status == .invalid {
                    invalidCount += 1
                } else if let cached = cache[Self.cacheKey(item)] {
                    item.metadata = cached.metadata
                    item.thumbnail = cached.thumbnail
                    item.status = cached.status
                    item.reason = cached.reason
                } else {
                    probes.append(url.path)
                }
                if item.status == .playable, let n = number, let f = item.file { byKey[MediaKey(folder: n, file: f)] = url.path }
                items.append(item)
            }
            items.sort { ($0.file ?? 999, $0.name) < ($1.file ?? 999, $1.name) }
            folders.append(LibraryFolder(number: number, name: folderName, path: folderURL.path, items: items))
        }
        folders.sort { ($0.number ?? 999, $0.name) < ($1.number ?? 999, $1.name) }
        let snapshot = LibrarySnapshot(root: root.path, rootExists: rootExists, folders: folders, scannedAt: Date().timeIntervalSince1970, fileCount: fileCount, invalidCount: invalidCount)
        state.withLock { s in
            s.snapshot = snapshot
            s.byKey = byKey
            s.pendingProbes = probes
        }
        logger.info("library scanned", metadata: ["root": "\(root.path)", "folders": "\(folders.count)", "files": "\(fileCount)", "invalid": "\(invalidCount)", "toProbe": "\(probes.count)"])
        onChange?()
        if !probes.isEmpty { probeWake.signal() }
    }

    /// Leading 1–3 digits (1–255) followed by a non-digit or the end: "012_Show" → 12.
    public static func prefixNumber(_ name: String) -> Int? {
        let digits = name.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3, let n = Int(digits), (1...255).contains(n) else { return nil }
        return n
    }

    // MARK: Probing (library thread)

    static func cacheKey(_ item: LibraryItem) -> String { "\(item.path)|\(Int(item.modified))|\(item.size)" }

    private func probeLoop() {
        while running.load(ordering: .relaxed) {
            guard let path = state.withLock({ $0.pendingProbes.isEmpty ? nil : $0.pendingProbes.removeFirst() }) else {
                probeWake.wait()
                continue
            }
            autoreleasepool { probe(URL(fileURLWithPath: path)) }
        }
        probeExited.signal()
    }

    private func probe(_ url: URL) {
        guard let item = state.withLock({ s in s.snapshot.folders.lazy.flatMap(\.items).first { $0.path == url.path } }) else { return }
        var entry = CacheEntry(metadata: nil, thumbnail: nil, status: .unreadable, reason: nil)
        switch item.kind {
        case .still:
            if let metadata = Self.probeStill(url) {
                entry.metadata = metadata
                entry.status = .playable
            } else {
                entry.reason = "cannot read image"
            }
        case .movie:
            do {
                let metadata = try Self.probeMovie(url)
                entry.metadata = metadata
                entry.status = url.pathExtension.lowercased() == "mov" && Self.playableCodecs.contains(metadata.codec) ? .playable : .needsTranscode
                if entry.status == .needsTranscode { entry.reason = "\(metadata.codec) is not ProRes/HAP in .mov" }
            } catch {
                entry.reason = "\(error)"
            }
        case .sequence:
            let frames = (try? SequenceIngest.frames(in: url)) ?? []
            if frames.count >= 2, let first = Self.probeStill(frames[0]) {
                var metadata = first
                metadata.frameCount = frames.count
                entry.metadata = metadata
                entry.status = .needsTranscode
                entry.reason = "image sequence: ingest to a movie"
            } else {
                entry.reason = "not an image sequence"
            }
        case .other:
            entry.reason = "unknown type"
        }
        if entry.status == .playable || entry.status == .needsTranscode, let metadata = entry.metadata, let thumbnailer {
            entry.thumbnail = thumbnailer(item.kind == .sequence ? ((try? SequenceIngest.frames(in: url))?[0] ?? url) : url, metadata, item.kind)
        }
        apply(entry, to: item)
    }

    private func apply(_ entry: CacheEntry, to item: LibraryItem) {
        state.withLock { s in
            s.cache[Self.cacheKey(item)] = entry
            for f in s.snapshot.folders.indices {
                for i in s.snapshot.folders[f].items.indices where s.snapshot.folders[f].items[i].path == item.path {
                    var updated = s.snapshot.folders[f].items[i]
                    updated.metadata = entry.metadata
                    updated.thumbnail = entry.thumbnail
                    updated.status = entry.status
                    updated.reason = entry.reason
                    s.snapshot.folders[f].items[i] = updated
                    if entry.status == .playable, let n = s.snapshot.folders[f].number, let file = updated.file {
                        s.byKey[MediaKey(folder: n, file: file)] = updated.path
                    }
                }
            }
        }
        saveCache()
        onChange?()
    }

    static func probeStill(_ url: URL) -> MediaMetadata? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        var metadata = MediaMetadata()
        metadata.width = width
        metadata.height = height
        metadata.codec = url.pathExtension.lowercased()
        metadata.hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        metadata.frameCount = 1
        return metadata
    }

    /// AVAsset probe; the library thread is not a cooperative thread, so blocking on the async loads is fine.
    static func probeMovie(_ url: URL) throws -> MediaMetadata {
        let done = DispatchSemaphore(value: 0)
        let box = Mutex<Result<MediaMetadata, Error>?>(nil)
        Task.detached(priority: .utility) {
            do {
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration).seconds
                var metadata = MediaMetadata()
                metadata.duration = duration
                if let video = try await asset.loadTracks(withMediaType: .video).first {
                    let (descriptions, frameRate, size) = try await video.load(.formatDescriptions, .nominalFrameRate, .naturalSize)
                    metadata.width = Int(size.width)
                    metadata.height = Int(size.height)
                    metadata.frameRate = Double(frameRate)
                    metadata.frameCount = Int((duration * Double(frameRate)).rounded())
                    if let description = descriptions.first {
                        let codec = CMFormatDescriptionGetMediaSubType(description)
                        metadata.codec = fourCCString(codec)
                        metadata.hasAlpha = ["ap4h", "ap4x", "Hap5", "HapM", "HapA"].contains(metadata.codec)
                    }
                } else {
                    throw MovieError.noVideoTrack
                }
                if let audio = try await asset.loadTracks(withMediaType: .audio).first,
                    let description = try await audio.load(.formatDescriptions).first,
                    let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
                {
                    metadata.audioChannels = Int(basic.mChannelsPerFrame)
                    metadata.audioSampleRate = basic.mSampleRate
                }
                box.withLock { $0 = .success(metadata) }
            } catch {
                box.withLock { $0 = .failure(error) }
            }
            done.signal()
        }
        done.wait()
        return try box.withLock { $0 }!.get()
    }

    // MARK: Cache

    private var cacheFile: URL { cacheDirectory.appending(path: "library-index.json") }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheFile), let cache = try? JSONDecoder().decode([String: CacheEntry].self, from: data) else { return }
        state.withLock { $0.cache = cache }
    }

    private func saveCache() {
        let cache = state.withLock { $0.cache }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheFile, options: .atomic) }
    }

    // MARK: FSEvents

    private func watch() {
        // the stream retains the index until it is released in stop(), so a late callback never sees a freed object
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<LibraryIndex>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<LibraryIndex>.fromOpaque(info).release()
            }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<LibraryIndex>.fromOpaque(info).takeUnretainedValue().scheduleRescan()
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents))
        else {
            logger.warning("FSEvents unavailable for \(root.path); the library only rescans on request")
            return
        }
        FSEventStreamSetDispatchQueue(stream, eventQueue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// Debounced: one rescan 500 ms after the last event (DESIGN.md §8.1).
    private func scheduleRescan() {
        eventQueue.async { [self] in
            guard !rescanPending else { return }
            rescanPending = true
            eventQueue.asyncAfter(deadline: .now() + 0.5) { [self] in
                rescanPending = false
                rescan()
            }
        }
    }
}

// MARK: - Ingest targets

extension LibraryIndex {
    /// Uploads land here before ingest (DESIGN.md §8.1); never indexed.
    public var incomingDirectory: URL { root.appending(path: "_incoming") }

    /// The folder with this number, or a new `NNN_<name>` folder when `createAs` is given.
    public func folderURL(number: Int, createAs name: String? = nil) -> URL? {
        if let existing = snapshot.folders.first(where: { $0.number == number }) { return URL(fileURLWithPath: existing.path) }
        guard let name, (1...255).contains(number) else { return nil }
        let url = root.appending(path: String(format: "%03d_%@", number, Self.safeName(name)))
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Smallest unused file number in a folder (1–255); nil when the folder is full or unknown.
    public func nextFileNumber(inFolder number: Int) -> Int? {
        guard let folder = snapshot.folders.first(where: { $0.number == number }) else { return 1 }
        let used = Set(folder.items.compactMap(\.file) + folder.items.compactMap { Self.prefixNumber($0.name) })
        return (1...255).first { !used.contains($0) }
    }

    /// `NNN_<base>.<ext>` with the base cleaned of path separators and leading digits (so the number stays unambiguous).
    public static func destinationName(number: Int, originalName: String, pathExtension: String) -> String {
        var base = URL(fileURLWithPath: originalName).deletingPathExtension().lastPathComponent
        base = String(base.drop { $0.isNumber }).trimmingCharacters(in: CharacterSet(charactersIn: " _-"))
        if base.isEmpty { base = "media" }
        return String(format: "%03d_%@.%@", number, safeName(base), pathExtension)
    }

    static func safeName(_ name: String) -> String {
        String(name.map { $0 == "/" || $0 == ":" || $0 == "\0" ? "_" : $0 }).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
