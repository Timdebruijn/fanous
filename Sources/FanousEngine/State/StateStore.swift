// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import Logging
import Synchronization

/// A command on the `project` document (DESIGN.md §11.2): validated, applied, diffed into a patch;
/// the inverse patch is recorded for undo. `run` mutates a copy of the project; the store diffs
/// before and after, so commands never spell out their own inverse.
public struct CommandSpec: Sendable {
    public var name: String
    /// Minimum role.
    public var role: Role
    /// Refused while the show is locked (except `show.unlock`).
    public var mutatesConfig = true
    public var undoable = true
    /// One line for `protocol.d.ts`.
    public var summary: String
    /// Arguments schema for `protocol.d.ts`, as a TypeScript type literal (`{ path: string; value: unknown }`).
    public var argsType = "Record<string, never>"
    /// Checked before undo or redo replays this command's history entry, with the patch the step would apply, the patch
    /// that made the state it undoes, and the project as it is now; a thrown `CommandError` refuses the step (the entry
    /// stays, unless the code is `historyConflict`; a dropped `project.revert` entry takes its whole stack with it, B91).
    public var replayCheck: (@Sendable (JSONPatch, JSONPatch, JSONValue) throws -> Void)?
    /// What makes two calls "the same edit" for undo coalescing (a slider drag), with the args' `id`; nil = their `path`.
    public var coalesceKey: (@Sendable (JSONValue) -> String?)?
    /// Runs before `run` on the caller's thread, with the control queue free, once the role is checked; what it returns
    /// is `run`'s args. For a slow part that must not hold the queue: `show.mode`'s readiness checks (B200). It runs before
    /// `executeLocked`'s own checks (show lock, and whatever the queue's state is by then), so it must do nothing those
    /// could still refuse.
    public var prepare: (@Sendable (JSONValue) throws -> JSONValue)?
    /// B286: `executeUnqueued` runs it on the caller's thread without the control queue: for a command that neither reads
    /// nor changes the project and is refused by nothing but its role (`cue.go`, `cue.back`, `cue.goto`: OSC and MIDI fire
    /// them, and a GO must not wait behind a welcome or a project change). Needs `mutatesConfig` false.
    public var unqueued = false
    public var run: @Sendable (inout JSONValue, JSONValue) throws -> JSONValue?
}

public struct CommandError: Error, Equatable, Sendable {
    public var code: String
    public var message: String
    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
    public static let showLocked = CommandError("showLocked", "the show is locked; unlock it first (programmer)")
    public static let forbidden = CommandError("forbidden", "your role may not run this command")
    public static let unknownCommand = CommandError("unknownCommand", "no such command")
    public static func invalidArgs(_ detail: String) -> CommandError { CommandError("invalidArgs", detail) }
}

/// What the store needs from a connected client: a bounded sender. `send` returns false when the message
/// was dropped (queue full); the store then marks the client lagging (live) or disconnects it (project).
public protocol StateClient: AnyObject, Sendable {
    var role: Role { get }
    func send(text: String, droppable: Bool) -> Bool
    func disconnect(reason: String)
}

public struct CommandResult: Sendable, Equatable {
    public var rev: UInt64
    public var value: JSONValue?
}

/// Holds `project` and `live` (DESIGN.md §11.2) and fans patches out to clients. Everything runs on
/// `queue` (Control); `execute` and `updateLive` are the entry points.
public final class StateStore: @unchecked Sendable {
    public let queue = DispatchQueue(label: "org.fanous.control", qos: .userInitiated)
    public static let maxHistory = 500
    public static let liveInterval: TimeInterval = 0.05

    private struct HistoryEntry {
        var name: String
        var forward: JSONPatch
        var inverse: JSONPatch
        /// Coalescing key: same command, args id and path (or the command's `coalesceKey`) and client within
        /// `coalesceWindow` merge into one entry.
        var key: String? = nil
        var client: ObjectIdentifier? = nil
        var at: TimeInterval = 0
    }
    /// Consecutive same-path edits from one client closer together than this (a drag) become one undo step.
    public static let coalesceWindow: TimeInterval = 1
    /// `held`: set while `admit` builds the client's welcome off the queue; patches wait there and go out after it.
    private struct Client { var client: StateClient; var lagging = false; var held: [(text: String, droppable: Bool)]? }

