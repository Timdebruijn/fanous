// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import Foundation
import Logging
import Synchronization

/// One unit of ingest work (DESIGN.md §8.3). The caller decides the final path (library numbering); the queue only
/// writes there, atomically, and handles the original.
public struct IngestJob: Codable, Sendable, Identifiable {
    public enum Kind: Codable, Sendable, Equatable {
        /// A movie AVFoundation can read → `.mov` in `codec` (promoted for alpha sources, see `Transcoder.effectiveCodec`).
        case transcode(codec: MovieWriter.Codec)
        /// `source` is a directory of numbered images → a movie at `fps`.
        case sequence(fps: Int32, codec: MovieWriter.Codec)
        /// A still image: copied as it is.
        case still
    }

    public enum State: Codable, Sendable, Equatable {
        case queued
        case running(progress: Double)
        case done
        case failed(String)
        case cancelled

        public var isFinished: Bool {
            switch self {
            case .queued, .running: false
            case .done, .failed, .cancelled: true
            }
        }
    }

    public var id: UUID
    public var source: URL
    public var destination: URL
    public var kind: Kind
    /// When set, the source is moved here after success (a name collision gets a numeric suffix); nil leaves it in place.
    public var originalsDirectory: URL?
    /// With no `originalsDirectory`: delete the source after success. `originalsDirectory` wins when both are set.
    public var deleteSource: Bool
    public var state: State
    public var createdAt: Date
    public var finishedAt: Date?

    public init(
        source: URL, destination: URL, kind: Kind, originalsDirectory: URL? = nil, deleteSource: Bool = false
    ) {
        id = UUID()
        self.source = source
        self.destination = destination
        self.kind = kind
        self.originalsDirectory = originalsDirectory
        self.deleteSource = deleteSource
        state = .queued
        createdAt = Date()
        finishedAt = nil
    }
}

/// Runs ingest jobs one at a time on a single `.utility` thread, persists the queue as JSON, and reloads it at init
/// (jobs that were running when the process died start over from `queued`). Output is written to a hidden temp file in
/// the destination directory and renamed on success, so the library index never sees a partial movie.
/// The running worker keeps the queue alive: call `stop()` when done.
public final class IngestQueue: @unchecked Sendable {
    private struct State {
        var jobs: [IngestJob] = []
        var paused = false
        var stopping = false
        var thread: Thread?
        var current: (id: UUID, gate: IngestGate)?
        var onChange: (@Sendable () -> Void)?
        var shouldYield: (@Sendable () -> Bool)?
    }

    private let url: URL
    private let logger: Logger
    private let state = Mutex(State())
    private let wake = DispatchSemaphore(value: 0)
    private let exited = DispatchSemaphore(value: 0)

    /// Loads the queue persisted at `persistenceURL` (if any); every later change is saved there.
    public init(persistenceURL: URL, logger: Logger = Logger(label: "fanous.ingest")) {
        url = persistenceURL
        self.logger = logger
        var jobs: [IngestJob] = []
        if let data = try? Data(contentsOf: persistenceURL) {
            do {
                jobs = try Self.decoder.decode([IngestJob].self, from: data)
            } catch {
                logger.error("ingest queue file unreadable, starting empty", metadata: ["file": "\(persistenceURL.path)", "error": "\(error)"])
                try? FileManager.default.moveItem(at: persistenceURL, to: persistenceURL.appendingPathExtension("corrupt"))
            }
        }
        for index in jobs.indices {
            if case .running = jobs[index].state {
                jobs[index].state = .queued
                try? FileManager.default.removeItem(at: Self.temporaryURL(for: jobs[index]))  // the half-written output of the crashed run
            }
        }
        state.withLock { $0.jobs = jobs }
    }

    // MARK: API

    /// A snapshot, oldest first.
    public var jobs: [IngestJob] { state.withLock { $0.jobs } }

    /// Called after every state change (also progress, at most every 1 %), on whichever thread caused it.
    public var onChange: (@Sendable () -> Void)? {
        get { state.withLock { $0.onChange } }
        set { state.withLock { $0.onChange = newValue } }
    }

    /// Asked between frames of a running job; true makes it wait 20 ms before the next frame (compositor load, DESIGN.md §8.3).
    public var shouldYield: (@Sendable () -> Bool)? {
        get { state.withLock { $0.shouldYield } }
        set { state.withLock { $0.shouldYield = newValue } }
    }

