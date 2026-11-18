// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Logging
import Network
import Synchronization

/// An `NWListener` that is made again when it fails (B272). `.failed` is terminal: "irrecoverably closed or failed",
/// and states "progress forward and do not move backwards" (Network.framework, `listener.h`); a listener that failed
/// on a port another program held stays failed after that program quits (measured). On `.failed` the dead listener is
/// cancelled and, after a wait (`backoff`), `make` builds a new one with the same parameters on the same port; that
/// repeats until one gets ready. `.waiting` ("waiting for a usable network") is left alone: that listener goes on to
/// ready by itself once the network is there, and a new one would only wait the same way. One log line per change of
/// outcome (failed with another error, waiting, listening again), not one per attempt. After `start()` everything runs
/// on `queue`, the listener's own.
final class RecoveringListener: @unchecked Sendable {
    /// Seconds before attempt n (from 0): `first` doubled n times, at most `max`. 1, 2, 4, then every 5 s: a listener
    /// that can come back is there within 5 s of its cause going away (the console's Art-Net is lost meanwhile), and an
    /// attempt costs one socket, so 12 a minute cost nothing. Tests set it before `start()`.
    var backoff = (first: 1.0, max: 5.0)
    /// "Art-Net listener", "OSC UDP": the start of every line logged.
    private let name: String
    private let queue: DispatchQueue
    private let logger: Logger
    private let make: () throws -> NWListener
    /// Every state of the current listener, after this type's own handling (on `queue`).
    private let onState: (NWListener.State, NWListener) -> Void
    private let current = Mutex<NWListener?>(nil)
    private let problem = Mutex<String?>(nil)
    /// `queue` only.
    private var attempts = 0
    private var logged: String?
    private var retry: DispatchWorkItem?
    private var stopped = false

    init(
        name: String, queue: DispatchQueue, logger: Logger, make: @escaping () throws -> NWListener,
        onState: @escaping (NWListener.State, NWListener) -> Void = { _, _ in }
    ) {
        self.name = name
        self.queue = queue
        self.logger = logger
        self.make = make
        self.onState = onState
    }

    /// The listener in use; nil while a failed one waits for its next attempt.
    var listener: NWListener? { current.withLock { $0 } }

    /// Why nothing listens (failed and trying again, or waiting for a network), for readiness; nil while it listens.
    var failure: String? { problem.withLock { $0 } }

    func start() throws { try open() }

    /// Cancels the listener and any attempt still to come. From any thread, also from inside `queue` (it only
    /// dispatches); from then on only `.cancelled` reaches `onState`.
    func stop() {
        queue.async { [self] in
            stopped = true
            retry?.cancel()
            retry = nil
            current.withLock { $0 }?.cancel()
        }
    }

    private func open() throws {
        let listener = try make()
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            stateChanged(state, of: listener)
        }
        current.withLock { $0 = listener }
        listener.start(queue: queue)
    }

    /// The listener's state handler, on `queue`. Tests hand it a `.failed` they cannot cause on a ready listener.
    func stateChanged(_ state: NWListener.State, of listener: NWListener) {
        guard listener === current.withLock({ $0 }) else { return }  // a failed one's own `.cancelled`
        // a `.ready` queued before the stop (an attempt that ran just before it) must not start a beacon or a Bonjour
        // registration that nothing cancels any more
        guard !stopped else {
            if case .cancelled = state { onState(state, listener) }
            return
        }
        switch state {
        case .ready:
            attempts = 0
            logged = nil
            problem.withLock { $0 = nil }
        case .waiting(let error):
            report(error, "\(name) waiting for a usable network", problem: "waiting for a usable network: \(error)", level: .warning)
        case .failed(let error):
            listener.cancel()
            current.withLock { $0 = nil }
            failed(error)
        default: break
        }
        onState(state, listener)
    }

    private func failed(_ error: any Error) {
        report(error, "\(name) failed; trying again", problem: "\(error), trying again", level: .error)
        scheduleRetry()
    }

    /// Readiness reads `problem`; the line is logged only when it differs from the last one.
    private func report(_ error: any Error, _ message: String, problem: String, level: Logger.Level) {
        self.problem.withLock { $0 = problem }
        guard logged != "\(message) \(error)" else { return }
        logged = "\(message) \(error)"
        logger.log(level: level, "\(message)", metadata: ["error": "\(error)", "retry": "\(String(format: "every %g s at most", backoff.max))"])
    }

    private func scheduleRetry() {
        guard !stopped else { return }
        let delay = min(backoff.first * pow(2, Double(attempts)), backoff.max)
        attempts = min(attempts + 1, 30)
        let item = DispatchWorkItem { [weak self] in
            guard let self, !stopped else { return }
            retry = nil
            do {
                try open()
            } catch {
                failed(error)
            }
        }
        retry = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