    private var projectDocument: JSONValue
    private var liveDocument: JSONValue = [:]
    private var revision: UInt64 = 0
    private var commands: [String: CommandSpec] = [:]
    private var undoStack: [HistoryEntry] = []
    private var redoStack: [HistoryEntry] = []
    private var clients: [ObjectIdentifier: Client] = [:]
    private var pendingLive: [JSONPatch.Operation] = []
    private var liveTimer: DispatchSourceTimer?
    private let logger: Logger
    /// The `unqueued` commands, readable without the queue (B286).
    private let unqueuedCommands = Mutex<[String: CommandSpec]>([:])
    /// Called on `queue` after every project change (autosave), before the change goes out to clients.
    public var onProjectChanged: (@Sendable (JSONValue) -> Void)?

    public init(project: JSONValue, logger: Logger) {
        projectDocument = project
        self.logger = logger
        register(CommandSpec(name: "undo", role: .programmer, undoable: false, summary: "Undo the last undoable command (global history).") { _, _ in nil })
        register(CommandSpec(name: "redo", role: .programmer, undoable: false, summary: "Redo the last undone command.") { _, _ in nil })
        register(CommandSpec(name: "show.lock", role: .programmer, mutatesConfig: false, undoable: false, summary: "Lock the show: configuration commands are refused.") { project, _ in
            try project.set(true, at: "/showLock")
            return nil
        })
        register(CommandSpec(name: "show.unlock", role: .programmer, mutatesConfig: false, undoable: false, summary: "Unlock the show.") { project, _ in
            try project.set(false, at: "/showLock")
            return nil
        })
    }

    // MARK: Registry and snapshots

    public func register(_ spec: CommandSpec) {
        precondition(!spec.unqueued || !spec.mutatesConfig, "an unqueued command must not change the configuration")
        queue.sync { commands[spec.name] = spec }
        unqueuedCommands.withLock { $0[spec.name] = spec.unqueued ? spec : nil }
    }
    public var commandSpecs: [CommandSpec] { queue.sync { commands.values.sorted { $0.name < $1.name } } }

    public var rev: UInt64 { queue.sync { revision } }
    public var project: JSONValue { queue.sync { projectDocument } }
    public var live: JSONValue { queue.sync { liveDocument } }
    public var historyDepth: (undo: Int, redo: Int) { queue.sync { (undoStack.count, redoStack.count) } }

    // MARK: Commands

    /// Runs a command synchronously on the control queue; a command's `prepare` runs before, off it.
    public func execute(_ name: String, args: JSONValue = [:], role: Role, from client: AnyObject? = nil) -> Result<CommandResult, CommandError> {
        let client = client.map(ObjectIdentifier.init)
        let (done, prepare) = queue.sync { () -> (Result<CommandResult, CommandError>?, (@Sendable (JSONValue) throws -> JSONValue)?) in
            if let spec = commands[name], role >= spec.role, let prepare = spec.prepare { return (nil, prepare) }
            return (executeLocked(name, args: args, role: role, client: client), nil)
        }
        guard let prepare else { return done! }
        let prepared: JSONValue
        do {
            prepared = try prepare(args)
        } catch let error as CommandError {
            return .failure(error)
        } catch {
            return .failure(CommandError("failed", "\(error)"))
        }
        return queue.sync { executeLocked(name, args: prepared, role: role, client: client) }
    }

    /// OSC and MIDI (B286): an `unqueued` command runs here on the caller's thread, with no project (`run` gets null) and
    /// rev 0 in its result; any other goes through `execute`. A WebSocket command always goes through `execute`, so its
    /// ack keeps the revision.
    public func executeUnqueued(_ name: String, args: JSONValue = [:], role: Role) -> Result<CommandResult, CommandError> {
        guard let spec = unqueuedCommands.withLock({ $0[name] }) else { return execute(name, args: args, role: role) }
        guard role >= spec.role else { return .failure(.forbidden) }
        var none = JSONValue.null
        do {
            return .success(CommandResult(rev: 0, value: try spec.run(&none, args)))
        } catch let error as CommandError {
            return .failure(error)
        } catch {
            return .failure(CommandError("failed", "\(error)"))
        }
    }

