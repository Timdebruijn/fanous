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
    /// The track carries a rotation/flip (`preferredTransform`); the decoder ignores it, so ingest must bake it in.
    public var rotated: Bool?
    /// Non-square pixels (B146): `width` is the shown width (`naturalSize` has the ratio in), the file holds `width / pixelAspect` columns. nil = 1.
    public var pixelAspect: Double?
}

extension CGAffineTransform {
    /// Anything but identity and pure translation.
    var rotatesOrFlips: Bool { !(a == 1 && b == 0 && c == 0 && d == 1) }
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

    /// A ProRes movie the engine can play is in the library (B389: the decoder warm-up is for those).
    var holdsProRes: Bool {
        folders.contains { $0.items.contains { $0.status == .playable && MovieSource.proResCodecs.contains(makeFourCC($0.metadata?.codec ?? "")) } }
    }

    public static let empty = LibrarySnapshot(root: "", rootExists: false, folders: [], scannedAt: 0, fileCount: 0, invalidCount: 0)

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

    /// Common video containers listed since B161, so none is skipped without a word; the probe then says needs transcode
    /// or unreadable. Fixed, not the system's type list: that one grows with installed apps (VLC adds `.vob`), and a listed
    /// numbered file is a CITP/MSEX element, so every Mac must list the same files. A TypeScript `.ts` shows as unreadable.
    static let lateMovieExtensions: Set<String> = [
        "webm", "mpg", "mpeg", "m2ts", "mts", "ts", "wmv", "flv", "3gp", "3g2", "ogv", "vob", "dv", "qt", "m2v", "f4v", "asf", "divx",
    ]
    /// The containers AVFoundation reads: a "Cannot Open" in one of these is a damaged file, not the container.
    static let avFoundationContainers: Set<String> = ["mov", "mp4", "m4v"]
    /// Why `url` did not open, as a client may see it: "Cannot Open" for a container AVFoundation has no reader for told
    /// nothing (B161); the library and a failed ingest job say the same (B194). `/api/library` and `live.ingest` reach
    /// monitors: no file path (B25). The library caches this text: reword it and bump `reasonsVersion` (B220).
    static func openFailureText(_ error: Error, _ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if let error = error as? AVError, error.code == .fileFormatNotRecognized, !ext.isEmpty, !avFoundationContainers.contains(ext) {
            return "AVFoundation cannot open .\(ext) files"
        }
        return error.clientText
    }
    /// The codecs `MovieSource` plays, as the fourCC strings of `Metadata.codec`.
    static let playableCodecs = Set(MovieSource.proResCodecs.union(MovieSource.hapCodecs.keys).map(fourCCString))

    public let root: URL
    public let cacheDirectory: URL
    private let logger: Logger
    private let state = Mutex(State())
    private let probeWake = DispatchSemaphore(value: 0)
    private let probeExited = DispatchSemaphore(value: 0)
    private let running = Atomic<Bool>(false)
    private var probeThread: Thread?
    /// B389: a scan or a probe that shows a ProRes movie that plays starts the decoder warm-up (once per process). The
    /// engine sets it; a test's index leaves the decoder alone. A `replacement(root:)` takes it over.
    public var warmsDecoders: Bool {
        get { warms.load(ordering: .relaxed) }
        set { warms.store(newValue, ordering: .relaxed) }
    }
    private let warms = Atomic<Bool>(false)  // set on the engine's thread, read on the scan and probe threads
    /// How long `stop()` waits for a probe in flight; shortened by a test only.
    var joinTimeout: DispatchTimeInterval = .seconds(10)
    private var stream: FSEventStreamRef?
    private let eventQueue = DispatchQueue(label: "org.fanous.library.fsevents", qos: .utility)
    private var rescanPending = false
    public var onChange: (@Sendable () -> Void)?
    /// Makes thumbnails (needs the GPU decoders); installed by the engine. Returns the written file name.
    public var thumbnailer: (@Sendable (URL, MediaMetadata, LibraryItem.Kind) -> String?)?

    struct State {
        var snapshot = LibrarySnapshot.empty
        var byKey: [MediaKey: String] = [:]
        var cache: [String: CacheEntry] = [:]  // key = path|mtime|size
        var pendingProbes: [String] = []
        /// B267: the cache key that was in work when the engine stopped before this start, and how often that happened.
        var stoppedIn: (key: String, stops: Int)?
    }

