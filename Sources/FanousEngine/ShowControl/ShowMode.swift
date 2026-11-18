// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import FanousCore
import Logging
import Synchronization

/// Show mode on disk (`show-state.json`): written on enter (and refreshed every 30 s), removed on leave — and every
/// clean stop leaves show mode. A file still there at start means the last run ended uncleanly (crash, kill -9, power
/// loss) or was an Engine › Restart Engine: show mode resumes when the file is young enough (`maxAge`).
public struct ShowModeState: Codable, Equatable, Sendable {
    public var on: Bool
    /// When show mode was entered (seconds since 1970); kept across a resume.
    public var since: Double
    /// When written (seconds since 1970).
    public var written: Double
    /// Written by the stop for Engine › Restart Engine: show mode kept on purpose.
    public var restart: Bool?

    public init(on: Bool = true, since: Double, written: Double, restart: Bool? = nil) {
        self.on = on
        self.since = since
        self.written = written
        self.restart = restart
    }

    /// A file this young still resumes the show (engine crash, restart, or the Mac went down mid-show); an older one is
    /// stale, so a crash nobody restarted does not resume show mode days later (B186).
    public static let maxAge: Double = 2 * 3600

    public enum Decision: Equatable, Sendable { case none, resume(ShowModeState), stale }

    /// The start decision: resume when the file was written less than `maxAge` ago, whether or not the Mac rebooted;
    /// anything else is stale, also a write time in the future (the clock was stepped back past it).
    public static func decide(_ state: ShowModeState?, now: Double) -> Decision {
        guard let state, state.on else { return .none }
        let age = now - state.written
        return age >= 0 && age < maxAge ? .resume(state) : .stale
    }

    /// nil: no file, unreadable (an older format too), or off.
    public static func load(from url: URL) -> ShowModeState? {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(Self.self, from: data), state.on else { return nil }
        return state
    }

    /// The shell writes `restart-pending` right before Engine › Restart Engine; a stop that finds one under a minute old keeps
    /// show mode. Always removed, so a marker from a failed restart cannot turn a later Stop Engine into a restart.
    public static func takeRestartMarker(at url: URL, now: Date = Date()) -> Bool {
        let fm = FileManager.default
        guard let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return false }
        try? fm.removeItem(at: url)
        return now.timeIntervalSince(modified) < 60
    }
}

/// Show mode (DESIGN.md §14): sleep assertions, a latency-critical activity, ingest paused, warning-level logs.
/// Entered and left on the control side; the assertions are plain IOKit handles.
public final class ShowModeController: @unchecked Sendable {
    private struct State {
        var on = false
        var since: Double = 0
        var display = IOPMAssertionID(0)
        var system = IOPMAssertionID(0)
        var activity: NSObjectProtocol?
        /// Set by `stop`: no enter after the engine began stopping.
        var stopping = false
        /// Where the on/off state survives an unclean end; nil: not persisted.
        var file: URL?
    }

    private let logger: Logger
    /// The file is written inside this lock, so it never lags `isOn` out of order.
    private let state: Mutex<State>
    /// Side effects owned by the engine (ingest pause, display modes, log level), run on enter/leave.
    nonisolated(unsafe) public var onChange: (@Sendable (Bool) -> Void)?

    /// `stateURL`: where the on/off state survives an unclean end (nil: not persisted until `persist(to:)`).
    public init(logger: Logger, stateURL: URL? = nil) {
        self.logger = logger
        state = Mutex(State(file: stateURL))
    }

    public var isOn: Bool { state.withLock { $0.on } }
    var stateFile: URL? { state.withLock { $0.file } }

    /// `Engine.start`: the state is persisted to `url` from here on, so an engine that never started writes and
    /// removes no state file (B241).
    public func persist(to url: URL) { state.withLock { $0.file = url } }

    /// `since`: the original entry time when show mode resumes after an unclean stop or a restart.
    public func enter(since: Date = Date()) {
        let changed = state.withLock { s -> Bool in
            guard !s.on, !s.stopping else { return false }
            let display = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Fanous show mode" as CFString, &s.display)
            if display != kIOReturnSuccess { logger.warning("display sleep assertion not created", metadata: ["result": "\(display)"]) }
            let system = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Fanous show mode" as CFString, &s.system)
            if system != kIOReturnSuccess { logger.warning("system sleep assertion not created", metadata: ["result": "\(system)"]) }
            s.activity = ProcessInfo.processInfo.beginActivity(options: [.latencyCritical, .userInitiated, .idleDisplaySleepDisabled], reason: "Fanous show mode")
            s.on = true
            s.since = since.timeIntervalSince1970
            persist(s)
            return true
        }
        guard changed else { return }
        logger.warning("show mode entered")
        onChange?(true)
    }

