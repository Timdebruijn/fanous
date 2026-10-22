// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Testing

@testable import LanthornCore

@Suite struct HTTPTests {
    @Test func parsesARequestHead() throws {
        let raw = Array("GET /index.html?x=1 HTTP/1.1\r\nHost: a\r\nContent-Length: 0\r\nconnection: close\r\n\r\nrest".utf8)
        let (request, headLength) = try #require(try HTTPRequest.parse(raw))
        #expect(request.method == "GET")
        #expect(request.target == "/index.html?x=1")
        #expect(request.path == "/index.html")
        #expect(request.header("host") == "a")
        #expect(request.contentLength == 0)
        #expect(request.wantsClose)
        #expect(headLength == raw.count - 4)
    }

    @Test func incompleteHeadReturnsNil() throws {
        #expect(try HTTPRequest.parse(Array("GET / HTTP/1.1\r\nHost: a\r\n".utf8)) == nil)
        #expect(try HTTPRequest.parse([]) == nil)
    }

    @Test func malformedInputThrows() {
        #expect(throws: HTTPRequest.ParseError.malformedRequestLine) {
            try HTTPRequest.parse(Array("GET /\r\n\r\n".utf8))
        }
        #expect(throws: HTTPRequest.ParseError.malformedRequestLine) {
            try HTTPRequest.parse(Array("GET / HTTP/2\r\n\r\n".utf8))
        }
        #expect(throws: HTTPRequest.ParseError.malformedHeader) {
            try HTTPRequest.parse(Array("GET / HTTP/1.1\r\nNoColon\r\n\r\n".utf8))
        }
        #expect(throws: HTTPRequest.ParseError.headTooLarge) {
            try HTTPRequest.parse([UInt8](repeating: 0x41, count: HTTPRequest.maxHeadBytes + 1))
        }
    }

    @Test func keepAliveDefaultsForHTTP11() throws {
        let (request, _) = try #require(try HTTPRequest.parse(Array("GET / HTTP/1.1\r\n\r\n".utf8)))
        #expect(!request.wantsClose)
        let (old, _) = try #require(try HTTPRequest.parse(Array("GET / HTTP/1.0\r\n\r\n".utf8)))
        #expect(old.wantsClose)
    }

    @Test func serializesResponses() {
        let response = HTTPResponse.text(200, "hi")
        let full = String(decoding: response.serialized(), as: UTF8.self)
        #expect(full == "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 2\r\n\r\nhi")
        let head = String(decoding: response.serialized(includeBody: false), as: UTF8.self)
        #expect(head.hasSuffix("Content-Length: 2\r\n\r\n"))
    }

    @Test func staticPathsAreSanitized() {
        #expect(StaticFiles.relativePath(forRequestPath: "/") == "index.html")
        #expect(StaticFiles.relativePath(forRequestPath: "/assets/app.js") == "assets/app.js")
        #expect(StaticFiles.relativePath(forRequestPath: "/a//b/") == "a/b")
        #expect(StaticFiles.relativePath(forRequestPath: "/../etc/passwd") == nil)
        #expect(StaticFiles.relativePath(forRequestPath: "/a/%2e%2e/b") == nil)
        #expect(StaticFiles.relativePath(forRequestPath: "/.git/config") == nil)
        #expect(StaticFiles.relativePath(forRequestPath: "/a\\b") == nil)
        #expect(StaticFiles.relativePath(forRequestPath: "/a%00b") == nil)
        #expect(StaticFiles.relativePath(forRequestPath: "noslash") == nil)
    }

    @Test func mimeTypes() {
        #expect(MIMEType.forPath("index.html") == "text/html; charset=utf-8")
        #expect(MIMEType.forPath("assets/app-1a2b.js") == "text/javascript; charset=utf-8")
        #expect(MIMEType.forPath("x.unknown") == "application/octet-stream")
    }
}
