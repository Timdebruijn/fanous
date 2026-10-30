// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Synchronization
import Testing

@testable import FanousEngine

@Suite struct LiveCatalogTests {
    static func device(_ uid: String, _ name: String) -> LiveCatalog.Entry {
        LiveCatalog.Entry(kind: .capture, file: 0, source: uid, name: name, runtimeID: uid)
    }

    /// The Syphon state machine on capture devices (B73): files 1–20, `/capture` `{"1": {uid, name, model}}`, kept by uid.
    @Test func captureCatalogNumbersKeepsAndForgetsDevicesLikeSyphon() throws {
        let first = LiveCatalog(.capture)
        first.update(running: [Self.device("cam-a", "FaceTime HD Camera"), Self.device("cam-b", "Cam Link 4K")])
        #expect(first.entries.map(\.file) == [1, 2])
        #expect(first.entries.map(\.label) == ["FaceTime HD Camera", "Cam Link 4K"])
        let project: JSONValue = ["capture": ProjectDocument.liveValue(first.entries)]
        #expect(project["capture"]?["2"] == ["uid": "cam-b", "name": "Cam Link 4K", "model": ""])

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

        // past 20 a device waits for a number (1–3 stay held, not running)
        next.update(running: (0..<21).map { Self.device("d\($0)", "Device \($0)") })
        #expect(next.entries.count == 20 && next.unnumbered == ["Device 17", "Device 18", "Device 19", "Device 20"])
        #expect((1...3).allSatisfy { next.entry(file: $0)?.running == false })

        // entries of another kind are ignored, running or from the project
        let syphon = LiveCatalog.Entry(kind: .syphon, file: 150, source: "App", name: "", runtimeID: "s")
        next.update(running: [syphon])
        #expect(!next.adopt(next.entries + [syphon]))
        #expect(next.entries.allSatisfy { $0.kind == .capture && !$0.running } && next.unnumbered.isEmpty)

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

/// Step 2b (B73): capture devices as folder 0 files 1–20.
extension LiveCatalogTests {
    static func device(_ uid: String, _ name: String, model: String, inUse: Bool = false) -> LiveCatalog.Entry {
        LiveCatalog.Entry(kind: .capture, file: 0, source: uid, name: name, runtimeID: uid, model: model, inUse: inUse)
    }
    static func numbered(_ file: Int, _ uid: String, _ name: String, model: String) -> LiveCatalog.Entry {
        LiveCatalog.Entry(kind: .capture, file: file, source: uid, name: name, model: model)
    }

    /// A UVC device on another USB port has a new uid: with its model and name it finds exactly one entry not running and
    /// takes that number, and the entry records the new uid. Two such entries: neither (a new number).
    @Test func captureDeviceWithANewUidTakesTheNumberOfItsOnlyModelAndNameTwin() throws {
        let project: JSONValue = ["capture": ProjectDocument.liveValue([Self.numbered(1, "usb-1", "Cam Link 4K", model: "UVC 0fd9:0066")])]
        #expect(project["capture"]?["1"] == ["uid": "usb-1", "name": "Cam Link 4K", "model": "UVC 0fd9:0066"])
        let catalog = LiveCatalog(.capture, numbers: ProjectDocument.liveNumbers(.capture, from: project))
        #expect(catalog.entry(file: 1)?.model == "UVC 0fd9:0066")
        catalog.update(running: [Self.device("usb-2", "Cam Link 4K", model: "UVC 0fd9:0066")])
        #expect(catalog.entries.map(\.file) == [1])
        #expect(catalog.entry(file: 1)?.source == "usb-2" && catalog.entry(file: 1)?.running == true && catalog.entry(file: 1)?.gone == false)
        #expect(ProjectDocument.liveValue(catalog.entries)["1"]?["uid"] == "usb-2")

        // the uid wins over the fallback, whatever the order: the old uid back on 1, the newcomer on 2
        let back = LiveCatalog(.capture, numbers: [Self.numbered(1, "usb-1", "Cam Link 4K", model: "m")])
        back.update(running: [Self.device("usb-9", "Cam Link 4K", model: "m"), Self.device("usb-1", "Cam Link 4K", model: "m")])
        #expect(back.entry(file: 1)?.source == "usb-1" && back.entry(file: 2)?.source == "usb-9")

        // two twins not running: ambiguous, the device gets a number of its own; another model never matches
        let two = LiveCatalog(.capture, numbers: [Self.numbered(1, "a", "Cam Link 4K", model: "m"), Self.numbered(2, "b", "Cam Link 4K", model: "m")])
        two.update(running: [Self.device("c", "Cam Link 4K", model: "m"), Self.device("d", "Cam Link 4K", model: "other")])
        #expect(two.entries.map(\.source) == ["a", "b", "c", "d"])
        #expect(two.entry(file: 1)?.running == false && two.entry(file: 2)?.running == false)
        // the same name with another model is another device: a new number, the entry stays
        let model = LiveCatalog(.capture, numbers: [Self.numbered(1, "a", "USB Camera", model: "m")])
        model.update(running: [Self.device("b", "USB Camera", model: "n")])
        #expect(model.entry(file: 1)?.source == "a" && model.entry(file: 1)?.running == false && model.entry(file: 2)?.source == "b")
        // two newcomers with the model and name of one entry: ambiguous too, both get numbers of their own
        let pair = LiveCatalog(.capture, numbers: [Self.numbered(1, "a", "Cam Link 4K", model: "m")])
        pair.update(running: [Self.device("b", "Cam Link 4K", model: "m"), Self.device("c", "Cam Link 4K", model: "m")])
        #expect(pair.entries.map(\.source) == ["a", "b", "c"] && pair.entry(file: 1)?.running == false)
        // Syphon has no model: never a fallback
        let syphon = LiveCatalog(.syphon, numbers: [LiveCatalog.Entry(kind: .syphon, file: 150, source: "App", name: "Out")])
        syphon.update(running: [LiveCatalog.Entry(kind: .syphon, file: 0, source: "Other", name: "Out", runtimeID: "x")])
        #expect(syphon.entries.map(\.source) == ["App", "Other"])
    }

    /// A device another app has open is running and `inUse` (Continuity Camera in FaceTime); the flag follows the device,
    /// a device that goes drops it, and `live.capture` carries it with the permissions.
    @Test func captureInUseFlagAndLiveFeed() throws {
        let catalog = LiveCatalog(.capture, numbers: [Self.numbered(3, "gone", "Old Cam", model: "")])
        let changes = Atomic<Int>(0)
        catalog.onChange = { changes.add(1, ordering: .relaxed) }
        catalog.update(running: [Self.device("cam", "FaceTime HD Camera", model: "m"), Self.device("phone", "iPhone", model: "p", inUse: true)])
        #expect(catalog.entry(file: 2)?.running == true && catalog.entry(file: 2)?.inUse == true)
        #expect(
            Engine.captureLive(catalog.entries, camera: .authorized, screen: false) == [
                "devices": [
                    ["file": 1, "name": "FaceTime HD Camera", "running": true],
                    ["file": 2, "name": "iPhone", "running": true, "inUse": true],
                    ["file": 3, "name": "Old Cam", "running": false, "gone": true],
                ],
                "screens": [],
                "permissions": ["camera": "granted", "screen": "denied"],
            ])
        let before = changes.load(ordering: .relaxed)
        catalog.update(running: [Self.device("cam", "FaceTime HD Camera", model: "m"), Self.device("phone", "iPhone", model: "p")])
        #expect(catalog.entry(file: 2)?.inUse == false && changes.load(ordering: .relaxed) == before + 1)
        catalog.update(running: [Self.device("phone", "iPhone", model: "p", inUse: true)])
        catalog.update(running: [])
        #expect(catalog.entry(file: 2)?.running == false && catalog.entry(file: 2)?.inUse == false)
        #expect(Engine.permissionWord(.restricted) == "denied" && Engine.permissionWord(.denied) == "denied")
        #expect(Engine.permissionWord(.notDetermined) == "notDetermined")
        #expect(Engine.captureLive([], camera: .notDetermined, screen: true)["permissions"] == ["camera": "notDetermined", "screen": "granted"])
    }

    /// `capture.forget` as `syphon.forget` (B69) on 1–20: one number or every one not running, never a running one;
    /// programmer, undoable, refused under show lock. `capture.authorize` asks for the camera outside show mode only.
    @Test func captureForgetAndAuthorize() throws {
        let auth = RoleAuth(settingsURL: nil, shellTokenURL: nil, iterations: 1000, logger: StateStoreTests.logger)
        var project = ProjectDocument.initial(patch: .standard(layers: 2, outputs: 1), layerCount: 2, libraryRoot: "/tmp/lib", policy: .dmx)
        #expect(project["capture"] == [:])
        try project.set(ProjectDocument.liveValue([1, 2, 3].map { Self.numbered($0, "uid-\($0)", "Cam \($0)", model: "m") }), at: "/capture")
        try project.set(ProjectDocument.liveValue([LiveCatalog.Entry(kind: .syphon, file: 150, source: "App", name: "")]), at: "/syphon")
        let store = StateStore(project: project, logger: StateStoreTests.logger)
        let showMode = Atomic<Bool>(false), asked = Atomic<Int>(0), askedScreen = Atomic<Int>(0)
        ProjectDocument.registerCommands(
            on: store, auth: auth, showModeOn: { showMode.load(ordering: .relaxed) }, liveRunning: { [1] },
            authorizeCamera: { asked.add(1, ordering: .relaxed) }, authorizeScreen: { askedScreen.add(1, ordering: .relaxed) })
        func files() -> [Int] { ProjectDocument.liveNumbers(.capture, from: store.project).map(\.file) }

        #expect(store.execute("capture.forget", args: ["file": 2], role: .operator).failureCode == "forbidden")
        #expect(
            store.execute("capture.forget", args: ["file": 1], role: .programmer)
                == .failure(.invalidArgs("Capture device 1 is running; only one that is not running can be forgotten")))
        #expect(store.execute("capture.forget", args: ["file": 9], role: .programmer) == .failure(.invalidArgs("no capture device numbered 9")))
        _ = try store.execute("capture.forget", args: ["file": 2], role: .programmer).get()
        #expect(files() == [1, 3])
        _ = try store.execute("undo", role: .programmer).get()
        #expect(files() == [1, 2, 3])
        #expect(store.project["capture"]?["2"] == ["uid": "uid-2", "name": "Cam 2", "model": "m"])
        _ = try store.execute("capture.forget", role: .programmer).get()
        #expect(files() == [1])
        #expect(ProjectDocument.liveNumbers(.syphon, from: store.project).map(\.file) == [150])  // the other kind stays

        #expect(store.execute("capture.authorize", args: ["kind": "microphone"], role: .programmer).failureCode == "invalidArgs")
        let depth = store.historyDepth.undo
        _ = try store.execute("capture.authorize", args: ["kind": "camera"], role: .programmer).get()
        #expect(asked.load(ordering: .relaxed) == 1 && store.historyDepth.undo == depth)
        _ = try store.execute("capture.authorize", args: ["kind": "screen"], role: .programmer).get()
        #expect(askedScreen.load(ordering: .relaxed) == 1 && asked.load(ordering: .relaxed) == 1 && store.historyDepth.undo == depth)
        showMode.store(true, ordering: .relaxed)
        #expect(store.execute("capture.authorize", args: ["kind": "camera"], role: .programmer).failureCode == "showMode")
        #expect(store.execute("capture.authorize", args: ["kind": "screen"], role: .programmer).failureCode == "showMode")
        showMode.store(false, ordering: .relaxed)
        _ = try store.execute("show.lock", role: .programmer).get()
        #expect(store.execute("capture.forget", role: .programmer) == .failure(.showLocked))
        #expect(store.execute("capture.authorize", args: ["kind": "camera"], role: .programmer) == .failure(.showLocked))
        #expect(store.execute("capture.authorize", args: ["kind": "screen"], role: .programmer) == .failure(.showLocked))
        #expect(asked.load(ordering: .relaxed) == 1 && askedScreen.load(ordering: .relaxed) == 1)
    }

