// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Testing

@testable import FanousEngine

@Suite struct LiveCatalogTests {
    static func device(_ uid: String, _ name: String) -> LiveCatalog.Entry {
        LiveCatalog.Entry(kind: .capture, file: 0, source: uid, name: name, runtimeID: uid)
    }

    /// The Syphon state machine on capture devices (B73): files 1–20, `/capture` `{"1": {uid, name}}`, kept by uid.
    @Test func captureCatalogNumbersKeepsAndForgetsDevicesLikeSyphon() throws {
        let first = LiveCatalog(.capture)
        first.update(running: [Self.device("cam-a", "FaceTime HD Camera"), Self.device("cam-b", "Cam Link 4K")])
        #expect(first.entries.map(\.file) == [1, 2])
        #expect(first.entries.map(\.label) == ["FaceTime HD Camera", "Cam Link 4K"])
        let project: JSONValue = ["capture": ProjectDocument.liveValue(first.entries)]
        #expect(project["capture"]?["2"] == ["uid": "cam-b", "name": "Cam Link 4K"])

        // a restart: every number held, gone until the device is seen; back by uid, also under a new name
        let next = LiveCatalog(.capture, numbers: ProjectDocument.liveNumbers(.capture, from: project))
        #expect(next.entries.allSatisfy { $0.gone && !$0.running })
        next.update(running: [Self.device("cam-b", "Cam Link 4K"), Self.device("cam-a", "Tim's Camera")])
        #expect(next.entry(file: 1)?.running == true && next.entry(file: 1)?.label == "Tim's Camera")
        #expect(next.entry(file: 2)?.running == true && next.entry(file: 2)?.gone == false)

        // unplugged: keeps its number, not running; a new device takes the lowest free number
        next.update(running: [Self.device("cam-b", "Cam Link 4K"), Self.device("iphone", "iPhone")])
        #expect(next.entry(file: 1)?.running == false && next.entry(file: 3)?.label == "iPhone")

        // a forget frees a number that is not running; a running device keeps its number
        #expect(next.adopt(next.entries.filter { $0.file != 1 && $0.file != 2 }))
        #expect(next.entries.map(\.file) == [2, 3])
        next.update(running: [Self.device("cam-b", "Cam Link 4K"), Self.device("iphone", "iPhone"), Self.device("usb", "USB Capture")])
        #expect(next.entry(file: 1)?.label == "USB Capture")

        // past 20 a device waits for a number (1–3 are held, gone)
        next.update(running: (0..<21).map { Self.device("d\($0)", "Device \($0)") })
        #expect(next.entries.count == 20 && next.unnumbered == ["Device 17", "Device 18", "Device 19", "Device 20"])

        // the undo/redo check of `/syphon` covers `/capture`: a number taken meanwhile is refused
        let held: JSONValue = ["capture": ["3": ["uid": "other", "name": "Other"]]]
        let undo = JSONPatch(operations: [.add("/capture/3", ["uid": "cam-a", "name": "FaceTime HD Camera"])])
        #expect(throws: CommandError("historyConflict", "Capture number 3 is now held by Other; undo/redo refused")) {
            try ProjectDocument.checkLiveReplay(undo, undoing: JSONPatch(operations: [.remove("/capture/3")]), on: held)
        }
        // and a revert's one-field diff below `/capture/N` folds into the whole entry
        let folded = ProjectDocument.wholeLiveEntries(JSONPatch(operations: [.replace("/capture/3/name", "X")]), in: held)
        #expect(folded == JSONPatch(operations: [.replace("/capture/3", ["uid": "other", "name": "Other"])]))
    }
}