    /// B220: the wording of the probe's reason texts. A cached entry that carries a reason is probed again once when the
    /// version it was written with is not this one (a cache from before this field has none); entries without a reason
    /// are not stale and keep their hit and thumbnail. BUMP THIS whenever a reason text changes. The texts are made in
    /// `probe` (still, movie, sequence and unknown-type reasons) and in `openFailureText` (the movie open failure, also
    /// used by the ingest queue), and in `loadCache` (`stoppedTwice`). An entry with `stoppedTwice` is never stale (B267): a
    /// re-probe after an update would cost two more stops of the engine per such file; it goes when the file changes.
    /// Rewording `stoppedTwice` itself makes the old entries stale, with that cost.
    static let reasonsVersion = 1
    static let stoppedTwice = "the engine stopped twice while reading it: replace or re-save the file to try again"

    struct CacheEntry: Codable {
        var metadata: MediaMetadata?; var thumbnail: String?; var status: LibraryItem.Status; var reason: String?
        var reasonsVersion: Int?  // nil = no reason, or written before B220
    }

    /// B267: the file in work on the library thread, written before its probe and thumbnail and removed after, so the next
    /// start knows which file was in work when the engine stopped. `stops`: how often that happened before this probe.
    struct ProbeMarker: Codable { var path: String; var key: String; var stops: Int }

    /// `readsStopMarker`: only the index made at engine start reads a probe marker as a stop of the engine (B267); a
    /// replacement made while the engine runs (B51) would read the live marker of the index it replaces.
    public init(root: URL, cacheDirectory: URL, logger: Logger, readsStopMarker: Bool = true) {
        self.root = root
        self.cacheDirectory = cacheDirectory
        self.logger = logger
        state.withLock { $0.snapshot.root = root.path }
        loadCache(readsStopMarker: readsStopMarker)
    }

    // MARK: Public

    public var snapshot: LibrarySnapshot { state.withLock { $0.snapshot } }

    /// Path for a DMX folder/file pair; nil = not present or not playable (DESIGN.md §7.4).
    public func resolve(_ key: MediaKey) -> URL? { state.withLock { $0.byKey[key] }.map { URL(fileURLWithPath: $0) } }

    /// The valid item numbered `key` in the last scan, whatever its probe says.
    public func item(_ key: MediaKey) -> LibraryItem? {
        snapshot.folders.first { $0.number == key.folder }?.items.first { $0.file == key.file && $0.status != .invalid }
    }

    /// The still numbered `key` for an image mask (DESIGN.md §9.10 item 5), also while it is probed again after a save,
    /// when `resolve` has none (the mask reads the file itself, and its stamp sees the change); nil when there is none or
    /// it is not a still, or the engine stopped twice while reading it (B267: a mask is decoded at every start).
    public func still(_ key: MediaKey) -> URL? {
        item(key).flatMap { $0.kind == .still && $0.reason != Self.stoppedTwice ? URL(fileURLWithPath: $0.path) : nil }
    }

    public func start() {
        running.store(true, ordering: .relaxed)
        rescan()  // before the thread: its first pass must see the queue, or it takes it as drained and drops a kept marker (B267)
        let thread = Thread { [self] in probeLoop() }
        thread.name = "org.fanous.library"
        thread.qualityOfService = .utility
        thread.start()
        probeThread = thread
        watch()
    }

