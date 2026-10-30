// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import Network
import Synchronization

/// Receives the messages of one WebSocket connection. Callbacks run on the connection's queue.
public protocol WebSocketHandler: AnyObject, Sendable {
    func sessionDidOpen(_ session: WebSocketSession)
    func session(_ session: WebSocketSession, didReceiveText text: String)
    func session(_ session: WebSocketSession, didReceiveBinary data: [UInt8])
    func sessionDidClose(_ session: WebSocketSession)
}

/// One upgraded connection: RFC 6455 framing from FanousCore over the existing TLS connection, a bounded
/// send queue (DESIGN.md §11.2: 256 KB; droppable messages are dropped first, a client that is hopelessly
/// behind is disconnected by the caller), ping/pong and close handling, fragment reassembly.
public final class WebSocketSession: @unchecked Sendable {
    public static let maxQueuedBytes = 256 * 1024
    /// Beyond this a non-droppable send is refused too; the caller then closes the connection.
    public static let hardLimitBytes = 4 * maxQueuedBytes
    public static let maxMessageBytes = 16 * 1024 * 1024

    public let remoteAddress: String
    private let connection: NWConnection
    private let handler: WebSocketHandler
    private let queued = Atomic<Int>(0)
    private let closed = Atomic<Bool>(false)
    private let ended = Atomic<Bool>(false)
    private var fragment: (opcode: WebSocketFrame.Opcode, payload: [UInt8])?

    init(connection: NWConnection, remoteAddress: String, handler: WebSocketHandler) {
        self.connection = connection
        self.remoteAddress = remoteAddress
        self.handler = handler
    }

    public var isClosed: Bool { closed.load(ordering: .relaxed) }

    // MARK: Sending (any thread)

    /// Returns false when the message was not queued: a droppable one above the soft limit, any one above the hard limit.
    @discardableResult
    public func send(text: String, droppable: Bool) -> Bool { send(WebSocketFrame.text(text), droppable: droppable) }

    @discardableResult
    public func send(binary: [UInt8], droppable: Bool) -> Bool { send(WebSocketFrame.binary(binary), droppable: droppable) }

    public func close(code: UInt16 = 1000, reason: String = "") {
        guard !closed.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let frame = WebSocketFrame.close(code: code, reason: reason).serialized()
        connection.send(
            content: Data(frame),
            completion: .contentProcessed { [self] _ in
                connection.cancel()
                connectionDidEnd()
            })
    }

    private func send(_ frame: WebSocketFrame, droppable: Bool) -> Bool {
        guard !isClosed else { return false }
        let bytes = frame.serialized()
        let pending = queued.load(ordering: .relaxed)
        if droppable && pending > Self.maxQueuedBytes { return false }
        if pending > Self.hardLimitBytes { return false }
        queued.add(bytes.count, ordering: .relaxed)
        connection.send(content: Data(bytes), completion: .contentProcessed { [self] _ in queued.subtract(bytes.count, ordering: .relaxed) })
        return true
    }

    // MARK: Receiving (connection queue)

    func opened() { handler.sessionDidOpen(self) }

    /// Consumes every complete frame in `buffer`. Returns false once the connection is closing.
    func feed(_ buffer: inout [UInt8]) -> Bool {
        while !buffer.isEmpty {
            let parsed: (frame: WebSocketFrame, length: Int)?
            do {
                parsed = try WebSocketFrame.parse(buffer, maxPayload: Self.maxMessageBytes)
            } catch {
                close(code: 1002, reason: "protocol error")
                return false
            }
            guard let (frame, length) = parsed else { return true }
            buffer.removeFirst(length)
            switch frame.opcode {
            case .ping:
                _ = send(.pong(frame.payload), droppable: false)
            case .pong:
                break
            case .close:
                close(code: frame.closeCode ?? 1000)
                return false
            case .text, .binary:
                if frame.fin {
                    deliver(frame.opcode, frame.payload)
                } else {
                    fragment = (frame.opcode, frame.payload)
                }
            case .continuation:
                guard var current = fragment else {
                    close(code: 1002, reason: "continuation without start")
                    return false
                }
                current.payload.append(contentsOf: frame.payload)
                guard current.payload.count <= Self.maxMessageBytes else {
                    close(code: 1009, reason: "message too large")
                    return false
                }
                if frame.fin {
                    fragment = nil
                    deliver(current.opcode, current.payload)
                } else {
                    fragment = current
                }
            }
        }
        return true
    }

    /// Idempotent: called from the close path, the receive error path and the connection's cancelled state.
    func connectionDidEnd() {
        closed.store(true, ordering: .relaxed)
        guard !ended.exchange(true, ordering: .acquiringAndReleasing) else { return }
        handler.sessionDidClose(self)
    }

    private func deliver(_ opcode: WebSocketFrame.Opcode, _ payload: [UInt8]) {
        if opcode == .text {
            guard let text = String(bytes: payload, encoding: .utf8) else {
                close(code: 1007, reason: "invalid UTF-8")
                return
            }
            handler.session(self, didReceiveText: text)
        } else {
            handler.session(self, didReceiveBinary: payload)
        }
    }
}
