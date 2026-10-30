// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Synchronization

/// Runs `body` (AVFoundation's async loads) and blocks the calling thread until it is done. Only from a plain thread
/// (the loader, ingest and library threads), never a cooperative one: with the pool full of tasks parked here, `body`
/// never gets a thread (B63).
func blockingAwait<T: Sendable>(priority: TaskPriority = .utility, _ body: @escaping @Sendable () async throws -> T) throws -> T {
    let done = DispatchSemaphore(value: 0)
    let box = Mutex<Result<T, Error>?>(nil)
    Task.detached(priority: priority) {
        let result: Result<T, Error>
        do { result = .success(try await body()) } catch { result = .failure(error) }
        box.withLock { $0 = result }
        done.signal()
    }
    done.wait()
    return try box.withLock { $0 }!.get()
}

extension DispatchSource {
    /// A running timer that calls `handler` on `queue` every `interval` seconds, the first time one interval from now.
    static func repeating(every interval: Double, on queue: DispatchQueue, _ handler: @escaping DispatchSourceHandler) -> DispatchSourceTimer {
        let timer = makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }
}