    private func executeLocked(_ name: String, args: JSONValue, role: Role, client: ObjectIdentifier? = nil) -> Result<CommandResult, CommandError> {
        guard let spec = commands[name] else { return .failure(.unknownCommand) }
        guard role >= spec.role else { return .failure(.forbidden) }
        let locked = projectDocument["showLock"]?.bool ?? false
        if locked && spec.mutatesConfig && name != "show.unlock" { return .failure(.showLocked) }
        switch name {
        case "undo": return step(from: &undoStack, to: &redoStack)
        case "redo": return step(from: &redoStack, to: &undoStack)
        default: break
        }
        var next = projectDocument
        let value: JSONValue?
        do {
            value = try spec.run(&next, args)
        } catch let error as CommandError {
            return .failure(error)
        } catch let error as JSONPatch.PatchError {
            return .failure(.invalidArgs("\(error)"))
        } catch {
            return .failure(CommandError("failed", "\(error)"))
        }
        let forward = ProjectDocument.wholeLiveEntries(JSONPatch.diff(from: projectDocument, to: next), in: next)
        if !forward.isEmpty {
            let inverse = ProjectDocument.wholeLiveEntries(JSONPatch.diff(from: next, to: projectDocument), in: projectDocument)
            commit(next, patch: forward)
            if spec.undoable {
                let key = (spec.coalesceKey?(args) ?? args["path"]?.string).map { "\(name)|\(args["id"]?.int ?? -1)|\($0)" }
                let now = ProcessInfo.processInfo.systemUptime
                if let key, let client, let last = undoStack.last, last.key == key, last.client == client, now - last.at < Self.coalesceWindow {
                    undoStack[undoStack.count - 1] = HistoryEntry(
                        name: name, forward: JSONPatch(operations: last.forward.operations + forward.operations),
                        inverse: JSONPatch(operations: inverse.operations + last.inverse.operations), key: key, client: client, at: now)
                } else {
                    undoStack.append(HistoryEntry(name: name, forward: forward, inverse: inverse, key: key, client: client, at: now))
                }
                if undoStack.count > Self.maxHistory { undoStack.removeFirst() }
                redoStack.removeAll()
            }
        }
        logger.debug("command \(name)", metadata: ["role": "\(role)", "rev": "\(revision)", "ops": "\(forward.operations.count)"])
        return .success(CommandResult(rev: revision, value: value))
    }

    private func step(from source: inout [HistoryEntry], to target: inout [HistoryEntry]) -> Result<CommandResult, CommandError> {
        guard let last = source.last else { return .failure(CommandError("nothingToUndo", "history is empty")) }
        // a revert replaced the whole project: the entries below a dropped one were recorded against the other project (B91)
        func drop() { if last.name == "project.revert" { source.removeAll() } else { source.removeLast() } }
        do {
            try commands[last.name]?.replayCheck?(last.inverse, last.forward, projectDocument)
        } catch let error as CommandError {
            // a conflict does not clear up by itself (B90): the entry goes, as one that no longer applies does below
            if error.code == "historyConflict" { drop() }
            return .failure(error)
        } catch {
            return .failure(CommandError("failed", "\(error)"))
        }
        var next = projectDocument
        var applied: [JSONPatch.Operation] = []
        do {
            for operation in last.inverse.operations {
                // already gone (the engine dropped a running server's twin): nothing to undo, and no client hears of it
                if case .remove(let pointer) = operation, next[pointer] == nil { continue }
                try JSONPatch(operations: [operation]).apply(to: &next)
                applied.append(operation)
            }
        } catch {
            drop()
            logger.error("history entry no longer applies", metadata: ["command": "\(last.name)", "error": "\(error)"])
            return .failure(CommandError("historyConflict", "the change no longer applies"))
        }
        source.removeLast()
        if !applied.isEmpty { commit(next, patch: JSONPatch(operations: applied)) }
        // the whole patch, skipped removes included: the other direction's check needs what this step meant to leave
        target.append(HistoryEntry(name: last.name, forward: last.inverse, inverse: last.forward))
        return .success(CommandResult(rev: revision, value: nil))
    }