    public func leave() {
        let changed = state.withLock { s -> Bool in
            guard s.on else { return false }
            release(&s)
            persist(s)
            return true
        }
        guard changed else { return }
        logger.warning("show mode left")
        onChange?(false)
    }

    /// Refreshes the write time while on (readiness timer), so a show longer than `maxAge` still resumes after
    /// a crash or a power loss.
    public func touch() {
        state.withLock { s in if s.on { persist(s) } }
    }

    /// `Engine.stop`: no enter after this. A clean stop leaves show mode (file removed, `onChange`); a restart
    /// (`keepingState`) only releases the assertions and keeps the file, marked as a restart, for the next start.
    /// True when show mode was kept.
    @discardableResult
    public func stop(keepingState keep: Bool) -> Bool {
        let wasOn = state.withLock { s -> Bool in
            s.stopping = true
            guard s.on else { return false }
            release(&s)
            persist(s, restart: keep)
            return true
        }
        guard wasOn else { return false }
        if keep {
            logger.warning("show mode kept for the restart")
            return true
        }
        logger.warning("show mode left")
        onChange?(false)
        return false
    }

    /// `since` stays: a restart writes it into the kept file.
    private func release(_ s: inout State) {
        if s.display != 0 { IOPMAssertionRelease(s.display) }
        if s.system != 0 { IOPMAssertionRelease(s.system) }
        if let activity = s.activity { ProcessInfo.processInfo.endActivity(activity) }
        s.on = false
        s.display = 0
        s.system = 0
        s.activity = nil
    }

    /// Under the state lock: on → the file, off → no file (unless kept for a restart).
    private func persist(_ s: State, restart: Bool = false) {
        guard let stateURL = s.file else { return }
        do {
            if s.on || restart {
                let value = ShowModeState(since: s.since, written: Date().timeIntervalSince1970, restart: restart ? true : nil)
                try JSONEncoder().encode(value).write(to: stateURL, options: .atomic)
            } else if FileManager.default.fileExists(atPath: stateURL.path) {
                try FileManager.default.removeItem(at: stateURL)
            }
        } catch {
            logger.error("show mode state not saved", metadata: ["error": "\(error)"])
        }
    }
}

/// One readiness item (DESIGN.md §14).
public struct ReadinessItem: Sendable, Equatable, Identifiable {
    /// `warn` never blocks: something to look at, not to acknowledge.
    public enum State: String, Sendable { case ok, warn, fail, manual, hard }
    public var id: String
    public var title: String
    public var state: State
    public var detail: String
    public var fix: String
    public var acknowledged = false

    public var blocks: Bool { (state == .fail && !acknowledged) || state == .hard }
}

/// The last readiness run and the operator's acknowledgements, kept in memory only (B163): an acknowledgement holds
/// for this failure in this show. It ends when taken back, when show mode is left, and outside show mode when its item
/// passes a run; in show mode a pass keeps it, since items such as the camera pass only while no cue uses what they check.
struct ReadinessLedger {
    private(set) var items: [ReadinessItem] = []
    private(set) var acknowledged: Set<String> = []
    private(set) var checkedAt: Double = 0

    /// Run numbers (B187): runs overlap (the readiness queue and a show-mode entry on the caller's thread, on the
    /// engine's show-entry queue with the control queue free, B200), so a run that started later may land first; an
    /// older one then stores nothing.
    private var started = 0
    private var stored = 0

    /// A run starts: its number and the acknowledgements it reads.
    mutating func begin() -> (run: Int, acknowledged: Set<String>) {
        started += 1
        return (started, acknowledged)
    }