    /// Stops the watcher and joins the probe thread (a probe in flight finishes first), so nothing runs afterwards.
    public func stop() {
        guard running.exchange(false, ordering: .relaxed) else { return }
        probeWake.signal()
        // B267: a probe still running after the wait is cut off by a stop of our own (exit follows), not a crash: no blame
        if probeExited.wait(timeout: .now() + joinTimeout) == .timedOut { try? FileManager.default.removeItem(at: markerFile) }
        probeThread = nil  // its block holds the index: a replaced index (B51) must be freed
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    /// After a scan or a probe pass, on the thread that made it.
    private func changed() {
        if warmsDecoders, !DecoderWarmUp.hasStarted, snapshot.holdsProRes { DecoderWarmUp.startOnce(logger: logger) }
        onChange?()
    }

    /// B51: an index on another root with this one's cache, thumbnailer and change hook, started (scanned). This one
    /// keeps running until the caller has swapped them and calls `stop()` (FSEvents released, probe thread joined).
    /// The cache is keyed by absolute path and shared, so switching back to a root probed before needs no new probes.
    public func replacement(root: URL) -> LibraryIndex {
        let next = LibraryIndex(root: root, cacheDirectory: cacheDirectory, logger: logger, readsStopMarker: false)
        next.thumbnailer = thumbnailer
        next.onChange = onChange
        next.warmsDecoders = warmsDecoders
        next.start()
        return next
    }

    /// Why `path` cannot be the library root (B51); nil when it is an existing, readable folder.
    public static func rootProblem(_ path: String) -> String? {
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/") else { return "the library root must be an absolute path" }
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return "\(path) does not exist" }
        guard isDirectory.boolValue else { return "\(path) is not a folder" }
        guard (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil else { return "\(path) cannot be read" }
        return nil
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
            // a late movie (B161, a regular file) claims its number after everything else: one that shares a number with an
            // entry listed before B161 is the duplicate, so a show's folder/file numbers stay what they were
            let entries = ((try? fm.contentsOfDirectory(atPath: folderURL.path)) ?? []).filter { !$0.hasPrefix(".") && !$0.hasPrefix("_") }
                .compactMap { name -> (name: String, values: URLResourceValues, late: Bool)? in
                    let url = folderURL.appending(path: name)
                    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]) else { return nil }
                    return (name, values, values.isDirectory != true && Self.lateMovieExtensions.contains(url.pathExtension.lowercased()))
                }
                .sorted { ($0.late ? 1 : 0, $0.name) < ($1.late ? 1 : 0, $1.name) }
            for (name, values, late) in entries {
                let url = folderURL.appending(path: name)
                let isDirectory = values.isDirectory == true
                let ext = url.pathExtension.lowercased()
                let kind: LibraryItem.Kind =
                    isDirectory ? .sequence : StillSource.extensions.contains(ext) ? .still
                    : Self.movieExtensions.contains(ext) || late ? .movie : .other
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
                } else if let cached = cache[Self.cacheKey(item)], cached.reason == nil || cached.reasonsVersion == Self.reasonsVersion || cached.reason == Self.stoppedTwice {
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
        changed()
        if !probes.isEmpty { probeWake.signal() }
    }

    /// Leading 1–3 digits (1–255) followed by a non-digit or the end: "012_Show" → 12.
    public static func prefixNumber(_ name: String) -> Int? {
        let digits = name.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3, let n = Int(digits), (1...255).contains(n) else { return nil }
        return n
    }

    // MARK: Probing (library thread)

    /// The trailing version re-probes every file once when the metadata gains a field (v2: `pixelAspect`, B146). Bumping it
    /// also re-probes the files marked `stoppedTwice` (B267): each can stop the engine twice more before it is marked again.
    static func cacheKey(_ item: LibraryItem) -> String { "\(item.path)|\(Int(item.modified))|\(item.size)|v2" }

    private func probeLoop() {
        while running.load(ordering: .relaxed) {
            guard let path = state.withLock({ $0.pendingProbes.isEmpty ? nil : $0.pendingProbes.removeFirst() }) else {
                // B267: nothing in work, so a marker kept from the last stop (its file changed or went) blames no one
                try? FileManager.default.removeItem(at: markerFile)
                probeWake.wait()
                continue
            }
            autoreleasepool { probe(URL(fileURLWithPath: path)) }
        }
        probeExited.signal()
    }