    /// Engine-owned correction of a project value (a change the engine could not apply is put back): no command,
    /// no history entry, every client gets the patch. Not to be called from the store's own queue.
    public func correct(_ value: JSONValue, at pointer: JSONPointer) { correct(at: pointer) { value } }

    /// As `correct(_:at:)`, with the value made on the store's queue: it cannot be older than a change committed before
    /// it (the engine's Syphon numbering against `syphon.forget`, B69).
    public func correct(at pointer: JSONPointer, _ make: () -> JSONValue) {
        queue.sync {
            var next = projectDocument
            guard (try? next.set(make(), at: pointer)) != nil else { return }
            let patch = JSONPatch.diff(from: projectDocument, to: next)
            if !patch.isEmpty { commit(next, patch: patch) }
        }
    }

    private func commit(_ next: JSONValue, patch: JSONPatch) {
        projectDocument = next
        revision += 1
        // projectChanged runs before any client hears of the change: a client that asks for the preview of an output it
        // was just told about must find it (B62); the asynchronous parts (canvas switch, DMX patch, output windows) may
        // still follow
        onProjectChanged?(projectDocument)
        broadcast(doc: "project", patch: patch, droppable: false)
    }

    // MARK: Live

    /// Replaces the whole live document; only the differences go out, batched every 50 ms.
    public func updateLive(_ document: JSONValue) {
        queue.async { [self] in
            let patch = JSONPatch.diff(from: liveDocument, to: document)
            guard !patch.isEmpty else { return }
            liveDocument = document
            enqueueLive(patch.operations)
        }
    }

    /// Sets one live value; coalesced per path with everything else pending for the same batch.
    public func setLive(_ value: JSONValue, at pointer: JSONPointer) {
        queue.async { [self] in
            guard liveDocument[pointer] != value else { return }
            do {
                try liveDocument.set(value, at: pointer)
            } catch {
                logger.error("live set failed", metadata: ["path": "\(pointer)", "error": "\(error)"])
                return
            }
            enqueueLive([.add(pointer, value)])  // add: the path may be new on the client's copy
        }
    }

