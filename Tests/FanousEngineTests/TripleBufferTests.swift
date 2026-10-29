// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Logging
import Synchronization
import Testing
import simd

@testable import FanousEngine

final class Box { var value = 0 }

@Suite struct TripleBufferTests {
    @Test func readerSeesTheLatestWriteAndKeepsItWhenNothingIsNew() {
        let buffer = TripleBuffer { Box() }
        #expect(buffer.read().value == 0)
        buffer.write { $0.value = 1 }
        buffer.write { $0.value = 2 }
        #expect(buffer.read().value == 2)
        #expect(buffer.read().value == 2)
        buffer.write { $0.value = 3 }
        #expect(buffer.read().value == 3)
    }

    @Test func writerNeverTouchesTheSlotTheReaderHolds() {
        let buffer = TripleBuffer { Box() }
        buffer.write { $0.value = 10 }
        let held = buffer.read()
        for i in 0..<100 { buffer.write { $0.value = i } }  // many writes while the reader keeps its slot
        #expect(held.value == 10)
        #expect(buffer.read().value == 99)
    }

    @Test func concurrentWriterAndReaderNeverTear() async {
        final class Pair { var a = 0; var b = 0 }
        let buffer = TripleBuffer { Pair() }
        let writer = Task.detached {
            for i in 1...50_000 { buffer.write { $0.a = i; $0.b = -i } }
        }
        var torn = 0
        for _ in 0..<50_000 {
            let p = buffer.read()
            if p.a != -p.b { torn += 1 }
        }
        await writer.value
        #expect(torn == 0)
        #expect(buffer.read().a == 50_000)
    }

    // MARK: Readers other than the render reader (B71)

    @Test func copyReaderLeavesTheNewFlagToTheRenderReader() {
        let buffer = TripleBuffer({ Box() }, copy: { $0.value = $1.value })
        let held = buffer.read()
        buffer.write { $0.value = 1 }
        #expect(buffer.withLatest { $0.value } == 1)
        let next = buffer.read()
        #expect(next !== held)  // the render reader took the new slot itself
        #expect(next.value == 1)
    }

    @Test func copyReaderNeverHandsTheWriterTheRenderReadersSlot() {
        let buffer = TripleBuffer({ Box() }, copy: { $0.value = $1.value })
        let held = buffer.read()
        buffer.write { $0.value = 1 }
        _ = buffer.withLatest { $0.value }  // with `read()` here, the third write below lands in `held`
        for i in 2...4 { buffer.write { $0.value = i } }
        #expect(held.value == 0)
        #expect(buffer.withLatest { $0.value } == 4)
        #expect(buffer.read().value == 4)
    }

    @Test func currentKeepsTheTicksSlotAndLeavesTheNewFlag() {
        let buffer = TripleBuffer { Box() }
        let held = buffer.read()
        buffer.write { $0.value = 1 }
        #expect(buffer.current() === held)  // a second `read()` here would take the new slot and free `held` to the writer
        for i in 2...4 { buffer.write { $0.value = i } }
        #expect(held.value == 0)
        #expect(buffer.read().value == 4)
    }

    @Test func dmxCopyEqualsTheLastPublishedSlot() {
        let store = DMXStore(patch: .standard(layers: 2, outputs: 1), logger: Logger(label: "test"))
        for i in 1...3 {
            store.snapshots.write { slot in
                slot.sequence = UInt64(i)
                slot.receivedAt = Double(i)
                slot.master = Float(i) / 10
                slot.testPattern = i == 2 ? .grid : .off
                slot.layers[1].intensity = Float(i) / 4
                slot.layers[1].playMode = .bounce
                slot.outputs[0].raw = i % 2 == 1
                slot.keystones[1] = matrix_identity_float3x3 * Float(i)
                slot.keystoneInvalid[1] = i == 2
            }
        }
        let published = store.snapshots.read()
        #expect(published.sequence == 3)
        let same = store.snapshots.withLatest {
            $0.sequence == published.sequence && $0.receivedAt == published.receivedAt && $0.master == published.master
                && $0.masterControl == published.masterControl && $0.masterSpeed == published.masterSpeed
                && $0.testPattern == published.testPattern && $0.layers == published.layers && $0.outputs == published.outputs
                && $0.keystones == published.keystones && $0.keystoneInvalid == published.keystoneInvalid
        }
        #expect(same)
    }