    /// A revert diffs `/capture` too: one field below `/capture/N` folds into the whole entry, and its undo is refused when
    /// another device took the number meanwhile (B91, B104 on the capture key).
    @Test func captureRevertUndoIsCheckedLikeSyphon() throws {
        let f = ProjectVersionsTests.make()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let store = f.store
        store.correct(at: "/capture") { ProjectDocument.liveValue([Self.numbered(3, "a", "Old", model: "m")]) }
        let id = try #require(try store.execute("project.snapshot", args: ["name": "Doors"], role: .programmer).get().value?["id"]?.string)
        store.correct(at: "/capture") { ProjectDocument.liveValue([Self.numbered(3, "a", "New", model: "m")]) }
        _ = try store.execute("project.revert", args: ["id": .string(id)], role: .programmer).get()
        #expect(store.project["capture"]?["3"] == ["uid": "a", "name": "Old", "model": "m"])
        _ = try store.execute("undo", role: .programmer).get()
        #expect(store.project["capture"]?["3"] == ["uid": "a", "name": "New", "model": "m"])
        _ = try store.execute("redo", role: .programmer).get()
        // 3 is freed and another device takes it, then goes
        store.correct(at: "/capture") { ProjectDocument.liveValue([]) }
        store.correct(at: "/capture") { ProjectDocument.liveValue([Self.numbered(3, "b", "Other", model: "x")]) }
        #expect(store.execute("undo", role: .programmer) == .failure(CommandError("historyConflict", "Capture number 3 is now held by Other; undo/redo refused")))
        #expect(store.project["capture"]?["3"]?["uid"] == "b")
    }

