// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Synchronization

/// Keeps the rendered canvases in step with the project's (B31; canvas.add/remove/set). The project can change on any
/// thread (canvas commands, undo/redo, project load); the switch runs on the main actor, one at a time, and waits while
/// `isDeferred` (show mode) says so: call `run()` again when that ends. A failed switch keeps the old canvases, hands
/// them to `revert` (which puts them back into the project) and keeps the error for `live.canvas`.
final class CanvasSwitch: @unchecked Sendable {
    typealias Layout = ProjectDocument.CanvasLayout
    struct State: Sendable {
        var rendered: Layout
        var wanted: Layout
        var applying = false
        var error: String?
    }

    private let state: Mutex<State>
    private let isDeferred: @Sendable () -> Bool
    private let apply: @MainActor (Layout) throws -> Void
    private let revert: @MainActor (Layout, any Error) -> Void
    /// After a switch, with `rendered` already updated (previews, caps, display-mode checks follow it).
    nonisolated(unsafe) var applied: (@MainActor (Layout) -> Void)?

    init(
        rendered: Layout, isDeferred: @escaping @Sendable () -> Bool, apply: @escaping @MainActor (Layout) throws -> Void,
        revert: @escaping @MainActor (Layout, any Error) -> Void
    ) {
        state = Mutex(State(rendered: rendered, wanted: rendered))
        self.isDeferred = isDeferred
        self.apply = apply
        self.revert = revert
    }

    var rendered: Layout { state.withLock { $0.rendered } }

    /// The project's canvases could not be made at start: `rendering` is what runs, `live.canvas` shows the error.
    func startFailed(rendering: Layout, error: String) {
        state.withLock {
            $0.rendered = rendering
            $0.wanted = rendering
            $0.error = error
        }
    }

    /// The project's canvases, from `projectChanged` (`ProjectDocument.layout`, invalid ones already dropped).
    func request(_ layout: Layout) {
        state.withLock { $0.wanted = layout }
        run()
    }

    func run() {
        guard !isDeferred() else { return }
        let next: Layout? = state.withLock { s in
            guard !s.applying, s.wanted != s.rendered else { return nil }
            s.applying = true
            return s.wanted
        }
        guard let layout = next else { return }
        Task { @MainActor in
            do {
                try apply(layout)
                state.withLock {
                    $0.rendered = layout
                    $0.error = nil
                }
                applied?(layout)
            } catch {
                let rendered = state.withLock { s in
                    let sizes = layout.canvases.map { "\($0.width) × \($0.height)" }.joined(separator: ", ")
                    s.error = "\(sizes) at \(String(format: "%g", layout.fps)) fps: \(error)"
                    s.wanted = s.rendered
                    return s.rendered
                }
                revert(rendered, error)
            }
            state.withLock { $0.applying = false }
            run()  // another change may have arrived meanwhile
        }
    }

    /// `live.canvas`: what renders (canvas 1's size and the shared rate, plus every canvas), whether the project asks
    /// for other canvases (show mode defers it), the last failure.
    var live: JSONValue {
        let s = state.withLock { $0 }
        let first = s.rendered.first
        return [
            "width": .number(Double(first.width)), "height": .number(Double(first.height)), "fps": .number(s.rendered.fps),
            "canvases": .array(s.rendered.canvases.map { ["id": .number(Double($0.id)), "width": .number(Double($0.width)), "height": .number(Double($0.height))] }),
            "pending": .bool(s.wanted != s.rendered), "error": s.error.map(JSONValue.string) ?? .null,
        ]
    }
}
