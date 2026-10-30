// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Logging
import Metal
import Synchronization
import Testing

@testable import FanousEngine

/// The edit overlay (DESIGN.md §9.10 item 4): its lease, the lines it builds and `output.overlay`. The drawing is in
/// `OutputPassTests`.
@MainActor
struct EditOverlayTests {
    static func segments(_ lines: EditOverlay.Lines?) -> [OverlaySegment] {
        guard let lines else { return [] }
        return Array(UnsafeBufferPointer(start: lines.buffer.contents().assumingMemoryBound(to: OverlaySegment.self), count: lines.count))
    }

    /// Where the selection's crosshair is drawn (before the warp), nil when there is none.
    static func selectedPoint(_ lines: EditOverlay.Lines?) -> SIMD2<Float>? { segments(lines).first { $0.flags & 1 != 0 }?.a }

    /// Start, renewal, expiry 5 s after the last renewal, the latest selection wins, off and show mode or lock end it.
    @Test func theLeaseRunsFiveSecondsFromItsLastRenewal() throws {
        let overlay = EditOverlay(device: try #require(MTLCreateSystemDefaultDevice()))
        let config = OutputConfig(id: 1)
        #expect(overlay.lines(1, at: 100) == nil && !overlay.asked(1, at: 100), "none before a lease")
        overlay.lease(1, on: true, selected: OverlaySelection(kind: .corner, point: 0), config: config, at: 100)
        #expect(overlay.lines(1, at: 104.9) != nil && overlay.asked(1, at: 104.9))
        #expect(overlay.lines(1, at: 105) == nil && !overlay.asked(1, at: 105), "5 s after it was taken")
        #expect(overlay.lines(2, at: 101) == nil, "per output")

        let first = try #require(overlay.lines(1, at: 101))
        overlay.lease(1, on: true, selected: OverlaySelection(kind: .corner, point: 0), config: config, at: 103)
        #expect(overlay.lines(1, at: 107.9) != nil && overlay.lines(1, at: 108) == nil, "renewed at 103: until 108")
        #expect(overlay.lines(1, at: 104)?.buffer === first.buffer, "a renewal with the same selection keeps the lines")
        #expect(Self.selectedPoint(first) == SIMD2(0, 0))

        overlay.lease(1, on: true, selected: OverlaySelection(kind: .corner, point: 2), config: config, at: 104)
        #expect(Self.selectedPoint(overlay.lines(1, at: 104)) == SIMD2(1, 1), "the latest call's selection")
        overlay.lease(1, on: true, selected: nil, config: config, at: 104.5)
        #expect(overlay.lines(1, at: 105) != nil && Self.selectedPoint(overlay.lines(1, at: 105)) == nil, "no selection: lines only")

        overlay.lease(1, on: false, selected: nil, config: config, at: 105)
        #expect(overlay.lines(1, at: 105) == nil && !overlay.asked(1, at: 105), "off ends it")
        overlay.lease(1, on: true, selected: nil, config: nil, at: 106)
        #expect(overlay.lines(1, at: 106) == nil, "an output that is gone draws nothing")

        overlay.lease(1, on: true, selected: nil, config: config, at: 110)
        overlay.lease(2, on: true, selected: nil, config: OutputConfig(id: 2), at: 110)
        overlay.endAll()
        #expect(overlay.lines(1, at: 110) == nil && overlay.lines(2, at: 110) == nil, "show mode and show lock end every lease")
    }

    /// An edit rebuilds a running lease's lines from the new mapping with its selection; one that ran out, or whose
    /// output went, is dropped. A selection the new mapping lacks draws none.
    @Test func anEditRebuildsTheRunningLeases() throws {
        let overlay = EditOverlay(device: try #require(MTLCreateSystemDefaultDevice()))
        var config = OutputConfig(id: 1)
        config.slices.append(SliceConfig(id: 2))
        overlay.lease(1, on: true, selected: OverlaySelection(slice: 1, kind: .slice, point: 1), config: config, at: 100)
        overlay.lease(2, on: true, selected: nil, config: OutputConfig(id: 2), at: 90)
        #expect(Self.selectedPoint(overlay.lines(1, at: 101)) == SIMD2(1, 0))
        config.slices[1].dest[1] = MapPoint(0.8, 0.1)
        overlay.rebuild([config, OutputConfig(id: 2)], at: 101)
        #expect(Self.selectedPoint(overlay.lines(1, at: 101)) == SIMD2(0.8, 0.1), "the moved corner")
        #expect(Self.segments(overlay.lines(1, at: 101)).contains { $0.a == SIMD2(0.8, 0.1) && $0.flags == 0 }, "slice 2's outline from it")
        #expect(overlay.lines(1, at: 104.9) != nil && overlay.lines(1, at: 105) == nil, "the lease keeps its end")
        config.slices.removeLast()
        overlay.rebuild([config], at: 102)
        #expect(overlay.lines(1, at: 102) != nil && Self.selectedPoint(overlay.lines(1, at: 102)) == nil, "slice 2 went: no selection, the lines stay")
        overlay.lease(2, on: true, selected: nil, config: OutputConfig(id: 2), at: 102)
        overlay.rebuild([config], at: 103)
        #expect(!overlay.asked(2, at: 103), "output 2 went")
    }

    /// What the overlay draws: the corner pin's edges or the mesh's grid lines, 64 pieces each, every slice's outline (64
    /// per edge) and its mask's (at most 1/64 of the output per piece), then the selection. Capped at 16,384 segments.
    @Test func theLinesOfAMapping() {
        var o = OutputConfig(id: 1)
        #expect(EditOverlay.segments(o, selected: nil).count == 4 * 64 + 4 * 64, "corner pin edges and slice 1")
        o.warp.mesh = .identity(cols: 3, rows: 5)
        o.slices[0].mask = MaskSettings(path: [MapPoint(0.125, 0.125), MapPoint(0.625, 0.125), MapPoint(0.125, 0.375)], feather: 0)
        let lines = EditOverlay.segments(o, selected: nil)
        #expect(lines.count == 8 * 64 + 4 * 64 + (32 + 32 + 16), "5 rows and 3 columns of the mesh, slice 1, its mask")
        #expect(lines.first == OverlaySegment(a: SIMD2(0, 0), b: SIMD2(1.0 / 64, 0)) && lines[4 * 64].a == SIMD2(0, 1), "row by row from the top")
        #expect(lines.allSatisfy { $0.flags == 0 && $0.offsetA == .zero && $0.offsetB == .zero }, "no selection")

        // r3 c5 of a 33 × 33 mesh: "3·5" is 3 (five segments), the dot and 5 (five), after four arms
        o.warp.mesh = .identity(cols: 33, rows: 33)
        let mark = EditOverlay.segments(o, selected: OverlaySelection(kind: .mesh, point: 2 * 33 + 4)).filter { $0.flags & 1 != 0 }
        #expect(mark.count == 4 + 5 + 1 + 5 && mark.filter { $0.flags == 3 }.count == 4, "\(mark.count)")
        #expect(mark.allSatisfy { $0.a == SIMD2(4.0 / 32, 2.0 / 32) && $0.b == $0.a }, "at the point before the warp, offsets in pixels")
        #expect(mark.contains { $0.offsetA == $0.offsetB }, "the dot")
        for wrong in [
            OverlaySelection(kind: .mesh, point: 33 * 33), OverlaySelection(kind: .corner, point: 4), OverlaySelection(slice: 1, kind: .slice, point: 0),
            OverlaySelection(kind: .mask, mask: 1, point: 0), OverlaySelection(kind: .mask, point: 3),
        ] {
            #expect(EditOverlay.mark(o, wrong) == nil, "\(wrong)")
        }
        #expect(EditOverlay.mark(o, OverlaySelection(kind: .mask, point: 2))?.first?.a == SIMD2(0.125, 0.375))

        // a mask of 15,000 points beside a 33 × 33 mesh: past the cap its last edges go; the selection (four arms and
        // a 2 of five segments) stays, last
        o.slices[0].mask = MaskSettings(path: (0..<15000).map { MapPoint(0.5 + 0.4 * cos(Double($0) * 2 * .pi / 15000), 0.5 + 0.4 * sin(Double($0) * 2 * .pi / 15000)) }, feather: 0)
        let capped = EditOverlay.segments(o, selected: OverlaySelection(kind: .corner, point: 1))
        #expect(capped.count == EditOverlay.maxSegments && capped.suffix(9).allSatisfy { $0.flags & 1 != 0 } && capped[capped.count - 10].flags == 0)
    }

    /// Nothing bounds a point's coordinates (`output.set`, a hand-edited file): a mask point at 1e19 does not trap the piece
    /// count, and a mask whose every other point is at 1e7 stops at the cap instead of building millions of segments
    /// first. The selection is drawn in both.
    @Test func farOffPointsStopAtTheCap() {
        var o = OutputConfig(id: 1)
        o.slices[0].mask = MaskSettings(path: [MapPoint(0, 0), MapPoint(1e19, 0), MapPoint(0, 1)], feather: 0)
        let huge = EditOverlay.segments(o, selected: OverlaySelection(kind: .corner, point: 0))
        #expect(huge.count == EditOverlay.maxSegments && huge.suffix(6).allSatisfy { $0.flags & 1 != 0 }, "four arms and a 1")
        o.slices[0].mask = MaskSettings(path: (0..<1000).map { $0.isMultiple(of: 2) ? MapPoint(0, 0) : MapPoint(1e7, 1e7) }, feather: 0)
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let far = EditOverlay.segments(o, selected: OverlaySelection(kind: .corner, point: 0))
        let ms = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e6
        #expect(far.count == EditOverlay.maxSegments && far.suffix(6).allSatisfy { $0.flags & 1 != 0 })
        #expect(ms < 100, "\(ms) ms of CPU")
    }

    // MARK: output.overlay

    final class Machine: Sendable {
        let showMode = Mutex(false)
        let calls = Mutex<[(Int, Bool, OverlaySelection?)]>([])
    }

    static func makeStore() throws -> (StateStore, Machine) {
        let logger = Logger(label: "test")
        let store = StateStore(project: ProjectDocument.initial(patch: .standard(layers: 2, outputs: 1), layerCount: 2, libraryRoot: "/tmp/lib", policy: .dmx), logger: logger)
        let machine = Machine()
        ProjectDocument.registerCommands(
            on: store, auth: RoleAuth(settingsURL: nil, shellTokenURL: nil, iterations: 1000, logger: logger), showModeOn: { machine.showMode.withLock { $0 } },
            showOverlay: { id, on, selected in machine.calls.withLock { $0.append((id, on, selected)) } })
        _ = try store.execute("output.add", role: .programmer).get()
        return (store, machine)
    }

    /// A lease, not an edit: no project change and no undo step; the selection reaches the coordinator as sent.
    @Test func theCommandIsALease() throws {
        let (store, machine) = try Self.makeStore()
        let (rev, depth) = (store.rev, store.historyDepth.undo)
        _ = try store.execute("output.overlay", args: ["id": 1, "on": true, "selected": ["slice": 0, "kind": "mesh", "point": 7]], role: .programmer).get()
        _ = try store.execute("output.overlay", args: ["id": 1, "on": true, "selected": ["slice": 1, "kind": "mask", "mask": 0, "point": 2]], role: .programmer).get()
        _ = try store.execute("output.overlay", args: ["id": 1, "on": true, "selected": .null], role: .programmer).get()
        _ = try store.execute("output.overlay", args: ["id": 1, "on": false], role: .programmer).get()
        let calls = machine.calls.withLock { $0 }
        #expect(calls.map(\.0) == [1, 1, 1, 1] && calls.map(\.1) == [true, true, true, false])
        #expect(calls.map(\.2) == [OverlaySelection(kind: .mesh, point: 7), OverlaySelection(slice: 1, kind: .mask, point: 2), nil, nil])
        #expect(store.rev == rev && store.historyDepth.undo == depth, "not saved, not undone")
    }

    /// Programmer only; refused under show lock (ending too: the lock ended it), in show mode except to end, for an output
    /// that does not exist (ending one is fine) and for a selection of the wrong shape.
    @Test func refusals() throws {
        let (store, machine) = try Self.makeStore()
        func run(_ args: JSONValue, role: Role = .programmer) -> Result<CommandResult, CommandError> { store.execute("output.overlay", args: args, role: role) }
        #expect(run(["id": 1, "on": true], role: .operator) == .failure(.forbidden))
        #expect(run(["id": 7, "on": true]) == .failure(.invalidArgs("no output 7")))
        #expect((try? run(["id": 7, "on": false]).get()) != nil, "ending one of an output that is gone")
        for selected in [
            ["slice": 0, "kind": "edge", "point": 0], ["slice": 0, "kind": "mesh", "point": -1], ["slice": 0, "kind": "mesh", "point": 1.5],
            ["kind": "corner", "point": 0], ["slice": 0, "kind": "mask", "mask": "x", "point": 0], ["slice": 0, "kind": "mask", "mask": -1, "point": 0],
        ] as [JSONValue] {
            if case .failure(let error) = run(["id": 1, "on": true, "selected": selected]) { #expect(error.code == "invalidArgs", "\(selected)") } else { Issue.record("accepted \(selected)") }
        }
        #expect(run(["id": 1]) == .failure(.invalidArgs("args: { id, on, selected? }")))
        machine.showMode.withLock { $0 = true }
        #expect(run(["id": 1, "on": true]) == .failure(CommandError("showMode", "the edit overlay is off in show mode")), "show mode ends it, so it cannot start")
        #expect((try? run(["id": 1, "on": false]).get()) != nil, "ending is fine")
        machine.showMode.withLock { $0 = false }
        _ = try store.execute("show.lock", role: .programmer).get()
        #expect(run(["id": 1, "on": true]) == .failure(.showLocked) && run(["id": 1, "on": false]) == .failure(.showLocked))
        #expect(machine.calls.withLock { $0.map(\.1) } == [false, false], "only the two endings got through")
    }

    /// `live.outputs[].overlay`: null without a lease, "shown", or why not: a preset or a morph from one shows, or Raw. A
    /// number the output lacks shows the edited mapping, and the overlay.
    @Test func liveSaysWhyTheOverlayIsHidden() {
        var o = OutputConfig(id: 1)
        o.storePreset(2, name: nil)
        func live(asked: Bool = true, raw: Bool = false, _ number: Int = 0, from: UInt8 = 0, fade: Double = 0) -> JSONValue {
            Engine.overlayLive(asked: asked, raw: raw, preset: Engine.presetLive((number, false, PresetMorph(from: from, start: 10, fade: fade)), config: o, at: 11))
        }
        #expect(live(asked: false, 2) == .null && live() == "shown")
        #expect(live(2) == "preset" && live(0, from: 2, fade: 2) == "preset", "a preset, a morph from one")
        #expect(live(9) == "shown" && live(0, from: 9, fade: 2) == "shown", "a missing number draws the edited mapping")
        #expect(live(raw: true) == "raw")
    }
}