    private func enqueueLive(_ operations: [JSONPatch.Operation]) {
        pendingLive.append(contentsOf: operations)
        guard liveTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.liveInterval)
        timer.setEventHandler { [self] in flushLive() }
        timer.resume()
        liveTimer = timer
    }

    private func flushLive() {
        liveTimer?.cancel()
        liveTimer = nil
        guard !pendingLive.isEmpty else { return }
        // latest value per path wins
        var seen: Set<String> = []
        var coalesced: [JSONPatch.Operation] = []
        for operation in pendingLive.reversed() {
            if seen.insert(operation.path.description).inserted { coalesced.append(operation) }
        }
        pendingLive.removeAll()
        revision += 1
        broadcast(doc: "live", patch: JSONPatch(operations: coalesced.reversed()), droppable: true)
    }

    // MARK: Clients

    public func detach(_ client: StateClient) { queue.sync { _ = clients.removeValue(forKey: ObjectIdentifier(client)) } }
    public var clientCount: Int { queue.sync { clients.count } }
    public var laggingClients: Int { queue.sync { clients.values.filter(\.lagging).count } }

    /// The `welcome`/`snapshot` payload for one client.
    public func welcome(role: Role, caps: JSONValue) -> String { Self.welcomeMessage(documents, role: role, caps: caps) }

    /// Makes `client` a member at `role` and sends its welcome before any broadcast (built for the new role) reaches it.
    public func admit(_ client: StateClient, role: Role, caps: JSONValue, setRole: () -> Void) {
        send(to: client, setup: {
            setRole()
            let id = ObjectIdentifier(client)
            if clients[id] == nil { clients[id] = Client(client: client, held: nil) }
        }) { Self.welcomeMessage($0, role: role, caps: caps) }
    }

    /// A client's `snapshot` request (a gap, or lagging): clears its lagging flag and sends the snapshot before any
    /// patch with a later revision.
    public func resnapshot(_ client: StateClient, role: Role) {
        send(to: client, setup: { clients[ObjectIdentifier(client)]?.lagging = false }) { Self.snapshotMessage($0, role: role) }
    }

    /// B286: a welcome or snapshot is redacted and encoded off the control queue, from the documents copied in the turn
    /// that `setup` runs in; a member's patches broadcast meanwhile are held and go out after it, in order. The encoding
    /// runs on `encodeQueue`, one at a time: 20 clients joining take one core, as when it ran on the control queue.
    private func send(to client: StateClient, setup: () -> Void, make: ((UInt64, JSONValue, JSONValue)) -> String) {
        let id = ObjectIdentifier(client)
        let copied = queue.sync {
            setup()
            if clients[id]?.held == nil { clients[id]?.held = [] }
            return (revision, projectDocument, liveDocument)
        }
        whileWelcoming?()
        let text = encodeQueue.sync { make(copied) }
        queue.sync {
            let held = clients[id]?.held
            clients[id]?.held = nil
            _ = client.send(text: text, droppable: false)  // also to a client detached meanwhile: its session is closed
            for message in held ?? [] { deliver(message.text, droppable: message.droppable, to: id) }
        }
    }

    /// Welcome and snapshot encoding, one at a time (see `send(to:setup:make:)`); entered with `sync`, so the work runs at
    /// the waiting connection's QoS, as it did on the control queue.
    private let encodeQueue = DispatchQueue(label: "org.fanous.control.encode")

    /// Test hook: called between the copy and the encoding of a welcome or snapshot.
    nonisolated(unsafe) var whileWelcoming: (@Sendable () -> Void)?

    /// The revision and both documents, copied on the queue (shared storage: no copy of the documents).
    private var documents: (UInt64, JSONValue, JSONValue) { queue.sync { (revision, projectDocument, liveDocument) } }

    private static func welcomeMessage(_ documents: (UInt64, JSONValue, JSONValue), role: Role, caps: JSONValue) -> String {
        var message = snapshotObject(documents, role: role)
        message["t"] = "welcome"
        message["role"] = .string(role.rawValue)
        message["caps"] = caps
        return JSONValue.encodeCompact(.object(message))
    }

    private static func snapshotMessage(_ documents: (UInt64, JSONValue, JSONValue), role: Role) -> String {
        var message = snapshotObject(documents, role: role)
        message["t"] = "snapshot"
        return JSONValue.encodeCompact(.object(message))
    }

    /// The snapshot text for `role` (tests); a client's request goes through `resnapshot`.
    public func snapshot(role: Role) -> String { Self.snapshotMessage(documents, role: role) }

    /// One patch message per role present (Redaction): a redacted patch may be empty but still goes out, keeping the revision chain.
    private func broadcast(doc: String, patch: JSONPatch, droppable: Bool) {
        var messages: [Role: String] = [:]
        for (id, entry) in clients {
            let role = entry.client.role
            if messages[role] == nil { messages[role] = patchMessage(doc: doc, patch: Redaction.patch(patch, doc: doc, role: role)) }
            if entry.held != nil {
                clients[id]?.held?.append((messages[role]!, droppable))  // its welcome is being built (`admit`)
            } else {
                deliver(messages[role]!, droppable: droppable, to: id)
            }
        }
    }

    /// Queue only: a full send queue marks the client lagging (live) or drops it (project).
    private func deliver(_ text: String, droppable: Bool, to id: ObjectIdentifier) {
        guard let entry = clients[id], !entry.client.send(text: text, droppable: droppable) else { return }
        if droppable {
            if !entry.lagging { logger.warning("client lagging; live patches dropped") }
            clients[id]?.lagging = true
        } else {
            entry.client.disconnect(reason: "cannot keep up with project changes")
            clients.removeValue(forKey: id)
        }
    }

    private static func snapshotObject(_ documents: (rev: UInt64, project: JSONValue, live: JSONValue), role: Role) -> [String: JSONValue] {
        [
            "rev": .number(Double(documents.rev)), "project": Redaction.document(documents.project, doc: "project", role: role),
            "live": Redaction.document(documents.live, doc: "live", role: role),
        ]
    }

    private func patchMessage(doc: String, patch: JSONPatch) -> String {
        let ops = (try? JSONDecoder().decode(JSONValue.self, from: JSONValue.wireEncoder.encode(patch.operations))) ?? []
        return encode(["t": "patch", "rev": .number(Double(revision)), "doc": .string(doc), "ops": ops])
    }

    func encode(_ value: JSONValue) -> String { JSONValue.encodeCompact(value) }
}
