// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Logging
import Synchronization
import Testing

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
            }
        }
        let published = store.snapshots.read()
        #expect(published.sequence == 3)
        let same = store.snapshots.withLatest {
            $0.sequence == published.sequence && $0.receivedAt == published.receivedAt && $0.master == published.master
                && $0.masterControl == published.masterControl && $0.masterSpeed == published.masterSpeed
                && $0.testPattern == published.testPattern && $0.layers == published.layers && $0.outputs == published.outputs
        }
        #expect(same)
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

    /// Sparse updates (one per 20 ms) with a 4 Hz copy reader (CITP layer status): the render reader sees every one.
    @Test func renderReaderSeesEverySparseUpdateBesideA4HzCopyReader() async throws {
        let run = try await offPool { readerRun(count: 100, interval: 0.02, otherHz: 4, other: copyReader) }
        print("B71 sparse (100 updates 20 ms apart, 4 Hz copy reader): \(run)")
        #expect(run.missed == 0)
        #expect(run.changed == 0)
        #expect(run.torn == 0)
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
        usleep(20_000)
        shared.stop.store(true, ordering: .relaxed)
    }
    thread {
        var seen = [Bool](repeating: false, count: count + 1)
        while !shared.stop.load(ordering: .relaxed) {
            let slot = buffer.read()
            let a = slot.a, b = slot.b
            if a != -b { shared.run.torn += 1 }
            if a > 0, a <= count { seen[a] = true }
            shared.run.lastSeen = a
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
    (run.otherReads, run.otherTorn) = shared.other.withLock { ($0.reads, $0.torn) }
    return run
}