    /// Show lock: no job starts while true, and a running job holds after its current frame. Not persisted.
    public var paused: Bool {
        get { state.withLock { $0.paused } }
        set {
            state.withLock { $0.paused = newValue }
            wake.signal()
        }
    }

    /// Adds `job` as queued (whatever state it came with) and returns the stored copy.
    @discardableResult
    public func enqueue(_ job: IngestJob) -> IngestJob {
        var job = job
        job.state = .queued
        job.finishedAt = nil
        mutate { $0.jobs.append(job) }
        wake.signal()
        return job
    }

    /// A queued job is cancelled at once; a running one at its next frame (its partial output is removed). Finished jobs stay as they are.
    public func cancel(id: UUID) {
        mutate { state in
            guard let index = state.jobs.firstIndex(where: { $0.id == id }) else { return }
            if state.current?.id == id {
                state.current?.gate.cancel()
            } else if state.jobs[index].state == .queued {
                state.jobs[index].state = .cancelled
                state.jobs[index].finishedAt = Date()
            }
        }
    }

    /// Drops a finished job from the list (queued and running jobs have to be cancelled first).
    public func remove(id: UUID) {
        mutate { state in
            state.jobs.removeAll { $0.id == id && $0.state.isFinished }
        }
    }

    /// Starts the worker thread (once).
    public func start() {
        state.withLock { state in
            guard state.thread == nil else { return }
            let thread = Thread { [self] in workerLoop() }
            thread.name = "fanous.ingest"
            thread.qualityOfService = .utility
            state.thread = thread
            state.stopping = false
            thread.start()
        }
        wake.signal()
    }

    /// Stops after cancelling the running job, which goes back to `queued` (it starts over at the next `start()` or launch).
    /// Returns when the worker has exited.
    public func stop() {
        let running = state.withLock { state -> Bool in
            guard state.thread != nil else { return false }
            state.stopping = true
            state.current?.gate.cancel()
            return true
        }
        guard running else { return }
        wake.signal()
        exited.wait()
        state.withLock { $0.thread = nil }
    }

    // MARK: Worker

    private func workerLoop() {
        while true {
            wake.wait()
            while let job = claimNext() { run(job) }
            if state.withLock({ $0.stopping }) { break }
        }
        exited.signal()
    }

    /// The first queued job, marked running; nil while paused or stopping or when nothing is queued.
    private func claimNext() -> IngestJob? {
        mutate { state in
            guard !state.paused, !state.stopping, let index = state.jobs.firstIndex(where: { $0.state == .queued }) else { return nil }
            state.jobs[index].state = .running(progress: 0)
            state.current = (state.jobs[index].id, IngestGate())
            return state.jobs[index]
        }
    }

    private func run(_ job: IngestJob) {
        let gate = state.withLock { $0.current!.gate }
        gate.shouldYield = { [weak self] in self?.shouldYield?() ?? false }
        gate.isPaused = { [weak self] in self?.paused ?? false }
        var outcome: IngestJob.State
        let temporary = Self.temporaryURL(for: job)
        do {
            try execute(job, temporary: temporary, gate: gate)
            outcome = .done
            finishOriginal(of: job)
        } catch TranscodeError.cancelled {
            try? FileManager.default.removeItem(at: temporary)
            outcome = .cancelled
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            let message = Self.message(error)
            outcome = .failed(message)
            logger.warning("ingest job failed", metadata: ["source": "\(job.source.path)", "error": "\(message)"])
        }
        mutate { state in
            state.current = nil
            guard let index = state.jobs.firstIndex(where: { $0.id == job.id }) else { return }
            if state.stopping, outcome == .cancelled {
                state.jobs[index].state = .queued  // interrupted by stop(), not by the user
            } else {
                state.jobs[index].state = outcome
                state.jobs[index].finishedAt = Date()
            }
        }
    }