    /// A run lands. Returns its items flagged by the acknowledgements as they are now, not as they were when the run
    /// started, and stores them unless a run that started later stored first (then nothing changes). Outside show mode
    /// a pass (ok or warn; manual is unreadable, not a pass) drops an acknowledgement, but only one the run read when
    /// it started (`checked` carries it as `acknowledged`): one made while the run was in flight stays.
    @discardableResult
    mutating func store(_ checked: [ReadinessItem], run: Int, at time: Double, showMode: Bool) -> [ReadinessItem] {
        let newest = run > stored
        if newest, !showMode {
            for item in checked where item.acknowledged && (item.state == .ok || item.state == .warn) { acknowledged.remove(item.id) }
        }
        var flagged = checked
        for i in flagged.indices { flagged[i].acknowledged = acknowledged.contains(flagged[i].id) }
        guard newest else { return flagged }
        items = flagged
        checkedAt = time
        stored = run
        return flagged
    }

    /// The stored items too, so the UI sees it now and not at the next 30 s run.
    mutating func acknowledge(_ id: String, _ on: Bool) {
        if on { acknowledged.insert(id) } else { acknowledged.remove(id) }
        reflag()
    }

    mutating func leaveShow() {
        acknowledged = []
        reflag()
    }

    private mutating func reflag() {
        for i in items.indices { items[i].acknowledged = acknowledged.contains(items[i].id) }
    }

}

/// B185: what a stored run changed, for the show-mode log line. Failing is fail or hard, acknowledged or not, so an
/// acknowledged item that fails again mid-show is reported too; `blocking` is the set after the run.
struct ReadinessChange: Equatable {
    var failing: [String] = []
    /// The items of `failing` that are acknowledged, so they do not block.
    var acknowledged: [String] = []
    var passing: [String] = []
    var blocking: [String] = []
    /// The blocking set has an item it did not have before: the line is a warning.
    var blockingGained = false

    /// Compares the stored items before and after a store, nil when nothing changed. A run the ledger discards leaves
    /// the stored items as they were, so it reports nothing.
    init?(from old: [ReadinessItem], to new: [ReadinessItem]) {
        func fails(_ item: ReadinessItem) -> Bool { item.state == .fail || item.state == .hard }
        let failedBefore = Set(old.filter(fails).map(\.id))
        let blockedBefore = Set(old.filter(\.blocks).map(\.id))
        let started = new.filter { fails($0) && !failedBefore.contains($0.id) }
        failing = started.map(\.id)
        acknowledged = started.filter(\.acknowledged).map(\.id)
        passing = new.filter { !fails($0) && failedBefore.contains($0.id) }.map(\.id)
        blocking = new.filter(\.blocks).map(\.id)
        blockingGained = blocking.contains { !blockedBefore.contains($0) }
        if failing.isEmpty, passing.isEmpty, Set(blocking) == blockedBefore { return nil }
    }
}

/// What the checks look at; filled by the engine so the checks stay testable.
public struct ReadinessContext: Sendable {
    public var universesSilent: [String] = []
    /// "artnet:0.0.1: en5" per patched universe whose interface this Mac does not have or offers no sACN multicast on (B28).
    public var interfacesMissing: [String] = []
    /// Why the Art-Net listener failed (UDP 6454 held exclusively); nil when Art-Net runs (B167).
    public var artnetError: String?
    /// Why the sACN port could not be bound at start; nil when sACN runs.
    public var sacnError: String?
    /// B281: the project did not come from `project.json` at start, and what runs instead.
    public var projectProblem: String?
    public var outputsLost: [Int] = []
    public var outputsUnassigned: [Int] = []
    public var outputsBound = 0
    /// "Output 2: …" for every bound output whose desired display mode cannot be or was not applied.
    public var modeIssues: [String] = []
    public var layerErrors: [String] = []
    /// "Output 2 slice 1: folder 3 file 5" per image mask whose file the library does not have (§9.10 item 5).
    public var maskImagesMissing: [String] = []
    public var libraryRoot: String = ""
    /// "Layer 2 (group 1): no master" / "…: two masters" for slaves playing a file.
    public var syncMasterIssues: [String] = []
    /// "Layer 2 (group 1)" for slaves playing a file whose master is lost.
    public var syncLost: [String] = []
    public var hardwareSupported = true
    /// Folder 0 files the layers show now; a permission counts only for inputs in use (B122): capture devices 1–20,
    /// displays 21–28, or a scene entry's `capture:` / `screen:`.
    public var shownFolder0: [Int] = []
    public var sceneCapture = false
    public var sceneScreen = false
    /// The camera permission ("granted", "denied", "notDetermined") and the screen-recording grant ("granted", "denied").
    public var cameraPermission = "granted"
    public var screenPermission = "granted"
    /// Timecode set to LTC (whatever the operator's switch: it may be turned on in show mode), and the microphone
    /// permission LTC needs (B137, as the camera's).
    public var ltcInUse = false
    public var microphonePermission = "granted"
    /// The library volume's read and how long a check waits for it (B197); a test replaces them with a read that hangs.
    var readVolume: @Sendable (String) -> Readiness.LibraryVolume = Readiness.libraryVolume
    var volumeTimeout = Readiness.toolTimeout
    public init() {}
}

