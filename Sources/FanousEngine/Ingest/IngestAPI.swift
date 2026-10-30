// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import Logging
import Synchronization

/// HTTP surface of the ingest queue and remote upload (DESIGN.md §8.3).
///   GET  /api/ingest                 queue as JSON
///   POST /api/ingest                 {"source": path, "folder": N, "file": N?, "name": "...", "codec": "hapq"?, "fps": 25?}
///   POST /api/ingest/<id>/cancel · POST /api/ingest/<id>/remove
///   PUT  /api/upload/<folder>/<name>  body = the file; it lands in _incoming/ and is queued for folder N
/// ponytail: no role check yet (Phase 5 brings roles); the engine listens on the LAN like every other endpoint.
public final class IngestAPI: @unchecked Sendable {
    public static let defaultCodec: MovieWriter.Codec = .proRes422HQ
    /// The current index: the library root can change while the engine runs (B51).
    private let currentLibrary: @Sendable () -> LibraryIndex
    private var library: LibraryIndex { currentLibrary() }
    private let queue: IngestQueue
    private let encoder: JSONEncoder
    private let logger: Logger

    public init(library: @escaping @Sendable () -> LibraryIndex, queue: IngestQueue, encoder: JSONEncoder, logger: Logger) {
        currentLibrary = library
        self.queue = queue
        self.encoder = encoder
        self.logger = logger
    }

    struct JobRequest: Decodable {
        var source: String
        var folder: Int
        var file: Int?
        var name: String?
        var codec: String?
        var fps: Int32?
        var keepOriginal: Bool?
    }

    /// Where a large `PUT /api/upload/...` body is streamed; nil refuses it.
    public func uploadTarget(for request: HTTPRequest) -> URL? {
        guard request.method == "PUT", let (_, name) = Self.uploadComponents(request.path) else { return nil }
        try? FileManager.default.createDirectory(at: library.incomingDirectory, withIntermediateDirectories: true)
        return library.incomingDirectory.appending(path: Self.uniqueName(name, in: library.incomingDirectory))
    }

    public func handle(_ request: HTTPRequest, uploadedFile: URL?) -> HTTPResponse {
        let path = request.path
        if path.hasPrefix("/api/upload/") {
            guard request.method == "PUT", let (folder, name) = Self.uploadComponents(path) else { return .text(400, "PUT /api/upload/<folder>/<name>") }
            let file: URL
            if let uploadedFile {
                file = uploadedFile
            } else {
                try? FileManager.default.createDirectory(at: library.incomingDirectory, withIntermediateDirectories: true)
                file = library.incomingDirectory.appending(path: Self.uniqueName(name, in: library.incomingDirectory))
                do { try Data(request.body).write(to: file) } catch { return .text(500, "cannot store upload: \(error)") }
            }
            return enqueue(source: file, folder: folder, file: nil, name: name, codec: nil, fps: nil, keepOriginal: false)
        }
        switch (request.method, path) {
        case ("GET", "/api/ingest"):
            return .json(200, Array((try? encoder.encode(queue.jobs)) ?? Data()))
        case ("POST", "/api/ingest"):
            guard let job = try? JSONDecoder().decode(JobRequest.self, from: Data(request.body)) else { return .text(400, "bad job JSON") }
            return enqueue(
                source: URL(fileURLWithPath: job.source), folder: job.folder, file: job.file, name: job.name, codec: job.codec, fps: job.fps,
                keepOriginal: job.keepOriginal ?? true)
        case ("POST", let p) where p.hasSuffix("/cancel"):
            guard let id = UUID(uuidString: String(p.dropFirst("/api/ingest/".count).dropLast("/cancel".count))) else { return .text(404, "no such job") }
            queue.cancel(id: id)
            return .text(200, "cancelled")
        case ("POST", let p) where p.hasSuffix("/remove"):
            guard let id = UUID(uuidString: String(p.dropFirst("/api/ingest/".count).dropLast("/remove".count))) else { return .text(404, "no such job") }
            queue.remove(id: id)
            return .text(200, "removed")
        default:
            return .text(404, "not found")
        }
    }

    /// Builds the destination (`NNN_name.ext` in the numbered folder) and queues the job.
    /// Why new jobs are refused (a library root change in progress, B51), with how many holds are active.
    private let hold = Mutex<(count: Int, reason: String)>((0, ""))

