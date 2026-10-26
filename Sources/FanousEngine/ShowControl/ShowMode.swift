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
/// loss) or was an Engine › Restart Engine: show mode resumes.
public struct ShowModeState: Codable, Equatable, Sendable {
    public var on: Bool
    /// When show mode was entered (seconds since 1970); kept across a resume.
    public var since: Double
    /// `kern.boottime` when written: the same boot means the engine died, not the Mac.
    public var boot: Double
    /// When written (seconds since 1970).
    public var written: Double
    /// Written by the stop for Engine › Restart Engine: show mode kept on purpose.
    public var restart: Bool?

    public init(on: Bool = true, since: Double, boot: Double, written: Double, restart: Bool? = nil) {
        self.on = on
        self.since = since
        self.boot = boot
        self.written = written
        self.restart = restart
    }

    /// After a reboot (power loss, panic) a file this young still resumes the show; an older one is stale.
    public static let maxAgeAfterReboot: Double = 2 * 3600

    public enum Decision: Equatable, Sendable { case none, resume(ShowModeState), stale }

    /// The start decision: resume when the Mac has not rebooted since the write (engine crash, kill, restart), or when
    /// the file is younger than `maxAgeAfterReboot` (the Mac went down mid-show); anything else is stale.
    public static func decide(_ state: ShowModeState?, boot: Double, now: Double) -> Decision {
        guard let state, state.on else { return .none }
        // kern.boottime moves a little when the wall clock is stepped
        let age = now - state.written
        if abs(state.boot - boot) < 5 || (age >= 0 && age < maxAgeAfterReboot) { return .resume(state) }
        return .stale
    }

    /// nil: no file, unreadable (an older format too), or off.
    public static func load(from url: URL) -> ShowModeState? {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(Self.self, from: data), state.on else { return nil }
        return state
    }

    /// `sysctl kern.boottime` in seconds since 1970; 0 when it cannot be read.
    public static var bootTime: Double {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0 else { return 0 }
        return Double(value.tv_sec) + Double(value.tv_usec) / 1e6
    }