public enum Readiness {
    /// All items; the slow probes (power, disk, volume, Spotlight, Time Machine, updates, display sleep) run here too,
    /// each external tool and the library volume's read for at most `toolTimeout`. The engine runs it on its readiness
    /// queue, and on the caller's thread (on its show-entry queue, the control queue free; B200) only to enter show
    /// mode, which needs the answer (B187).
    public static func check(_ context: ReadinessContext, acknowledged: Set<String>) -> [ReadinessItem] {
        var items: [ReadinessItem] = []
        /// `failing`: the state when not ok (`warn` never blocks, `hard` cannot be acknowledged).
        func add(_ id: String, _ title: String, _ ok: Bool?, _ detail: String, _ fix: String, failing: ReadinessItem.State = .fail) {
            let state: ReadinessItem.State = ok == nil ? .manual : (ok! ? .ok : failing)
            items.append(ReadinessItem(id: id, title: title, state: state, detail: detail, fix: fix, acknowledged: acknowledged.contains(id)))
        }
        add(
            "project", "Project file read at start", context.projectProblem == nil, context.projectProblem ?? "read",
            "Check the patch, the cues and the outputs, then acknowledge; a repaired file goes back as project.json with the engine stopped")
        let power = powerState()
        add("power", "On AC power", power.onAC, power.detail, "Connect the power adapter")
        let thermal = ProcessInfo.processInfo.thermalState
        add("thermal", "Thermal state nominal", thermal == .nominal || thermal == .fair, thermal == .nominal ? "nominal" : "\(thermal)", "Let the machine cool down, improve airflow")
        // nil: the volume has not answered in time (a stalled network mount, B197); disk and library fail, Spotlight is manual
        let volume = readVolume(context.libraryRoot, timeout: context.volumeTimeout, read: context.readVolume)
        add(
            "disk", "Free disk > 10 %", volume.map { $0.disk.fraction > 0.10 } ?? false,
            volume.map { String(format: "%.0f %% free (%.1f GB)", $0.disk.fraction * 100, $0.disk.freeGB) } ?? notAnswering,
            volume == nil ? "Reconnect the library volume, or copy the library to the internal disk" : "Free space on the library volume")
        let memory = memoryHeadroom()
        add("memory", "Memory headroom", memory > 0.15, String(format: "%.0f %% free", memory * 100), "Quit other applications")
        add("dmx", "All patched universes receiving", context.universesSilent.isEmpty, context.universesSilent.isEmpty ? "all receiving" : "silent: \(context.universesSilent.joined(separator: ", "))", "Check the console's output and the network")
        add(
            "interfaces", "Universe interfaces usable", context.interfacesMissing.isEmpty,
            context.interfacesMissing.isEmpty ? "present, or any interface" : "not usable: \(context.interfacesMissing.joined(separator: "; "))",
            "Connect the network adapter, or pick another interface for the universe (Patch › Interface)", failing: .warn)
        add(
            "artnetport", "Art-Net port 6454 available", context.artnetError == nil, context.artnetError.map { "in use, running without Art-Net: \($0)" } ?? "listening",
            "Quit the program that holds UDP 6454 (sudo lsof -nP -iUDP:6454), then Engine › Restart Engine", failing: .warn)
        add(
            "sacnport", "sACN port 5568 available", context.sacnError == nil, context.sacnError.map { "in use, running without sACN: \($0)" } ?? "listening",
            "Quit the program that holds UDP 5568 (sudo lsof -nP -iUDP:5568), then Engine › Restart Engine", failing: .warn)
        let outputsOK = context.outputsLost.isEmpty && context.outputsUnassigned.isEmpty && context.outputsBound > 0
        add(
            "outputs", "All outputs bound to their displays", outputsOK,
            context.outputsBound == 0 ? "no output bound" : (context.outputsLost.isEmpty && context.outputsUnassigned.isEmpty ? "\(context.outputsBound) bound" : "lost: \(context.outputsLost), unassigned: \(context.outputsUnassigned)"),
            "Connect the displays, assign every output")
        add(
            "modes", "Outputs in their desired display mode", context.modeIssues.isEmpty,
            context.modeIssues.isEmpty ? "applied in show mode, or none set" : context.modeIssues.joined(separator: "; "),
            "Pick an available mode for the output (Outputs › Mode), or set it in System Settings › Displays", failing: .warn)
        add(
            "syncmaster", "Sync groups have one master", context.syncMasterIssues.isEmpty,
            context.syncMasterIssues.isEmpty ? "every slave in use has one master, or none in use" : context.syncMasterIssues.joined(separator: "; "),
            "Set exactly one layer per group to master (Sync channel); a slave without a master plays on its own", failing: .warn)
        add(
            "syncpackets", "Sync packets arriving", context.syncLost.isEmpty,
            context.syncLost.isEmpty ? "arriving, or no slave in use" : "lost (freewheeling): \(context.syncLost.joined(separator: "; "))",
            "Check the master machine and the network; sync uses UDP port 8002 by default (System › Sync)", failing: .warn)
        // a permission prompt must never come up during a show (B73): it blocks until acknowledged, only for inputs in use
        // (B122). A display in use warns even when granted: macOS asks a screen-capturing app again about monthly
        // (DESIGN.md §20 R18).
        let cameraInUse = context.sceneCapture || context.shownFolder0.contains { LiveCatalog.Kind.capture.files.contains($0) }
        let screenInUse = context.sceneScreen || context.shownFolder0.contains { LiveCatalog.Kind.screens.files.contains($0) }
        add(
            "camera", "Camera permission granted", !cameraInUse || context.cameraPermission == "granted",
            cameraInUse ? "camera: \(context.cameraPermission)" : "no capture device in use", "System Settings › Privacy & Security › Camera, then Engine › Restart")
        let screenGranted = context.screenPermission == "granted"
        items.append(
            ReadinessItem(
                id: "screen", title: "Screen recording granted", state: !screenInUse ? .ok : screenGranted ? .warn : .fail,
                detail: screenInUse ? "screen: \(context.screenPermission)" : "no display in use",
                fix: screenInUse && screenGranted
                    ? "macOS asks about monthly to keep recording the screen, on the main display; prefer a capture card for a show-critical feed"
                    : "System Settings › Privacy & Security › Screen & System Audio Recording, then Engine › Restart",
                acknowledged: acknowledged.contains("screen")))
        add(
            "microphone", "Microphone permission granted", !context.ltcInUse || context.microphonePermission == "granted",
            context.ltcInUse ? "microphone: \(context.microphonePermission)" : "timecode not on LTC", "Inputs › Authorize microphone, or System Settings › Privacy & Security › Microphone")
        add("decoders", "No decoder errors", context.layerErrors.isEmpty, context.layerErrors.isEmpty ? "none" : context.layerErrors.joined(separator: "; "), "Fix or replace the failing media")
        // a missing image mask covers nothing: an add mask's slice may go black, a subtract mask cuts no hole
        add(
            "maskimages", "Image masks found", context.maskImagesMissing.isEmpty,
            context.maskImagesMissing.isEmpty ? "found, or none in use" : "missing, covering nothing: \(context.maskImagesMissing.joined(separator: "; "))",
            "Put the greyscale file in the library under that folder and file number, or change the mask (Outputs › Warp & Slices › Mask)", failing: .warn)
        let local = volume?.local ?? false
        add("library", "Library on a local volume", local, volume == nil ? notAnswering : (local ? "local" : "network or removable volume"), "Copy the library to the internal disk")
        // Spotlight Privacy exclusions are root-only (`mdutil -P`, .Spotlight-V100), so the item reads the volume switch only (B182)
        let spotlight = volume.flatMap { spotlightIndexing(volume: $0.volume) }
        add(
            "spotlight", "Spotlight indexing off for the library volume", spotlight.map { !$0 },
            volume == nil ? notAnswering : (spotlight == nil ? "unknown" : (spotlight! ? "indexing enabled" : "off")), "sudo mdutil -i off <volume>")
        let updates = automaticUpdatesEnabled()
        add("updates", "Automatic macOS updates off", updates.map { !$0 }, updates == nil ? "unknown" : (updates! ? "automatic install enabled" : "off"), "System Settings › General › Software Update › Automatic updates")
        let backup = timeMachineRunning()
        add("timemachine", "Time Machine not backing up", backup.map { !$0 }, backup == nil ? "unknown" : (backup! ? "backup running" : "idle"), "Stop the backup or disable Time Machine for the show")
        add("focus", "Focus / Do Not Disturb on", nil, "cannot be read; check the menu bar", "Turn on a Focus so notifications stay off the outputs")
        items.append(displaySleep(minutes: displaySleepMinutes(), acknowledged: acknowledged))
        add("hardware", "Supported hardware", context.hardwareSupported, context.hardwareSupported ? "Apple Silicon with ProRes engine" : "no hardware ProRes decoder", "Use an Apple Silicon Mac with a ProRes engine (M1 Pro or newer)", failing: .hard)
        return items
    }