    /// Refuses new jobs until `releaseEnqueue()`; returns once no enqueue is in progress, so the queue's job list is
    /// final apart from jobs finishing. Holds nest.
    public func holdEnqueue(_ reason: String) { hold.withLock { $0 = ($0.count + 1, reason) } }
    public func releaseEnqueue() { hold.withLock { $0.count = max(0, $0.count - 1) } }

    func enqueue(source: URL, folder: Int, file: Int?, name: String?, codec: String?, fps: Int32?, keepOriginal: Bool) -> HTTPResponse {
        // under the hold lock: a root change that takes the hold never sees a job appear after its check
        hold.withLock { hold in
            if hold.count > 0 { return .text(409, hold.reason) }
            return enqueueNow(source: source, folder: folder, file: file, name: name, codec: codec, fps: fps, keepOriginal: keepOriginal)
        }
    }

    private func enqueueNow(source: URL, folder: Int, file: Int?, name: String?, codec: String?, fps: Int32?, keepOriginal: Bool) -> HTTPResponse {
        let library = self.library  // one index for the whole job, also if the root changes meanwhile
        guard (1...255).contains(folder) else { return .text(400, "folder must be 1–255") }
        guard FileManager.default.fileExists(atPath: source.path) else { return .text(404, "source not found") }
        guard let folderURL = library.folderURL(number: folder, createAs: name.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Folder")
        else { return .text(400, "cannot create folder \(folder)") }
        // Jobs before the disk: a job writes its file before it is marked done, so every job that is writing or wrote a file
        // shows in one of them. Needs the hold lock around all of enqueueNow: two enqueues must not both read before either appends.
        let pending = queue.jobs.filter { !$0.state.isFinished && $0.destination.deletingLastPathComponent().path == folderURL.path }
        guard let number = file ?? LibraryIndex.nextFileNumber(in: folderURL, pending: pending.map(\.destination.lastPathComponent)), (1...255).contains(number)
        else { return .text(409, "folder \(folder) is full") }
        let originalName = name ?? source.lastPathComponent
        let ext = source.pathExtension.lowercased()
        let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let kind: IngestJob.Kind
        let destinationExtension: String
        if isDirectory {
            kind = .sequence(fps: fps ?? 25, codec: Self.codec(named: codec) ?? .proRes4444)
            destinationExtension = "mov"
        } else if StillSource.extensions.contains(ext) {
            kind = .still
            destinationExtension = ext
        } else {
            kind = .transcode(codec: Self.codec(named: codec) ?? Self.defaultCodec)
            destinationExtension = "mov"
        }
        let destination = folderURL.appending(path: LibraryIndex.destinationName(number: number, originalName: originalName, pathExtension: destinationExtension))
        let originals = keepOriginal ? folderURL.appending(path: "_originals") : nil
        var job = IngestJob(source: source, destination: destination, kind: kind, originalsDirectory: originals, deleteSource: !keepOriginal)
        job = queue.enqueue(job)
        logger.info("ingest queued", metadata: ["source": "\(source.lastPathComponent)", "destination": "\(destination.lastPathComponent)", "id": "\(job.id)"])
        return .json(202, Array((try? encoder.encode(job)) ?? Data()))
    }

    static func codec(named name: String?) -> MovieWriter.Codec? {
        switch name?.lowercased() {
        case "prores422hq": .proRes422HQ
        case "prores422": .proRes422
        case "prores4444": .proRes4444
        case "hap": .hap(.hap)
        case "hapalpha": .hap(.hapAlpha)
        case "hapq": .hap(.hapQ)
        case "hapalphaonly": .hap(.hapAlphaOnly)
        default: nil
        }
    }

    /// `/api/upload/<folder>/<name>` → (folder, percent-decoded file name without path components).
    static func uploadComponents(_ path: String) -> (Int, String)? {
        let parts = path.dropFirst("/api/upload/".count).split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let folder = Int(parts[0]), let decoded = parts[1].removingPercentEncoding else { return nil }
        let name = URL(fileURLWithPath: decoded).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix(".") else { return nil }
        return (folder, name)
    }

    static func uniqueName(_ name: String, in directory: URL) -> String {
        var candidate = name
        var n = 1
        let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: name).pathExtension
        while FileManager.default.fileExists(atPath: directory.appending(path: candidate).path) {
            n += 1
            candidate = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
        }
        return candidate
    }
}
