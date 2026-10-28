// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CommonCrypto
import Foundation
import FanousCore
import Logging
import Synchronization

/// Machine settings that live outside the project (DESIGN.md §11.5).
public struct MachineSettings: Codable, Sendable, Equatable {
    public struct PasswordRecord: Codable, Sendable, Equatable {
        public var salt: Data
        public var hash: Data
        public var iterations: Int
    }
    /// Keyed by `Role.rawValue`; a role without a record is open.
    public var passwords: [String: PasswordRecord] = [:]
    /// OSC feedback to a fixed host:port for controllers that cannot subscribe (B36); edited in the file, read at start.
    public var oscFeedback: OSCFeedbackTarget?
    /// Multi-server sync interface, port and target (DESIGN.md §23.2); `sync.set` or the file. nil = defaults.
    public var sync: SyncSettings?

    /// Fields that could not be read, with the reason; never written back.
    public private(set) var problems: [String] = []
    /// The fields among them that did not decode at all.
    private(set) var unreadable: Set<CodingKeys> = []

    enum CodingKeys: String, CodingKey { case passwords, oscFeedback, sync }

    public init() {}

    /// Field by field: a missing or broken field never takes the others with it (a typo in `oscFeedback` must not
    /// drop the role passwords and open every role).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        do { passwords = try c.decodeIfPresent([String: PasswordRecord].self, forKey: .passwords) ?? [:] } catch { fail(.passwords, error) }
        do { oscFeedback = try c.decodeIfPresent(OSCFeedbackTarget.self, forKey: .oscFeedback) } catch { fail(.oscFeedback, error) }
        do { sync = try c.decodeIfPresent(SyncSettings.self, forKey: .sync) } catch { fail(.sync, error) }
        problems += (sync?.problems ?? []).map { "sync.\($0)" }
    }

    private mutating func fail(_ key: CodingKeys, _ error: Error) {
        problems.append("\(key.rawValue): \(error)")
        unreadable.insert(key)
    }

    /// Takes every field `file` could read (B82); one that did not decode keeps this copy's value, so a typo in a hand
    /// edit does not open every role.
    mutating func take(_ file: MachineSettings) {
        if !file.unreadable.contains(.passwords) { passwords = file.passwords }
        if !file.unreadable.contains(.oscFeedback) { oscFeedback = file.oscFeedback }
        if !file.unreadable.contains(.sync) { sync = file.sync }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(passwords, forKey: .passwords)
        try c.encodeIfPresent(oscFeedback, forKey: .oscFeedback)
        try c.encodeIfPresent(sync, forKey: .sync)
    }

    public static func load(from url: URL, logger: Logger? = nil) -> MachineSettings {
        guard let data = try? Data(contentsOf: url) else { return MachineSettings() }
        do {
            let settings = try JSONDecoder().decode(MachineSettings.self, from: data)
            for problem in settings.problems { logger?.error("settings.json: field ignored", metadata: ["problem": "\(problem)"]) }
            return settings
        } catch {
            logger?.error("settings.json could not be read; machine settings start empty", metadata: ["error": "\(error)"])
            return MachineSettings()
        }
    }
}

/// Roles with optional passwords (DESIGN.md §11.1): PBKDF2-HMAC-SHA256, per-role salt, HttpOnly session
/// cookies, 5 logins per minute per address, and a per-install token for the local shell.
public final class RoleAuth: @unchecked Sendable {
    public static let cookieName = "fanous_session"
    public static let sessionLifetime: TimeInterval = 24 * 3600
    public static let loginsPerMinute = 5

    private struct Session { var role: Role; var expires: Date }
    private struct State {
        var settings: MachineSettings
        var sessions: [String: Session] = [:]
        var attempts: [String: [Date]] = [:]
    }

    private let state: Mutex<State>
    private let settingsURL: URL?
    private let iterations: Int
    private let logger: Logger
    /// Hex token the shell reads from `AppPaths.shellTokenFile`; nil when no token file is used.
    public let shellToken: String?