    /// A display sleep timeout only warns (B180): show mode holds a PreventUserIdleDisplaySleep assertion and an
    /// `.idleDisplaySleepDisabled` activity, so the display stays awake whatever the setting; Never and an unreadable
    /// value pass.
    static func displaySleep(minutes: Int?, acknowledged: Set<String>) -> ReadinessItem {
        ReadinessItem(
            id: "displaysleep", title: "Display sleep disabled", state: (minutes ?? 0) == 0 ? .ok : .warn,
            detail: minutes.map { $0 == 0 ? "never" : "\($0) min; show mode keeps the display awake" } ?? "unknown",
            fix: "Show mode keeps the display awake; for outside show mode too: System Settings › Lock Screen › Turn display off: never",
            acknowledged: acknowledged.contains("displaysleep"))
    }

    // MARK: probes

    static func powerState() -> (onAC: Bool, detail: String) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return (true, "no battery")  // desktops report no sources
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            let state = description[kIOPSPowerSourceStateKey] as? String ?? ""
            let percent = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let onAC = state == kIOPSACPowerValue
            return (onAC, onAC ? "AC power (battery \(percent) %)" : "on battery, \(percent) %")
        }
        return (true, "no battery")
    }

    /// The path, or the home folder when it is empty or missing.
    static func existingPath(_ path: String) -> URL {
        let url = URL(fileURLWithPath: path.isEmpty ? NSHomeDirectory() : path)
        return FileManager.default.fileExists(atPath: url.path) ? url : URL(fileURLWithPath: NSHomeDirectory())
    }

    static func freeDisk(at path: String) -> (fraction: Double, freeGB: Double) {
        guard let values = try? existingPath(path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
            let free = values.volumeAvailableCapacityForImportantUsage, let total = values.volumeTotalCapacity, total > 0
        else { return (1, 0) }
        return (Double(free) / Double(total), Double(free) / 1e9)
    }

    /// The free fraction of physical memory (free, inactive and purgeable pages).
    static func memoryHeadroom() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 1 }
        let pageSize = Double(sysconf(_SC_PAGESIZE))
        let free = (Double(stats.free_count) + Double(stats.inactive_count) + Double(stats.purgeable_count)) * pageSize
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return free / total
    }

    static func volumeIsLocal(_ path: String) -> Bool {
        guard let values = try? existingPath(path).resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsRemovableKey]) else { return true }
        return (values.volumeIsLocal ?? true) && !(values.volumeIsRemovable ?? false)
    }

    /// What the disk, library and Spotlight items read from the library's volume.
    struct LibraryVolume: Sendable {
        var disk: (fraction: Double, freeGB: Double)
        var local: Bool
        /// The volume's mount point, for `mdutil`.
        var volume: String
    }

    static let notAnswering = "library volume not answering"

    /// Every filesystem call the checks make on the library path; on a network mount that stopped answering each one
    /// can block in the kernel for minutes.
    static func libraryVolume(_ path: String) -> LibraryVolume {
        let url = URL(fileURLWithPath: path.isEmpty ? NSHomeDirectory() : path)
        let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume ?? URL(fileURLWithPath: "/")
        return LibraryVolume(disk: freeDisk(at: path), local: volumeIsLocal(path), volume: volume.path)
    }

    /// A volume read in flight, which a later check of the same path joins instead of starting another.
    final class VolumeRead: Sendable {
        let done = DispatchGroup()
        let result = Mutex<LibraryVolume?>(nil)
    }

    static let volumeReads = Mutex<[String: VolumeRead]>([:])

    /// `read(path)` on a helper thread; nil when it has not returned within `timeout` (B197). A hung filesystem call
    /// cannot be killed, so its thread stays until the kernel gives up; every later check of the same path joins that
    /// read and waits at most `timeout` again rather than starting another. So at most one thread per library path is
    /// ever stuck, however long show mode runs the checks every 30 s.
    static func readVolume(_ path: String, timeout: Double, read: @escaping @Sendable (String) -> LibraryVolume) -> LibraryVolume? {
        let (pending, start) = volumeReads.withLock { reads in
            if let pending = reads[path] { return (pending, false) }
            let pending = VolumeRead()
            pending.done.enter()
            reads[path] = pending
            return (pending, true)
        }
        if start {
            // its own thread, not the global queue: with the pool's threads blocked elsewhere a queued read never starts
            Thread.detachNewThread {
                let volume = read(path)
                pending.result.withLock { $0 = volume }
                volumeReads.withLock { $0[path] = nil }
                pending.done.leave()
            }
        }
        guard pending.done.wait(timeout: .now() + timeout) == .success else { return nil }
        return pending.result.withLock { $0 }
    }

    /// How long a probe tool may take (B187). Measured on an M1 Pro, 2026-11-16, 20 runs each at load average 6–11:
    /// `mdutil -s` 8–16 ms, `tmutil status` 5–10 ms, `pmset -g` 8–16 ms.
    static let toolTimeout: Double = 3

    /// The tool's output (stdout and stderr); nil when it cannot be started or has not exited within `timeout`, and
    /// then it is killed (an unreachable Time Machine target must not hold the caller, B187). The output goes to an
    /// unlinked temporary file, not a pipe: a child the tool leaves behind keeps a pipe's write end open, and reading
    /// to its end would block until that child exits.
    static func run(_ tool: String, _ arguments: [String], timeout: Double = toolTimeout) -> String? {
        let url = FileManager.default.temporaryDirectory.appending(path: "fanous-probe-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil), let output = try? FileHandle(forUpdating: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            kill(process.processIdentifier, SIGKILL)  // Process reaps it when it exits; SIGTERM could be ignored
            return nil
        }
        try? output.seek(toOffset: 0)
        return String(data: (try? output.readToEnd()) ?? Data(), encoding: .utf8)
    }

    /// `mdutil -s` for the library's volume; nil when it cannot be read.
    static func spotlightIndexing(volume: String) -> Bool? {
        guard let output = run("/usr/bin/mdutil", ["-s", volume]) else { return nil }
        if output.contains("Indexing enabled") { return true }
        if output.contains("Indexing disabled") || output.contains("No index") { return false }
        return nil
    }

    /// `/Library/Preferences/com.apple.SoftwareUpdate` › AutomaticallyInstallMacOSUpdates; nil when the key is absent.
    static func automaticUpdatesEnabled() -> Bool? {
        CFPreferencesCopyValue(
            "AutomaticallyInstallMacOSUpdates" as CFString, "com.apple.SoftwareUpdate" as CFString, kCFPreferencesAnyUser, kCFPreferencesAnyHost) as? Bool
    }

    static func timeMachineRunning() -> Bool? {
        guard let output = run("/usr/bin/tmutil", ["status"]) else { return nil }
        if output.contains("Running = 1") { return true }
        if output.contains("Running = 0") { return false }
        return nil
    }

    /// `pmset -g` → "displaysleep N" (minutes, 0 = never) for the current power source.
    static func displaySleepMinutes() -> Int? {
        guard let output = run("/usr/bin/pmset", ["-g"]) else { return nil }
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, parts[0] == "displaysleep", let minutes = Int(parts[1]) { return minutes }
        }
        return nil
    }
}
