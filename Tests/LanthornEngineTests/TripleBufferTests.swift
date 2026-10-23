// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Testing

@testable import LanthornEngine

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
}