    private func probe(_ url: URL) {
        guard let item = state.withLock({ s in s.snapshot.folders.lazy.flatMap(\.items).first { $0.path == url.path } }) else { return }
        let key = Self.cacheKey(item)
        let stops = state.withLock { s -> Int in
            guard let stoppedIn = s.stoppedIn, stoppedIn.key == key else { return 0 }
            s.stoppedIn = nil  // read once: a second probe of the file (a rescan meanwhile) starts from 0 again
            return stoppedIn.stops
        }
        // ponytail: one small file written and removed per probe, beside the full cache rewrite of B328; not atomic, a torn
        // marker reads as none (the file is then not blamed). One marker per cache directory: while the root is replaced
        // (B51) two indexes probe on two threads, the marker names whichever file was written last and either removes it, so a
        // stop in that window can count against the other index's file (once: the second count needs another stop in it).
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(ProbeMarker(path: item.path, key: key, stops: stops)).write(to: markerFile)
        defer { try? FileManager.default.removeItem(at: markerFile) }
        var entry = CacheEntry(metadata: nil, thumbnail: nil, status: .unreadable, reason: nil)
        // B220: every reason text below (and `openFailureText`) is cached; bump `reasonsVersion` when one is reworded
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
                entry.status = url.pathExtension.lowercased() == "mov" && Self.playableCodecs.contains(metadata.codec) && metadata.rotated != true ? .playable : .needsTranscode
                if entry.status == .needsTranscode {
                    // B195: say which it is, the rotation, the codec or the container
                    entry.reason = metadata.rotated == true ? "rotated or flipped (phone footage): transcode to make it upright"
                        : !Self.playableCodecs.contains(metadata.codec) ? "\(metadata.codec) is not ProRes or HAP"
                        : "\(metadata.codec) in .\(url.pathExtension.lowercased()): plays only in .mov, "
                            + (MovieSource.proResCodecs.contains(makeFourCC(metadata.codec)) ? "transcode re-encodes it" : "remux it to a .mov on another machine")
                }
            } catch {
                entry.reason = Self.openFailureText(error, url)
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
        if entry.reason != nil { entry.reasonsVersion = Self.reasonsVersion }
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
        // a probe that outlived stop() (the join timed out): the cache file and the hook belong to the next index (B51)
        guard running.load(ordering: .relaxed) else { return }
        saveCache()
        changed()
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
        try blockingAwait {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            var metadata = MediaMetadata()
            metadata.duration = duration
            if let video = try await asset.loadTracks(withMediaType: .video).first {
                let (descriptions, frameRate, size, transform) = try await video.load(.formatDescriptions, .nominalFrameRate, .naturalSize, .preferredTransform)
                let upright = CGRect(origin: .zero, size: size).applying(transform).size  // rotated phone footage: report the displayed size
                metadata.rotated = transform.rotatesOrFlips
                metadata.width = Int(upright.width.rounded())
                metadata.height = Int(upright.height.rounded())
                metadata.frameRate = Double(frameRate)
                // B264: a header timescale of 0 reads as a NaN duration, which `Int(_:)` trapped on at every start; an edit list
                // can make the count huge, which traps playback's frame arithmetic. The same bound as `MovieSource`.
                guard let frameCount = Int(exactly: (duration * Double(frameRate)).rounded()), (0...Int(Int32.max)).contains(frameCount)
                else { throw MovieError.unknownDuration }
                guard Double(frameRate) <= MovieSource.maxFrameRate else { throw MovieError.frameRate }  // B336, as `MovieSource`
                metadata.frameCount = frameCount
                if let description = descriptions.first {
                    let codec = CMFormatDescriptionGetMediaSubType(description)
                    metadata.codec = fourCCString(codec)
                    metadata.hasAlpha = ["ap4h", "ap4x", "Hap5", "HapM", "HapA"].contains(metadata.codec)
                    let ratio = MovieSource.pixelAspect(of: description)
                    if abs(ratio - 1) > 0.005 { metadata.pixelAspect = ratio }  // 1001:1000-style tags are square pixels
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
            return metadata
        }
    }

    // MARK: Cache

    private var cacheFile: URL { cacheDirectory.appending(path: "library-index.json") }
    var markerFile: URL { cacheDirectory.appending(path: "library-probing.json") }

    private func loadCache(readsStopMarker: Bool) {
        if let data = try? Data(contentsOf: cacheFile), let cache = try? JSONDecoder().decode([String: CacheEntry].self, from: data) {
            state.withLock { $0.cache = cache }
        }
        // B267: a marker means the engine stopped while that file was read (a crash, a kill, a power cut). The second time it
        // is unreadable until it changes (a new size or date is a new cache key); the first time it is read once more. A
        // marker under another root is from a run on another root.
        guard readsStopMarker, let data = try? Data(contentsOf: markerFile), let marker = try? JSONDecoder().decode(ProbeMarker.self, from: data),
            marker.path.hasPrefix(root.path + "/")
        else { return }
        if marker.stops + 1 >= 2 {
            logger.warning("the engine stopped twice while reading this library file: listed as unreadable until it changes", metadata: ["file": "\(marker.path)"])
            state.withLock {
                $0.cache[marker.key] = CacheEntry(metadata: nil, thumbnail: nil, status: .unreadable, reason: Self.stoppedTwice, reasonsVersion: Self.reasonsVersion)
            }
            saveCache()  // before the marker goes: a stop in between keeps the count
            try? FileManager.default.removeItem(at: markerFile)
        } else {
            // the marker stays until the next probe (of any file) overwrites it or the queue drains, and a stop before that leaves
            // the count at one; after that the count is in memory only, so a stop before this file's re-probe loses it (the
            // safe side: three stops instead of two)
            logger.warning("the engine stopped while reading this library file: it is read once more", metadata: ["file": "\(marker.path)"])
            state.withLock { $0.stoppedIn = (marker.key, marker.stops + 1) }
        }
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
            nil, callback, &context, [Self.watchPath(root)] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents))
        else {
            logger.warning("FSEvents unavailable for \(root.path); the library only rescans on request")
            return
        }
        FSEventStreamSetDispatchQueue(stream, eventQueue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// The path to give FSEvents for `url`. Events carry real paths, and a watched path's symlinks are resolved only when it
    /// exists, so a root missing at start behind a symlink (`/tmp`, a `~/Movies` linked to another disk) never saw an event
    /// once it was made (B140): resolve the part that exists with `realpath` and append the rest.
    static func watchPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        guard let real = realpath(existing.path, nil) else { return url.path }
        defer { free(real) }
        return rest.reduce(URL(fileURLWithPath: String(cString: real))) { $0.appending(path: $1) }.path  // no "//" under "/"
    }

    /// Debounced: one rescan 500 ms after the last event (DESIGN.md §8.1).
    private func scheduleRescan() {
        eventQueue.async { [self] in
            guard !rescanPending else { return }
            rescanPending = true
            eventQueue.asyncAfter(deadline: .now() + 0.5) { [self] in
                rescanPending = false
                if running.load(ordering: .relaxed) { rescan() }  // never after stop(): the root may have been replaced
            }
        }
    }
}

// MARK: - Ingest targets

extension LibraryIndex {
    /// Uploads land here before ingest (DESIGN.md §8.1); never indexed.
    public var incomingDirectory: URL { root.appending(path: "_incoming") }

