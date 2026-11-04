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
        // refused: hidden, dot names, empty, a folder that is not a number
        #expect(Self.name(".hidden") == nil)
        #expect(Self.name("") == nil)
        #expect(Self.name("x.mov", folder: "abc") == nil)
        #expect(Self.name("bad%zz") == nil)
        // a NUL never reaches the file name (Foundation escapes it in the path component)
        #expect(Self.name("a%00.mov").map { !$0.contains("\0") } ?? true)
    }

    /// `URL(fileURLWithPath:)` resolves `..` against the process's working directory, so the `name != ".."` guard never
    /// sees it: the name becomes that directory's parent's name ("/" when the engine runs in "/").
    @Test func dotDotIsNotRefused() {
        withKnownIssue("`..` becomes the working directory's parent's name instead of nil") {
            #expect(Self.name("..") == nil)
            #expect(Self.name("%2E%2E") == nil)
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

    /// The folder range is checked in `enqueueNow`, after `uploadTarget` handed out a file and the body was written there
    /// (IngestAPI.uploadTarget does not check it), so a refused folder leaves the upload in `_incoming`.
    @Test func refusedFolderLeavesNoUploadBehind() throws {
        let (api, library) = try Self.api()
        #expect(api.uploadTarget(for: try Self.put("/api/upload/0/clip.mov")) != nil)
        let response = api.handle(try Self.put("/api/upload/256/clip.mov", body: [1, 2, 3]), uploadedFile: nil)
        #expect(response.status == 400)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: library.incomingDirectory.path)) ?? []
        withKnownIssue("folder 0/256 passes uploadTarget; the refused upload stays in _incoming") {
            #expect(left.isEmpty)
        }
    }
}
