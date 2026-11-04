// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Testing

@testable import FanousEngine

/// `PUT /api/upload/<folder>/<name>`: the name in the URL decides where the body is written, so it must never leave
/// `_incoming`.
@Suite(.cleansTempFiles) struct IngestAPITests {
    static func name(_ last: String, folder: String = "1") -> String? {
        IngestAPI.uploadComponents("/api/upload/\(folder)/\(last)")?.1
    }

    @Test func uploadNamesAreOneVisiblePathComponent() {
        #expect(IngestAPI.uploadComponents("/api/upload/7/clip.mov")?.0 == 7)
        #expect(Self.name("clip.mov") == "clip.mov")
        #expect(Self.name("my%20clip.mov") == "my clip.mov")
        // directories in the name, also percent-encoded ones, are dropped: what is left is the last component
        #expect(Self.name("..%2F..%2Fx.mov") == "x.mov")
        #expect(Self.name("../x.mov") == "x.mov")
        #expect(Self.name("abc/x") == "x")
        #expect(Self.name("%2Fetc%2Fpasswd") == "passwd")
        // refused: hidden, empty, a folder that is not a number or not 1–255, a NUL
        for refused in [".hidden", "", "bad%zz", "a%00.mov"] {
            #expect(Self.name(refused) == nil, "\(refused)")
        }
        for folder in ["abc", "0", "256", "-1"] {
            #expect(Self.name("x.mov", folder: folder) == nil, "folder \(folder)")
        }
        #expect(Self.name("x.mov", folder: "255") == "x.mov")
    }

    /// `.` and `..` are refused on the raw component: `URL(fileURLWithPath:)` would resolve them against the working
    /// directory, and the name would become that directory's or its parent's name (B154).
    @Test func dotNamesAreRefused() {
        for name in [".", "..", "%2E", "%2E%2E", "x%2F.."] {
            #expect(Self.name(name) == nil, "\(name)")
        }
    }

    static func api() throws -> (IngestAPI, LibraryIndex) {
        let root = try tempDir("ingest-api")
        let library = LibraryIndex(root: root, cacheDirectory: root.appending(path: "cache"), logger: testLogger)
        let queue = IngestQueue(persistenceURL: root.appending(path: "queue.json"), logger: testLogger)
        return (IngestAPI(library: { library }, queue: queue, encoder: JSONEncoder(), logger: testLogger), library)
    }

    static func put(_ path: String, body: [UInt8] = []) throws -> HTTPRequest {
        var request = try #require(try HTTPRequest.parse(Array("PUT \(path) HTTP/1.1\r\nHost: x\r\n\r\n".utf8))).request
        request.body = body
        return request
    }

    @Test func uploadTargetStaysInIncoming() throws {
        let (api, library) = try Self.api()
        for (name, file) in [
            ("..%2F..%2Fx.mov", "x.mov"), ("%2Fetc%2Fpasswd", "passwd"), ("a%2F..%2F..%2Fb.mov", "b.mov"),
        ] {
            let target = try #require(api.uploadTarget(for: try Self.put("/api/upload/1/\(name)")))
            #expect(
                target.deletingLastPathComponent().standardizedFileURL == library.incomingDirectory.standardizedFileURL)
            #expect(target.lastPathComponent == file)
        }
        #expect(api.uploadTarget(for: try Self.put("/api/upload/1/.hidden")) == nil)
    }

    /// A refused upload writes nothing: a folder out of range is refused before the body is written, and an upload that
    /// `enqueue` refuses after it was written (a hold) is removed again.
    @Test func refusedUploadsLeaveNothingBehind() throws {
        let (api, library) = try Self.api()
        let incoming = { (try? FileManager.default.contentsOfDirectory(atPath: library.incomingDirectory.path)) ?? [] }
        for folder in ["0", "256"] {
            #expect(api.uploadTarget(for: try Self.put("/api/upload/\(folder)/clip.mov")) == nil)
            #expect(api.handle(try Self.put("/api/upload/\(folder)/clip.mov", body: [1, 2, 3]), uploadedFile: nil).status == 400)
        }
        #expect(api.handle(try Self.put("/api/upload/1/..", body: [1, 2, 3]), uploadedFile: nil).status == 400)
        #expect(incoming().isEmpty)
        api.holdEnqueue("root change")
        #expect(api.handle(try Self.put("/api/upload/1/clip.mov", body: [1, 2, 3]), uploadedFile: nil).status == 409)
        api.releaseEnqueue()
        #expect(incoming().isEmpty)
    }
}