    /// One lock around list-and-create (B141): each HTTP client has its own queue, so two folder creates for one number,
    /// or an upload making the folder between an endpoint's check and its create, would make two folders. Static: an
    /// upload keeps its index when the root changes (`IngestAPI.enqueueNow`).
    private static let folderLock = Mutex(())

    /// The folder with this number, or a new `NNN_<name>` folder when `createAs` is given; nil when there is none and no
    /// name, or the create fails (B142: a read-only root). Reads the disk, not the snapshot: a folder an upload just
    /// created is there before the debounced rescan. Sorted like `rescan()`, so a duplicate number gives the folder the
    /// index keeps (hidden and `_` names have no prefix number).
    public func folderURL(number: Int, createAs name: String? = nil) -> URL? {
        Self.folderLock.withLock { _ in existingFolder(number) ?? name.flatMap { makeFolder(number, $0) } }
    }

    public enum FolderCreate: Equatable, Sendable {
        case created(URL), exists(URL), failed
    }

    /// Creates `NNN_<name>`, under the one lock, so `.exists` also covers a folder an upload or another client made a
    /// moment ago (B141), and `.failed` a root that cannot be written (B142).
    public func createFolder(number: Int, name: String) -> FolderCreate {
        Self.folderLock.withLock { _ in
            if let url = existingFolder(number) { return .exists(url) }
            return makeFolder(number, name).map { .created($0) } ?? .failed
        }
    }

    private func existingFolder(_ number: Int) -> URL? {
        for folder in ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted() where Self.prefixNumber(folder) == number {
            let url = root.appending(path: folder)
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { return url }
        }
        return nil
    }

    /// Also makes the root (`withIntermediateDirectories`).
    private func makeFolder(_ number: Int, _ name: String) -> URL? {
        guard (1...255).contains(number) else { return nil }
        let url = root.appending(path: String(format: "%03d_%@", number, Self.safeName(name)))
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) } catch { return nil }
        return url
    }

    /// Smallest file number (1–255) that no entry of `folder` on disk and no name in `pending` uses; nil when the folder is
    /// full. Reads the disk, not the snapshot: a file an ingest job just wrote is there before the debounced rescan.
    public static func nextFileNumber(in folder: URL, pending: [String] = []) -> Int? {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []) + pending
        let used = Set(names.compactMap(prefixNumber))
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