    /// The load migration gives a project from before step 2b its `/capture` key, so it never appears mid-session.
    @Test func loadAddsTheCaptureKey() throws {
        guard case .object(var map) = ProjectDocument.initial(patch: .standard(layers: 1, outputs: 0), layerCount: 1, libraryRoot: "/tmp/lib", policy: .dmx) else {
            Issue.record("the initial project is an object")
            return
        }
        map["capture"] = nil
        let url = FileManager.default.temporaryDirectory.appending(path: "fanous-capture-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try ProjectDocument.save(.object(map), to: url)
        let loaded = try #require(ProjectDocument.load(from: url))
        #expect(loaded["capture"] == [:])
    }

    /// Readiness items `camera` and `screen` (B122): only inputs in use count (a layer on folder 0 1–20 / 21–28, or a
    /// scene entry's `capture:` / `screen:`). Not granted fails (acknowledgeable, each by its own id); a display in use
    /// with the grant warns (macOS asks again about monthly); nothing in use is ok whatever the permissions.
    @Test func captureReadinessItems() throws {
        func items(
            shown: [Int] = [], sceneScreen: Bool = false, camera: String = "granted", screen: String = "granted", acknowledged: Set<String> = []
        ) throws -> (camera: ReadinessItem, screen: ReadinessItem) {
            var context = ReadinessContext()
            (context.shownFolder0, context.sceneScreen, context.cameraPermission, context.screenPermission) = (shown, sceneScreen, camera, screen)
            let all = Readiness.check(context, acknowledged: acknowledged)
            return (try #require(all.first { $0.id == "camera" }), try #require(all.first { $0.id == "screen" }))
        }
        let idle = try items(shown: [0, 29, 100, 150], camera: "denied", screen: "denied")
        #expect(idle.camera.state == .ok && idle.screen.state == .ok && idle.camera.detail == "no capture device in use" && idle.screen.detail == "no display in use")
        let camera = try items(shown: [3], camera: "notDetermined", screen: "denied")
        #expect(camera.camera.state == .fail && camera.camera.blocks && camera.camera.title == "Camera permission granted" && camera.camera.detail == "camera: notDetermined")
        #expect(camera.camera.fix == "System Settings › Privacy & Security › Camera, then Engine › Restart" && camera.screen.state == .ok)
        let scene = try items(sceneScreen: true, screen: "denied")
        #expect(scene.screen.state == .fail && scene.screen.blocks && scene.screen.title == "Screen recording granted" && scene.screen.detail == "screen: denied")
        #expect(scene.screen.fix == "System Settings › Privacy & Security › Screen & System Audio Recording, then Engine › Restart" && scene.camera.state == .ok)
        let display = try items(shown: [21])
        #expect(display.screen.state == .warn && !display.screen.blocks && display.screen.fix.contains("monthly") && display.camera.state == .ok)
        let granted = try items(shown: [3])
        #expect(granted.camera.state == .ok && granted.screen.state == .ok)
        // acknowledging one never hides the other
        let both = try items(shown: [3, 22], camera: "denied", screen: "denied", acknowledged: ["camera"])
        #expect(!both.camera.blocks && both.screen.blocks)
    }
}