    /// - Parameters:
    ///   - settingsURL: where `MachineSettings` are read and written; nil keeps them in memory (tests).
    ///   - shellTokenURL: the 0600 token file created on first start; nil disables the token.
    ///   - iterations: PBKDF2 rounds; tests lower it.
    public init(settingsURL: URL?, shellTokenURL: URL?, iterations: Int = 600_000, logger: Logger) {
        self.settingsURL = settingsURL
        self.iterations = iterations
        self.logger = logger
        state = Mutex(State(settings: settingsURL.map { MachineSettings.load(from: $0, logger: logger) } ?? MachineSettings()))
        shellToken = shellTokenURL.map { Self.loadOrCreateToken(at: $0, logger: logger) }
    }

    // MARK: Passwords

    public func isOpen(_ role: Role) -> Bool { state.withLock { $0.settings.passwords[role.rawValue] == nil } }

    /// Sets (or with nil clears) the password of a role and persists the settings.
    public func setPassword(_ password: String?, for role: Role) throws {
        let record = password.map { pw -> MachineSettings.PasswordRecord in
            var salt = Data(count: 16)
            _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
            return MachineSettings.PasswordRecord(salt: salt, hash: Self.pbkdf2(pw, salt: salt, iterations: iterations), iterations: iterations)
        }
        try rewrite("passwords", [role.rawValue: try record.map { try JSONValue(encoding: $0) }]) { settings, _ in settings.passwords[role.rawValue] = record }
        logger.info("role password \(record == nil ? "cleared" : "set")", metadata: ["role": "\(role)"])
    }

    /// The sync settings as stored (defaults when the file has none).
    public var syncSettings: SyncSettings { state.withLock { $0.settings.sync } ?? SyncSettings() }

    /// Stores the given sync members (`sync.set`, DESIGN.md §23.2) next to the passwords; the others keep the file's
    /// values. Returns the merged settings, to apply live.
    public func setSync(_ members: [String: JSONValue]) throws -> SyncSettings {
        var sync = SyncSettings()
        try rewrite("sync", members) { settings, object in
            sync = (try? JSONDecoder().decode(SyncSettings.self, from: JSONEncoder().encode(JSONValue.object(object)))) ?? SyncSettings()
            settings.sync = sync
        }
        logger.info("sync settings set", metadata: ["interface": "\(sync.interface)", "port": "\(sync.port)", "target": "\(sync.target)"])
        return sync
    }

    struct UnreadableSettings: Error, CustomStringConvertible, Equatable {
        var description = "settings.json could not be read; fix or remove it first"
    }

