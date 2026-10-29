// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Testing

@testable import FanousEngine

/// The engine half of the RFC 6455 handshake: the accept key (CryptoKit SHA-1) and the 101 response.
@Suite struct WebSocketHandshakeTests {
    private func request(_ raw: String) throws -> HTTPRequest {
        try #require(try HTTPRequest.parse(Array(raw.utf8))).request
    }

    @Test func acceptKeyMatchesRFCExample() {
        #expect(WebSocketHandshake.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test func upgradeProducesA101WithoutContentLength() throws {
        let head =
            "GET /ws HTTP/1.1\r\nHost: a\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
        let response = try #require(WebSocketHandshake.response(for: try request(head)))
        #expect(response.status == 101)
        let wire = String(decoding: response.serialized(), as: UTF8.self)
        #expect(
            wire == "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n")
        #expect(!wire.lowercased().contains("content-length"))
    }

    @Test func noResponseWithoutAnUpgrade() throws {
        #expect(WebSocketHandshake.response(for: try request("GET /ws HTTP/1.1\r\nHost: a\r\n\r\n")) == nil)
    }
}
