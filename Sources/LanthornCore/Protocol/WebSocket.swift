// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

/// One RFC 6455 frame. Fragmentation and UTF-8 validation of text messages are the caller's job.
public struct WebSocketFrame: Equatable, Sendable {
    public var fin: Bool
    public var opcode: Opcode
    /// Always the plain (unmasked) payload.
    public var payload: [UInt8]

    public enum Opcode: UInt8, Sendable {
        case continuation = 0
        case text = 1
        case binary = 2
        case close = 8
        case ping = 9
        case pong = 10
    }

    public enum Error: Swift.Error, Equatable {
        /// RSV1-3 set; no extension is negotiated.
        case reservedBits
        case unknownOpcode
        /// Client-to-server frames must be masked (RFC 6455 §5.1).
        case unmaskedClientFrame
        /// Control frames must have fin set and at most 125 payload bytes (§5.5).
        case controlFrameTooLong
        case payloadTooLarge
        /// The 64-bit length form has its most significant bit set (§5.2).
        case badLength
    }

    public init(fin: Bool = true, opcode: Opcode, payload: [UInt8] = []) {
        self.fin = fin
        self.opcode = opcode
        self.payload = payload
    }

    public static func text(_ s: String) -> WebSocketFrame { WebSocketFrame(opcode: .text, payload: Array(s.utf8)) }
    public static func binary(_ b: [UInt8]) -> WebSocketFrame { WebSocketFrame(opcode: .binary, payload: b) }
    public static func pong(_ payload: [UInt8]) -> WebSocketFrame { WebSocketFrame(opcode: .pong, payload: payload) }

    /// A close frame: big-endian status code followed by a UTF-8 reason.
    /// The reason is cut to 123 bytes so the frame stays a legal control frame.
    public static func close(code: UInt16, reason: String = "") -> WebSocketFrame {
        var reason = reason
        while reason.utf8.count > 123 { reason.removeLast() }
        return WebSocketFrame(opcode: .close, payload: [UInt8(code >> 8), UInt8(code & 0xFF)] + Array(reason.utf8))
    }

    /// The status code of a close frame, nil when the payload is shorter than 2 bytes.
    public var closeCode: UInt16? {
        payload.count >= 2 ? UInt16(payload[0]) << 8 | UInt16(payload[1]) : nil
    }

    /// XORs `payload` with the 4-byte key (RFC 6455 §5.3). Masking and unmasking are the same operation.
    public static func mask(_ payload: [UInt8], key: (UInt8, UInt8, UInt8, UInt8)) -> [UInt8] {
        let k = [key.0, key.1, key.2, key.3]
        return payload.enumerated().map { $0.element ^ k[$0.offset & 3] }
    }

    /// Parses one client-to-server frame from the start of `bytes`, returning it unmasked and the bytes consumed.
    /// Returns nil while the frame is incomplete. Header violations throw as soon as the header is
    /// available, so an oversized or malformed frame is rejected before its payload is buffered.
    public static func parse(
        _ bytes: [UInt8], maxPayload: Int = 16 * 1024 * 1024
    ) throws -> (frame: WebSocketFrame, length: Int)? {
        guard bytes.count >= 2 else { return nil }
        let b0 = bytes[0]
        let b1 = bytes[1]
        guard b0 & 0x70 == 0 else { throw Error.reservedBits }
        guard let opcode = Opcode(rawValue: b0 & 0x0F) else { throw Error.unknownOpcode }
        guard b1 & 0x80 != 0 else { throw Error.unmaskedClientFrame }
        let fin = b0 & 0x80 != 0

        var length = Int(b1 & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            guard bytes[2] & 0x80 == 0 else { throw Error.badLength }
            var n: UInt64 = 0
            for i in 2..<10 { n = n << 8 | UInt64(bytes[i]) }
            // The top bit is clear, so n fits in Int on every 64-bit platform we ship to.
            length = Int(n)
            offset = 10
        }
        if opcode.rawValue >= 8, !fin || length > 125 { throw Error.controlFrameTooLong }
        guard length <= maxPayload else { throw Error.payloadTooLarge }

        // Compared by subtraction so a huge `maxPayload` cannot overflow.
        let headerLength = offset + 4
        guard bytes.count >= headerLength, bytes.count - headerLength >= length else { return nil }
        let total = headerLength + length
        let key = (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
        let payload = mask(Array(bytes[(offset + 4)..<total]), key: key)
        return (WebSocketFrame(fin: fin, opcode: opcode, payload: payload), total)
    }

    /// Wire format for server-to-client frames, which are never masked.
    public func serialized() -> [UInt8] { encode(key: nil) }

    /// Wire format for client-to-server frames (masked), for tests and clients.
    public func serializedMasked(key: (UInt8, UInt8, UInt8, UInt8)) -> [UInt8] { encode(key: key) }

    private func encode(key: (UInt8, UInt8, UInt8, UInt8)?) -> [UInt8] {
        var out: [UInt8] = [(fin ? 0x80 : 0) | opcode.rawValue]
        let maskBit: UInt8 = key != nil ? 0x80 : 0
        let n = payload.count
        if n < 126 {
            out.append(maskBit | UInt8(n))
        } else if n <= 0xFFFF {
            out += [maskBit | 126, UInt8(n >> 8), UInt8(n & 0xFF)]
        } else {
            out.append(maskBit | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8(truncatingIfNeeded: UInt64(n) >> UInt64(shift)))
            }
        }
        if let key {
            out += [key.0, key.1, key.2, key.3]
            out += Self.mask(payload, key: key)
        } else {
            out += payload
        }
        return out
    }
}

/// The server side of the RFC 6455 §4 opening handshake.
public enum WebSocketHandshake {
    private static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// `Sec-WebSocket-Accept` for a client's `Sec-WebSocket-Key` (§4.2.2).
    public static func acceptKey(for clientKey: String) -> String {
        Data(SHA1.hash(Array((clientKey + guid).utf8))).base64EncodedString()
    }

    public static func isUpgrade(_ request: HTTPRequest) -> Bool {
        request.method == "GET"
            && request.version == "HTTP/1.1"
            && hasToken(request, "Upgrade", "websocket")
            && hasToken(request, "Connection", "upgrade")
            && request.header("Sec-WebSocket-Version") == "13"
            && !(request.header("Sec-WebSocket-Key") ?? "").isEmpty
    }

    /// The 101 response, or nil when `request` is not a WebSocket upgrade.
    public static func response(for request: HTTPRequest) -> HTTPResponse? {
        guard isUpgrade(request), let key = request.header("Sec-WebSocket-Key") else { return nil }
        return HTTPResponse(
            status: 101,
            headers: [
                HTTPHeader("Upgrade", "websocket"),
                HTTPHeader("Connection", "Upgrade"),
                HTTPHeader("Sec-WebSocket-Accept", acceptKey(for: key)),
            ])
    }

    /// True when any `name` header (repeated headers allowed) lists `token` in its comma-separated value, case-insensitively.
    private static func hasToken(_ request: HTTPRequest, _ name: String, _ token: String) -> Bool {
        request.headers.contains { header in
            header.name.caseInsensitiveCompare(name) == .orderedSame
                && header.value.split(separator: ",").contains {
                    $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(token) == .orderedSame
                }
        }
    }
}