    /// Re-reads settings.json and sets only `members` of the top-level object `key` (nil removes one), keeping every
    /// other member, unknown and unreadable ones too, and hand edits made while the engine runs (B79). A file that
    /// exists but does not parse, or whose `passwords` is not an object, is not overwritten; a missing one is created.
    /// The copy in memory then takes the fields of
    /// the file as written, so a hand-added password takes effect now, not at the next start (B82); `apply` gets the
    /// merged `key` object and sets it in memory too. Without a file (tests) the copy in memory is the base.
    private func rewrite(_ key: String, _ members: [String: JSONValue?], apply: (inout MachineSettings, [String: JSONValue]) -> Void) throws {
        try state.withLock { s in
            var root = (try? JSONValue(encoding: s.settings).object) ?? [:]
            if let settingsURL {
                root = [:]
                do {
                    let data = try Data(contentsOf: settingsURL)
                    guard let object = try JSONDecoder().decode(JSONValue.self, from: data).object else { throw UnreadableSettings() }
                    root = object
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                } catch {
                    logger.error("settings.json not written: it could not be read", metadata: ["error": "\(error)"])
                    throw UnreadableSettings()
                }
            }
            if let passwords = root["passwords"], passwords.object == nil {
                // replacing it with the one record written would open every other role in memory (B82)
                logger.error("settings.json not written: passwords could not be read")
                throw UnreadableSettings(description: "passwords in settings.json could not be read; fix it first")
            }
            var object = root[key]?.object ?? [:]  // a member that is not an object was unreadable; the command replaces it
            for (member, value) in members { object[member] = value }
            root[key] = .object(object)
            if let settingsURL {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(JSONValue.object(root))
                try data.write(to: settingsURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
                if let file = try? JSONDecoder().decode(MachineSettings.self, from: data) {
                    for problem in file.problems { logger.error("settings.json: field ignored", metadata: ["problem": "\(problem)"]) }
                    s.settings.take(file)
                }
            }
            apply(&s.settings, object)
        }
    }

    public func verify(_ password: String, for role: Role) -> Bool {
        guard let record = state.withLock({ $0.settings.passwords[role.rawValue] }) else { return true }
        return Self.constantTimeEqual(Self.pbkdf2(password, salt: record.salt, iterations: record.iterations), record.hash)
    }

    // MARK: Sessions

    public enum LoginError: Error, Equatable { case rateLimited, wrongPassword }

    /// Verifies the password (an open role needs none) and returns a session cookie value.
    public func login(role: Role, password: String, from address: String) throws(LoginError) -> String {
        let now = Date()
        let limited = state.withLock { s -> Bool in
            var recent = (s.attempts[address] ?? []).filter { now.timeIntervalSince($0) < 60 }
            if recent.count >= Self.loginsPerMinute {
                s.attempts[address] = recent
                return true
            }
            recent.append(now)
            s.attempts[address] = recent
            return false
        }
        if limited { throw .rateLimited }
        guard verify(password, for: role) else {
            logger.warning("login failed", metadata: ["role": "\(role)", "from": "\(address)"])
            throw .wrongPassword
        }
        let cookie = Self.randomToken()
        state.withLock { $0.sessions[cookie] = Session(role: role, expires: now.addingTimeInterval(Self.sessionLifetime)) }
        return cookie
    }

    public func logout(cookie: String) { state.withLock { _ = $0.sessions.removeValue(forKey: cookie) } }

    public func role(forCookie cookie: String?) -> Role? {
        guard let cookie else { return nil }
        return state.withLock { s in
            guard let session = s.sessions[cookie] else { return nil }
            if session.expires < Date() {
                s.sessions.removeValue(forKey: cookie)
                return nil
            }
            return session.role
        }
    }

    public func role(forToken token: String?) -> Role? {
        guard let token, let shellToken, Self.constantTimeEqual(Data(token.utf8), Data(shellToken.utf8)) else { return nil }
        return .programmer
    }

    /// The highest role up to `requested` this client is entitled to: shell token → programmer, else the
    /// session cookie's role, else any open role. Monitor is always granted when open.
    public func grant(requested: Role, cookie: String?, token: String?) -> Role? {
        grant(requested: requested, sessionRole: role(forToken: token) ?? role(forCookie: cookie))
    }

    /// Same, with the session's role already resolved (the WebSocket handler resolves the cookie at upgrade time).
    public func grant(requested: Role, sessionRole: Role?) -> Role? {
        for candidate in Role.allCases.reversed() where candidate <= requested {
            if let sessionRole, candidate <= sessionRole { return candidate }
            if isOpen(candidate) { return candidate }
        }
        return nil
    }

    /// `Set-Cookie` header value for a session.
    public static func cookieHeader(_ value: String) -> String {
        "\(cookieName)=\(value); Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=\(Int(sessionLifetime))"
    }

    /// Finds the session cookie in a request's `Cookie` header.
    public static func cookie(in request: HTTPRequest) -> String? {
        guard let header = request.header("Cookie") else { return nil }
        for part in header.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces)
            if pair.hasPrefix(cookieName + "=") { return String(pair.dropFirst(cookieName.count + 1)) }
        }
        return nil
    }

    // MARK: Primitives

    static func pbkdf2(_ password: String, salt: Data, iterations: Int) -> Data {
        var derived = Data(count: 32)
        let pw = Array(password.utf8)
        let status = derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { s in
                pw.withUnsafeBufferPointer { p in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }, pw.count,
                        s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations), out.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed: \(status)")
        return derived
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func loadOrCreateToken(at url: URL, logger: Logger) -> String {
        if let existing = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), existing.count == 64 {
            return existing
        }
        let token = randomToken()
        do {
            try Data(token.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            logger.error("cannot write shell token", metadata: ["path": "\(url.path)", "error": "\(error)"])
        }
        return token
    }
}
