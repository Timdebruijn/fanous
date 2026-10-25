// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Logging

/// Appends log lines to one file; rotates once to `.1` past `maxBytes`.
public final class FileLogSink: @unchecked Sendable {
    private let url: URL
    private let maxBytes: UInt64
    private let lock = NSLock()
    private var handle: FileHandle?

    public init(url: URL, maxBytes: UInt64 = 10_000_000) {
        self.url = url
        self.maxBytes = maxBytes
    }

    func write(_ line: String) {
        lock.withLock {
            do {
                if handle == nil { handle = try open() }
                if let size = try handle?.seekToEnd(), size > maxBytes {
                    try handle?.close()
                    handle = nil
                    let rotated = url.appendingPathExtension("1")
                    try? FileManager.default.removeItem(at: rotated)
                    try FileManager.default.moveItem(at: url, to: rotated)
                    handle = try open()
                }
                try handle?.write(contentsOf: Data(line.utf8))
            } catch {
                FileHandle.standardError.write(Data("log file error: \(error)\n".utf8))
            }
        }
    }

    private func open() throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }
}

public struct FileLogHandler: LogHandler {
    public var logLevel: Logger.Level = .info
    public var metadata: Logger.Metadata = [:]
    private let label: String
    private let sink: FileLogSink

    public init(label: String, sink: FileLogSink) {
        self.label = label
        self.sink = sink
    }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(
        level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String,
        file: String, function: String, line: UInt
    ) {
        let merged = self.metadata.merging(metadata ?? [:]) { $1 }
        let suffix = merged.isEmpty ? "" : " " + merged.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(Date())
        sink.write("\(stamp) \(level) [\(label)] \(message)\(suffix)\n")
    }
}

public enum EngineLogging {
    /// stderr + rotating file. Call once, before the first Logger is created.
    public static func bootstrap(fileURL: URL, level: Logger.Level = .info) {
        let sink = FileLogSink(url: fileURL)
        LoggingSystem.bootstrap { label in
            var stderr = StreamLogHandler.standardError(label: label)
            stderr.logLevel = level
            var file = FileLogHandler(label: label, sink: sink)
            file.logLevel = level
            return MultiplexLogHandler([stderr, file])
        }
    }
}
