// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

public struct HTTPHeader: Equatable, Sendable {
    public var name: String
    public var value: String
    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// An HTTP/1.1 request head. Bodies are handled by the caller.
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var target: String
    public var version: String
    public var headers: [HTTPHeader]

    public enum ParseError: Error, Equatable {
        case malformedRequestLine
        case malformedHeader
        case headTooLarge
    }

    public static let maxHeadBytes = 16 * 1024

    public var path: String { String(target.prefix { $0 != "?" }) }

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var contentLength: Int { Int(header("Content-Length") ?? "") ?? 0 }

    public var wantsClose: Bool {
        version == "HTTP/1.0" || header("Connection")?.lowercased() == "close"
    }

    /// Parses one request head from the start of `bytes`.
    /// Returns nil while the head (terminated by CRLF CRLF) is incomplete.
    public static func parse(_ bytes: [UInt8]) throws -> (request: HTTPRequest, headLength: Int)? {
        guard let end = indexOfHeadTerminator(bytes) else {
            if bytes.count > maxHeadBytes { throw ParseError.headTooLarge }
            return nil
        }
        guard end <= maxHeadBytes else { throw ParseError.headTooLarge }
        guard let head = String(bytes: bytes[0..<end], encoding: .utf8) else {
            throw ParseError.malformedRequestLine
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty,
            parts[1].hasPrefix("/") || parts[1] == "*",
            parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0"
        else { throw ParseError.malformedRequestLine }
        var headers: [HTTPHeader] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
                throw ParseError.malformedHeader
            }
            let name = String(line[..<colon])
            guard !name.contains(" ") else { throw ParseError.malformedHeader }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers.append(HTTPHeader(name, value))
        }
        let request = HTTPRequest(
            method: String(parts[0]), target: String(parts[1]), version: String(parts[2]), headers: headers)
        return (request, end + 4)
    }

    static func indexOfHeadTerminator(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4)
        where bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 {
            return i
        }
        return nil
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [HTTPHeader]
    public var body: [UInt8]

    public init(status: Int, headers: [HTTPHeader] = [], body: [UInt8] = []) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func text(_ status: Int, _ text: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: [HTTPHeader("Content-Type", "text/plain; charset=utf-8")], body: Array(text.utf8))
    }

    public static func json(_ status: Int, _ json: [UInt8]) -> HTTPResponse {
        HTTPResponse(status: status, headers: [HTTPHeader("Content-Type", "application/json")], body: json)
    }

    public static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Content Too Large"
        case 500: "Internal Server Error"
        default: "Status \(status)"
        }
    }

    /// Serializes head and (unless `includeBody` is false, for HEAD) body.
    /// Content-Length always describes the body, as RFC 9110 requires for HEAD.
    public func serialized(includeBody: Bool = true) -> [UInt8] {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for header in headers { head += "\(header.name): \(header.value)\r\n" }
        head += "Content-Length: \(body.count)\r\n\r\n"
        return Array(head.utf8) + (includeBody ? body : [])
    }
}

public enum MIMEType {
    public static func forPath(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        return switch ext {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json", "map": "application/json"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "webp": "image/webp"
        case "ico": "image/x-icon"
        case "woff2": "font/woff2"
        case "woff": "font/woff"
        case "wasm": "application/wasm"
        case "txt": "text/plain; charset=utf-8"
        default: "application/octet-stream"
        }
    }
}

public enum StaticFiles {
    /// Maps a request path to a relative file path under the web root.
    /// "/" becomes "index.html". Returns nil for traversal, hidden files,
    /// backslashes or control characters.
    public static func relativePath(forRequestPath path: String) -> String? {
        guard path.hasPrefix("/"), let decoded = path.removingPercentEncoding else { return nil }
        guard !decoded.contains("\\"), !decoded.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return nil }
        let segments = decoded.split(separator: "/", omittingEmptySubsequences: true)
        guard !segments.contains(where: { $0.hasPrefix(".") }) else { return nil }
        let relative = segments.joined(separator: "/")
        return relative.isEmpty ? "index.html" : relative
    }
}
