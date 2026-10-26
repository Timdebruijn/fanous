// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Synchronization

/// Keeps the rendered canvas in step with the project's (B31). The project can change on any thread (canvas.set,
/// undo/redo, project load); the switch runs on the main actor, one at a time, and waits while `isDeferred` (show
/// mode) says so: call `run()` again when that ends. A failed switch keeps the old canvas, hands it to `revert`
/// (which puts it back into the project) and keeps the error for `live.canvas`.
final class CanvasSwitch: @unchecked Sendable {
    struct State: Sendable {
        var rendered: ProjectDocument.CanvasFormat
        var wanted: ProjectDocument.CanvasFormat
        var applying = false
        var error: String?
    }

    private let state: Mutex<State>
    private let isDeferred: @Sendable () -> Bool
    private let apply: @MainActor (ProjectDocument.CanvasFormat) throws -> Void
    private let revert: @MainActor (ProjectDocument.CanvasFormat, any Error) -> Void
    /// After a switch, with `rendered` already updated (previews, caps, display-mode checks follow it).
    nonisolated(unsafe) var applied: (@MainActor (ProjectDocument.CanvasFormat) -> Void)?

    init(
        rendered: ProjectDocument.CanvasFormat, isDeferred: @escaping @Sendable () -> Bool, apply: @escaping @MainActor (ProjectDocument.CanvasFormat) throws -> Void,
        revert: @escaping @MainActor (ProjectDocument.CanvasFormat, any Error) -> Void
    ) {
        state = Mutex(State(rendered: rendered, wanted: rendered))
        self.isDeferred = isDeferred
        self.apply = apply
        self.revert = revert
    }

    var rendered: ProjectDocument.CanvasFormat { state.withLock { $0.rendered } }

    /// The project's canvas, from `projectChanged` (an invalid one is ignored by the caller).
    func request(_ format: ProjectDocument.CanvasFormat) {
        state.withLock { $0.wanted = format }
        run()
    }

    func run() {
        guard !isDeferred() else { return }
        let next: ProjectDocument.CanvasFormat? = state.withLock { s in
            guard !s.applying, s.wanted != s.rendered else { return nil }
            s.applying = true
            return s.wanted
        }
        guard let format = next else { return }
        Task { @MainActor in
            do {
                try apply(format)
                state.withLock {
                    $0.rendered = format
                    $0.error = nil
                }
                applied?(format)
            } catch {
                let rendered = state.withLock { s in
                    s.error = "\(format.width) × \(format.height) at \(String(format: "%g", format.fps)) fps: \(error)"
                    s.wanted = s.rendered
                    return s.rendered
                }
                revert(rendered, error)
            }
            state.withLock { $0.applying = false }
            run()  // another change may have arrived meanwhile
        }
    }

    /// `live.canvas`: what renders, whether the project asks for another canvas (show mode defers it), the last failure.
    var live: JSONValue {
        let s = state.withLock { $0 }
        return [
            "width": .number(Double(s.rendered.width)), "height": .number(Double(s.rendered.height)), "fps": .number(s.rendered.fps),
            "pending": .bool(s.wanted != s.rendered), "error": s.error.map(JSONValue.string) ?? .null,
        ]
    }
}
