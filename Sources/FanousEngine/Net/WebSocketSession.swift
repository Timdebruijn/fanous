// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import Network
import Synchronization

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
    /// Gets the session's open, text messages and close, on the connection's queue.
    private let handler: StateServer.Connection
    private let queued = Atomic<Int>(0)
    /// The part of `queued` that is welcomes and snapshots (`send(document:)`).
    private let documentBytes = Atomic<Int>(0)
    private let closed = Atomic<Bool>(false)
    private let ended = Atomic<Bool>(false)
    private var fragment: (opcode: WebSocketFrame.Opcode, payload: [UInt8])?
    /// `maxMessageBytes`; a test passes a small one so it need not build 16 MB frames (B353).
    private let messageLimit: Int

    init(connection: NWConnection, remoteAddress: String, handler: StateServer.Connection, messageLimit: Int = maxMessageBytes) {
        self.connection = connection
        self.remoteAddress = remoteAddress
        self.handler = handler
        self.messageLimit = messageLimit
    }

    public var isClosed: Bool { closed.load(ordering: .relaxed) }

    // MARK: Sending (any thread)

    /// Returns false when the message was not queued: a droppable one above the soft limit, any one above the hard limit.
    @discardableResult
    public func send(text: String, droppable: Bool) -> Bool { send(WebSocketFrame.text(text), droppable: droppable) }

    @discardableResult
    public func send(binary: [UInt8], droppable: Bool) -> Bool { send(WebSocketFrame.binary(binary), droppable: droppable) }

    /// A welcome or snapshot (B286): queued like any message, but the limits for what follows it leave it out, so a
    /// 1.6 MB document does not make the patches right behind it look like a client that cannot keep up (they went out
    /// in the same control-queue turn, before any byte of the document could leave). Refused above the hard limit of
    /// everything queued, earlier documents included; patches and streams after it still meet both limits.
    public func send(document text: String) -> Bool { send(WebSocketFrame.text(text), droppable: false, document: true) }

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

    /// An empty ping, which a client's WebSocket answers with a pong by itself: how the server tells a quiet client from a
    /// dead one (B269).
    func ping() { _ = send(WebSocketFrame(opcode: .ping), droppable: false) }

    private func send(_ frame: WebSocketFrame, droppable: Bool, document: Bool = false) -> Bool {
        guard !isClosed else { return false }
        let bytes = frame.serialized()
        let pending = queued.load(ordering: .relaxed) - documentBytes.load(ordering: .relaxed)
        if droppable && pending > Self.maxQueuedBytes { return false }
        if pending > Self.hardLimitBytes { return false }
        // a document is judged against everything queued, earlier documents included: at most one large one in flight
        // (the web client never has two), so a client that asks for snapshots and never reads is refused, then dropped
        if document && queued.load(ordering: .relaxed) > Self.hardLimitBytes { return false }
        queued.add(bytes.count, ordering: .relaxed)
        if document { documentBytes.add(bytes.count, ordering: .relaxed) }
        connection.send(
            content: Data(bytes),
            completion: .contentProcessed { [self] _ in
                queued.subtract(bytes.count, ordering: .relaxed)  // first: in between, `pending` errs low, never high
                if document { documentBytes.subtract(bytes.count, ordering: .relaxed) }
            })
        return true
    }

    // MARK: Receiving (connection queue)

    func opened() { handler.sessionDidOpen(self) }

    /// Consumes every complete frame in `buffer`. Returns false once the connection is closing.
    func feed(_ buffer: inout [UInt8]) -> Bool {
        while !buffer.isEmpty {
            let parsed: (frame: WebSocketFrame, length: Int)?
            do {
                parsed = try WebSocketFrame.parse(buffer, maxPayload: messageLimit)
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
                // RFC 6455 §5.4: no new data frame while a fragmented message is open
                guard fragment == nil else {
                    close(code: 1002, reason: "new message inside a fragmented one")
                    return false
                }
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
                guard current.payload.count <= messageLimit else {
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
        guard opcode == .text else { return }  // no client → server binary streams in v1
        guard let text = String(bytes: payload, encoding: .utf8) else {
            close(code: 1007, reason: "invalid UTF-8")
            return
        }
        handler.session(self, didReceiveText: text)
    }
}