    /// The shell writes `restart-pending` right before Engine › Restart Engine; a stop that finds a fresh one keeps
    /// show mode. Always removed, so a marker from a failed restart cannot turn a later Stop Engine into a restart.
    public static func takeRestartMarker(at url: URL, now: Date = Date(), maxAge: TimeInterval = 60) -> Bool {
        let fm = FileManager.default
        guard let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return false }
        try? fm.removeItem(at: url)
        return now.timeIntervalSince(modified) < maxAge
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
    }

    private let logger: Logger
    private let stateURL: URL?
    /// The file is written inside this lock, so it never lags `isOn` out of order.
    private let state = Mutex(State())
    /// Side effects owned by the engine (ingest pause, display modes, log level), run on enter/leave.
    nonisolated(unsafe) public var onChange: (@Sendable (Bool) -> Void)?

    /// `stateURL`: where the on/off state survives an unclean end (nil: not persisted).
    public init(logger: Logger, stateURL: URL? = nil) {
        self.logger = logger
        self.stateURL = stateURL
    }

    public var isOn: Bool { state.withLock { $0.on } }

    /// `since`: the original entry time when show mode resumes after an unclean stop or a restart.
    public func enter(since: Date = Date()) {
        let changed = state.withLock { s -> Bool in
            guard !s.on, !s.stopping else { return false }
            IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Fanous show mode" as CFString, &s.display)
            IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Fanous show mode" as CFString, &s.system)
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

    /// Refreshes the write time while on (readiness timer), so a show longer than `maxAgeAfterReboot` still resumes
    /// after a power loss.
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
        guard let stateURL else { return }
        do {
            if s.on || restart {
                let value = ShowModeState(since: s.since, boot: ShowModeState.bootTime, written: Date().timeIntervalSince1970, restart: restart ? true : nil)
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

/// What the checks look at; filled by the engine so the checks stay testable.
public struct ReadinessContext: Sendable {
    public var universesSilent: [String] = []
    public var outputsLost: [Int] = []
    public var outputsUnassigned: [Int] = []
    public var outputsBound = 0
    /// "Output 2: …" for every bound output whose desired display mode cannot be or was not applied.
    public var modeIssues: [String] = []
    public var layerErrors: [String] = []
    public var libraryRoot: String = ""
    public var hardwareSupported = true
    public init() {}
}

public enum Readiness {
    /// All items; the slow probes (power, disk, volume, Spotlight, Time Machine, updates, display sleep) run here too,
    /// so call it off the control queue.
    public static func check(_ context: ReadinessContext, acknowledged: Set<String>) -> [ReadinessItem] {
        var items: [ReadinessItem] = []
        func add(_ id: String, _ title: String, _ ok: Bool?, _ detail: String, _ fix: String, hard: Bool = false) {
            let state: ReadinessItem.State = ok == nil ? .manual : (ok! ? .ok : (hard ? .hard : .fail))
            items.append(ReadinessItem(id: id, title: title, state: state, detail: detail, fix: fix, acknowledged: acknowledged.contains(id)))
        }
        let power = powerState()
        add("power", "On AC power", power.onAC, power.detail, "Connect the power adapter")
        let thermal = ProcessInfo.processInfo.thermalState
        add("thermal", "Thermal state nominal", thermal == .nominal || thermal == .fair, thermal == .nominal ? "nominal" : "\(thermal)", "Let the machine cool down, improve airflow")
        let disk = freeDisk(at: context.libraryRoot)
        add("disk", "Free disk > 10 %", disk.fraction > 0.10, String(format: "%.0f %% free (%.1f GB)", disk.fraction * 100, disk.freeGB), "Free space on the library volume")
        let memory = memoryHeadroom()
        add("memory", "Memory headroom", memory.fraction > 0.15, String(format: "%.0f %% free", memory.fraction * 100), "Quit other applications")
        add("dmx", "All patched universes receiving", context.universesSilent.isEmpty, context.universesSilent.isEmpty ? "all receiving" : "silent: \(context.universesSilent.joined(separator: ", "))", "Check the console's output and the network")
        let outputsOK = context.outputsLost.isEmpty && context.outputsUnassigned.isEmpty && context.outputsBound > 0
        add(
            "outputs", "All outputs bound to their displays", outputsOK,
            context.outputsBound == 0 ? "no output bound" : (context.outputsLost.isEmpty && context.outputsUnassigned.isEmpty ? "\(context.outputsBound) bound" : "lost: \(context.outputsLost), unassigned: \(context.outputsUnassigned)"),
            "Connect the displays, assign every output")
        items.append(
            ReadinessItem(
                id: "modes", title: "Outputs in their desired display mode", state: context.modeIssues.isEmpty ? .ok : .warn,
                detail: context.modeIssues.isEmpty ? "applied in show mode, or none set" : context.modeIssues.joined(separator: "; "),
                fix: "Pick an available mode for the output (Outputs › Mode), or set it in System Settings › Displays"))
        add("decoders", "No decoder errors", context.layerErrors.isEmpty, context.layerErrors.isEmpty ? "none" : context.layerErrors.joined(separator: "; "), "Fix or replace the failing media")
        let local = volumeIsLocal(context.libraryRoot)
        add("library", "Library on a local volume", local, local ? "local" : "network or removable volume", "Copy the library to the internal disk")
        let spotlight = spotlightIndexing(context.libraryRoot)
        add("spotlight", "Spotlight indexing off for the library volume", spotlight.map { !$0 }, spotlight == nil ? "unknown" : (spotlight! ? "indexing enabled" : "off"), "sudo mdutil -i off <volume>, or add the library to Spotlight Privacy")
        let updates = automaticUpdatesEnabled()
        add("updates", "Automatic macOS updates off", updates.map { !$0 }, updates == nil ? "unknown" : (updates! ? "automatic install enabled" : "off"), "System Settings › General › Software Update › Automatic updates")
        let backup = timeMachineRunning()
        add("timemachine", "Time Machine not backing up", backup.map { !$0 }, backup == nil ? "unknown" : (backup! ? "backup running" : "idle"), "Stop the backup or disable Time Machine for the show")
        add("focus", "Focus / Do Not Disturb on", nil, "cannot be read; check the menu bar", "Turn on a Focus so notifications stay off the outputs")
        let sleep = displaySleepMinutes()
        add("displaysleep", "Display sleep disabled", sleep.map { $0 == 0 } ?? true, sleep.map { $0 == 0 ? "never" : "\($0) min (held off by the show-mode assertion)" } ?? "unknown", "System Settings › Lock Screen › Turn display off: never")
        add("hardware", "Supported hardware", context.hardwareSupported, context.hardwareSupported ? "Apple Silicon with ProRes engine" : "unsupported machine", "Use an Apple Silicon Mac with a ProRes engine (M1 Pro or newer)", hard: true)
        return items
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

    static func freeDisk(at path: String) -> (fraction: Double, freeGB: Double) {
        let url = URL(fileURLWithPath: path.isEmpty ? NSHomeDirectory() : path)
        let target = FileManager.default.fileExists(atPath: url.path) ? url : URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? target.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
            let free = values.volumeAvailableCapacityForImportantUsage, let total = values.volumeTotalCapacity, total > 0
        else { return (1, 0) }
        return (Double(free) / Double(total), Double(free) / 1e9)
    }

    static func memoryHeadroom() -> (fraction: Double, freeGB: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return (1, 0) }
        let pageSize = Double(sysconf(_SC_PAGESIZE))
        let free = (Double(stats.free_count) + Double(stats.inactive_count) + Double(stats.purgeable_count)) * pageSize
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return (free / total, free / 1e9)
    }

    static func volumeIsLocal(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path.isEmpty ? NSHomeDirectory() : path)
        let target = FileManager.default.fileExists(atPath: url.path) ? url : URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? target.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsRemovableKey]) else { return true }
        return (values.volumeIsLocal ?? true) && !(values.volumeIsRemovable ?? false)
    }

    static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// `mdutil -s` for the library's volume; nil when it cannot be read.
    static func spotlightIndexing(_ path: String) -> Bool? {
        let url = URL(fileURLWithPath: path.isEmpty ? NSHomeDirectory() : path)
        let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume ?? URL(fileURLWithPath: "/")
        guard let output = run("/usr/bin/mdutil", ["-s", volume.path]) else { return nil }
        if output.contains("Indexing enabled") { return true }
        if output.contains("Indexing disabled") || output.contains("No index") { return false }
        return nil
    }

    static func automaticUpdatesEnabled() -> Bool? {
        guard let output = run("/usr/bin/defaults", ["read", "/Library/Preferences/com.apple.SoftwareUpdate", "AutomaticallyInstallMacOSUpdates"]) else { return nil }
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "1" { return true }
        if value == "0" { return false }
        return nil
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