    /// DESIGN.md §9.10 item 2: a Keystone fixture patched next to its Output fixture. Both reach the snapshot whichever
    /// changes, in either patch order: the Output fixture rebuilds `outputs` on every publish, so the keystone has its own
    /// array. A refused quad keeps the last valid matrix and is flagged; unpatched is the identity again.
    @Test func keystoneAndOutputFixturesBothApply() {
        let universe = UniverseID(.artnet, 0)
        let output = PatchEntry(fixture: .output(1), universe: universe, address: 1)
        let keystone = PatchEntry(fixture: .keystone(1), universe: universe, address: 9)
        for entries in [[output, keystone], [keystone, output]] {
            let store = DMXStore(patch: Patch(entries: entries), logger: Logger(label: "test"))
            var time = 1000.0
            /// Output 1 intensity, Keystone 1 centred but for the top-left corner.
            func send(intensity: UInt16, topLeft: (x: UInt16, y: UInt16)) {
                var data = [UInt8](repeating: 0, count: 512)
                (data[0], data[1]) = (UInt8(intensity >> 8), UInt8(intensity & 0xFF))
                for (i, raw) in ([topLeft.x, topLeft.y] + Array(repeating: 32768, count: 6)).enumerated() {
                    (data[8 + 2 * i], data[9 + 2 * i]) = (UInt8(raw >> 8), UInt8(raw & 0xFF))
                }
                time += 0.02
                store.queue.sync { store.receive(artnet: ArtDmx(portAddress: 0, data: data), from: "desk", at: time) }
            }
            func state() -> (intensity: Float, topLeft: SIMD2<Float>, invalid: Bool) {
                store.snapshots.withLatest { slot in
                    let k = slot.keystones[0] * SIMD3<Float>(0, 0, 1)
                    return (slot.outputs[0].intensity, SIMD2(k.x, k.y) / k.z, slot.keystoneInvalid[0])
                }
            }
            func near(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Bool { simd_distance(a, b) < 1e-3 }
            let quarter = ChannelMap.spec(.keystone(.topLeftX)).raw(fromPhysical: 25)
            send(intensity: 32768, topLeft: (quarter, 32768))
            var s = state()
            #expect(abs(s.intensity - 0.5) < 0.01 && near(s.topLeft, SIMD2(0.25, 0)) && !s.invalid, "\(entries.map(\.fixture)): \(s)")
            send(intensity: 65535, topLeft: (quarter, 32768))
            s = state()
            #expect(s.intensity == 1 && near(s.topLeft, SIMD2(0.25, 0)), "an Output change keeps the keystone: \(s)")
            // top-left onto the centre: on the TR–BL diagonal, refused; the output still follows its own fixture
            send(intensity: 0, topLeft: (65535, 65535))
            s = state()
            #expect(s.intensity == 0 && near(s.topLeft, SIMD2(0.25, 0)) && s.invalid, "the last valid keystone stays: \(s)")
            store.setPatch(Patch(entries: [output]))
            store.queue.sync {}
            s = state()
            #expect(near(s.topLeft, .zero) && !s.invalid, "unpatched: the identity")
        }
    }

    /// Writer at ~1 kHz, the render reader on its own thread and a copy reader at ~2 kHz: no torn slot on either
    /// side, and the render reader's slot never changes under it (also run under `-sanitize=thread`).
    @Test func concurrentWriterRenderReaderAndCopyReader() async throws {
        let run = try await offPool { readerRun(count: 1000, interval: 0.001, otherHz: 2000, other: copyReader) }
        print("B71 stress (1 kHz writer, copy reader): \(run)")
        #expect(run.torn == 0)
        #expect(run.changed == 0)
        #expect(run.otherTorn == 0)
        #expect(run.lastSeen == 1000)
    }

    /// Sparse updates (one per 20 ms) with a 4 Hz copy reader (CITP layer status): the render reader's slot stays
    /// intact and it ends on the last update. `missed` is printed, not asserted: it depends on the reader thread being
    /// scheduled within each 20 ms gap.
    @Test func sparseUpdatesBesideA4HzCopyReader() async throws {
        let run = try await offPool { readerRun(count: 100, interval: 0.02, otherHz: 4, other: copyReader) }
        print("B71 sparse (100 updates 20 ms apart, 4 Hz copy reader): \(run)")
        #expect(run.changed == 0)
        #expect(run.torn == 0)
        #expect(run.lastSeen == 100)
    }
}

final class Twin { var a = 0; var b = 0 }

let copyReader: @Sendable (TripleBuffer<Twin>) -> (Int, Int) = { buffer in buffer.withLatest { ($0.a, $0.b) } }

struct ReaderRun: CustomStringConvertible {
    var missed = 0, changed = 0, torn = 0, lastSeen = 0, otherReads = 0, otherTorn = 0
    var description: String {
        "missed \(missed), changed under the render reader \(changed), torn \(torn), last seen \(lastSeen); "
            + "other reads \(otherReads), torn \(otherTorn)"
    }
}

/// One writer (`count` writes `interval` apart, `a = k, b = −k`), the render reader on its own thread (`read()` about
/// every 0.5 ms, keeping the slot over a 0.2 ms "tick") and another reader at `otherHz` through `other`. Blocking:
/// call it through `offPool`.
func readerRun(count: Int, interval: TimeInterval, otherHz: Double, other: @escaping @Sendable (TripleBuffer<Twin>) -> (Int, Int))
    -> ReaderRun
{
    final class Shared: @unchecked Sendable {  // `run` is written by the render reader only, read after the join
        let stop = Atomic<Bool>(false)
        let lastSeen = Atomic<Int>(0)
        let other = Mutex((reads: 0, torn: 0))
        var run = ReaderRun()
    }
    let buffer = TripleBuffer({ Twin() }, copy: { $0.a = $1.a; $0.b = $1.b })
    let shared = Shared()
    let group = DispatchGroup()
    func thread(_ body: @escaping @Sendable () -> Void) {
        group.enter()
        Thread.detachNewThread {
            body()
            group.leave()
        }
    }
    thread {
        for k in 1...count {
            buffer.write { $0.a = k; $0.b = -k }
            usleep(UInt32(interval * 1e6))
        }
        // the render reader gets up to 2 s to see the last write, not a fixed sleep
        let deadline = Date().addingTimeInterval(2)
        while shared.lastSeen.load(ordering: .relaxed) != count, Date() < deadline { usleep(1000) }
        shared.stop.store(true, ordering: .relaxed)
    }
    thread {
        var seen = [Bool](repeating: false, count: count + 1)
        while !shared.stop.load(ordering: .relaxed) {
            let slot = buffer.read()
            let a = slot.a, b = slot.b
            if a != -b { shared.run.torn += 1 }
            if a > 0, a <= count { seen[a] = true }
            shared.lastSeen.store(a, ordering: .relaxed)
            usleep(200)
            if slot.a != a || slot.b != b { shared.run.changed += 1 }
            usleep(300)
        }
        shared.run.missed = seen.dropFirst().filter { !$0 }.count
    }
    thread {
        while !shared.stop.load(ordering: .relaxed) {
            let (a, b) = other(buffer)
            shared.other.withLock { $0.reads += 1; if a != -b { $0.torn += 1 } }
            usleep(UInt32(1e6 / otherHz))
        }
    }
    group.wait()
    var run = shared.run
    run.lastSeen = shared.lastSeen.load(ordering: .relaxed)
    (run.otherReads, run.otherTorn) = shared.other.withLock { ($0.reads, $0.torn) }
    return run
}