    /// Produces `job.destination` through `temporary` (same directory, so the final rename is atomic).
    private func execute(_ job: IngestJob, temporary: URL, gate: IngestGate) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: job.source.path) else { throw IngestError.missingSource(job.source) }
        guard job.source.standardizedFileURL != job.destination.standardizedFileURL else { throw IngestError.sameFile }
        guard !files.fileExists(atPath: job.destination.path) else { throw IngestError.destinationExists(job.destination) }
        try files.createDirectory(at: job.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? files.removeItem(at: temporary)

        var lastReport = -1.0
        let report: (Int, Int) -> Void = { [self] done, total in
            let fraction = total > 0 ? min(1, Double(done) / Double(total)) : 0
            guard fraction - lastReport >= 0.01 || done == total else { return }
            lastReport = fraction
            mutate(persist: false) { state in
                if let index = state.jobs.firstIndex(where: { $0.id == job.id }) { state.jobs[index].state = .running(progress: fraction) }
            }
        }

        switch job.kind {
        case .transcode(let codec):
            try Transcoder(source: job.source, destination: temporary, codec: codec, gate: gate).run(progress: report)
        case .sequence(let fps, let codec):
            let frames = try SequenceIngest.frames(in: job.source)
            // The progress callback runs between frames: that is where cancel, yield and pause are honoured.
            try SequenceIngest.convert(frames: frames, to: temporary, fps: fps, codec: codec) { done, total in
                try gate.checkpoint()
                report(done, total)
            }
        case .still:
            try files.copyItem(at: job.source, to: temporary)
        }
        try gate.throwIfCancelled()
        try files.moveItem(at: temporary, to: job.destination)
    }

    /// Moves the source to the originals directory or deletes it, as configured. The output exists by now, so a failure
    /// here is logged and does not fail the job (a retry would only trip over the existing destination).
    private func finishOriginal(of job: IngestJob) {
        let files = FileManager.default
        do {
            if let directory = job.originalsDirectory {
                try files.createDirectory(at: directory, withIntermediateDirectories: true)
                try files.moveItem(at: job.source, to: Self.uniqueURL(for: job.source.lastPathComponent, in: directory))
            } else if job.deleteSource {
                try files.removeItem(at: job.source)
            }
        } catch {
            logger.warning("ingest could not dispose of the original", metadata: ["source": "\(job.source.path)", "error": "\(error)"])
        }
    }

    // MARK: State and persistence

    /// Changes the state under the lock, saves the queue (unless `persist` is false) and then calls `onChange` outside the lock.
    @discardableResult
    private func mutate<T: Sendable>(persist: Bool = true, _ body: (inout State) -> T) -> T {
        let (result, callback) = state.withLock { state -> (T, (@Sendable () -> Void)?) in
            let result = body(&state)
            // ponytail: saved under the lock, so a concurrent `jobs` read waits for a small atomic write; per-change
            // file writes are fine for hundreds of jobs, debounce or an append-only log beyond that.
            if persist { save(state.jobs) }
            return (result, state.onChange)
        }
        callback?()
        return result
    }

    private func save(_ jobs: [IngestJob]) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(jobs).write(to: url, options: .atomic)
        } catch {
            logger.error("ingest queue not saved", metadata: ["file": "\(url.path)", "error": "\(error)"])
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Hidden, next to the destination; derived from the job id so a restart can clean up after a crash.
    static func temporaryURL(for job: IngestJob) -> URL {
        let name = ".ingest-\(job.id.uuidString)"
        let ext = job.destination.pathExtension
        return job.destination.deletingLastPathComponent().appending(path: ext.isEmpty ? name : "\(name).\(ext)")
    }

    /// `name`, or `name-2.ext`, `name-3.ext`, … when `directory` already has it.
    static func uniqueURL(for name: String, in directory: URL) -> URL {
        var candidate = directory.appending(path: name)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)")
            suffix += 1
        }
        return candidate
    }

    static func message(_ error: Error) -> String {
        let domain = (error as NSError).domain
        return domain == NSCocoaErrorDomain || domain == AVFoundationErrorDomain || domain == NSPOSIXErrorDomain
            ? error.localizedDescription : "\(error)"
    }

    enum IngestError: Error, CustomStringConvertible {
        case missingSource(URL)
        case destinationExists(URL)
        case sameFile

        var description: String {
            switch self {
            case .missingSource(let url): "source not found: \(url.lastPathComponent)"
            case .destinationExists(let url): "destination already exists: \(url.lastPathComponent)"
            case .sameFile: "source and destination are the same file"
            }
        }
    }
}
