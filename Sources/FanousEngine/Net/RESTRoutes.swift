// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore

/// The engine's REST routes (DESIGN.md §11): what `HTTPSServer` asks before it serves a static file. A value with the
/// few things the routes read, so a test calls `handle` without a GPU or a socket; `Engine.start` makes the live one.
struct RESTRoutes: Sendable {
    let auth: RoleAuth
    let store: StateStore
    let ingestAPI: IngestAPI
    /// The index of the moment (B51): read per request, never a fixed one.
    let library: @Sendable () -> LibraryIndex
    let encoder: JSONEncoder
    let dmx: DMXStore
    let thumbnails: URL
    let logFile: URL
    let startedAt: Date
    /// `/metrics` and `/api/metrics`: they read the render service, sync and preview, which live in the engine.
    let metricsJSON: @Sendable () -> HTTPResponse
    let metricsText: @Sendable () -> HTTPResponse

    /// Whether the request's bearer token (the shell), its session cookie or an open role grants `role`.
    func allowed(_ role: Role, _ request: HTTPRequest) -> Bool {
        let bearer = request.header("Authorization").flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
        let sessionRole = auth.role(forToken: bearer) ?? auth.role(forCookie: RoleAuth.cookie(in: request))
        return auth.grant(requested: role, sessionRole: sessionRole) == role
    }
    func programmerAllowed(_ request: HTTPRequest) -> Bool { allowed(.programmer, request) }

    /// 405 for a route that only takes POST.
    static let postOnly = HTTPResponse(status: 405, headers: [HTTPHeader("Allow", "POST")])

    /// 200 with `value` as JSON (an empty body if it does not encode).
    func json(_ value: some Encodable) -> HTTPResponse { .json(200, Array((try? encoder.encode(value)) ?? Data())) }

    /// Where a large upload streams before the route runs: the role is checked before the body is accepted.
    func uploadTarget(_ request: HTTPRequest) -> URL? { programmerAllowed(request) ? ingestAPI.uploadTarget(for: request) : nil }

    /// The response for `request`; nil hands it to the static files.
    func handle(_ request: HTTPRequest) -> HTTPResponse? {
        if request.path.hasPrefix("/api/ingest") || request.path.hasPrefix("/api/upload/") {
            if request.method != "GET", !programmerAllowed(request) { return .text(403, "programmer role required") }
            if request.method == "GET", !allowed(.operator, request) { return .text(403, "operator role required") }  // job lists carry file paths
            return ingestAPI.handle(request, uploadedFile: nil)
        }
        let library = self.library()
        if request.path == "/api/library/rescan" {
            // any role: it only re-reads the disk
            library.rescan()
            return .text(200, "rescanned")
        }
        if request.path == "/api/library/folder" {
            // POST {"number": N, "name": "…"} creates NNN_name under the root (and the root itself)
            guard request.method == "POST" else { return Self.postOnly }
            guard programmerAllowed(request) else { return .text(403, "programmer role required") }
            guard let body = try? JSONDecoder().decode(JSONValue.self, from: Data(request.body)), let number = body["number"]?.int, (1...255).contains(number),
                let name = body["name"]?.string, !name.trimmingCharacters(in: .whitespaces).isEmpty
            else { return .text(400, "expected {\"number\": 1–255, \"name\": …}") }
            switch library.createFolder(number: number, name: name) {  // check and create under one lock (B141)
            case .exists: return .text(409, "folder \(number) exists")  // also one an upload just made
            case .failed: return .text(500, "cannot create the folder")  // a root that cannot be written (B142)
            case .created(let url):
                library.rescan()
                return .text(200, url.lastPathComponent)
            }
        }
        switch request.path {
        case "/healthz":
            let health: JSONValue = [
                "status": "ok", "version": .string(FanousVersion.string), "uptimeSeconds": .number(Double(Int(Date().timeIntervalSince(startedAt)))),
                "chip": .string(SystemInfo.chipName),
            ]
            return json(health)
        case "/api/live":
            return json(dmx.snapshot())
        case "/api/login":
            guard request.method == "POST" else { return Self.postOnly }
            guard let body = try? JSONDecoder().decode(JSONValue.self, from: Data(request.body)),
                let role = body["role"]?.string.flatMap(Role.init(rawValue:))
            else { return .text(400, "expected {\"role\": …, \"password\": …}") }
            do {
                let cookie = try auth.login(role: role, password: body["password"]?.string ?? "", from: request.remoteAddress)
                return HTTPResponse(status: 204, headers: [HTTPHeader("Set-Cookie", RoleAuth.cookieHeader(cookie))])
            } catch RoleAuth.LoginError.rateLimited {
                return .text(429, "too many attempts; wait a minute")
            } catch {
                return .text(401, "wrong password")
            }
        case "/api/logout":
            guard request.method == "POST" else { return Self.postOnly }
            if let cookie = RoleAuth.cookie(in: request) { auth.logout(cookie: cookie) }
            return HTTPResponse(status: 204, headers: [HTTPHeader("Set-Cookie", "\(RoleAuth.cookieName)=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0")])
        case "/metrics":
            return metricsJSON()
        case "/api/logs":
            guard programmerAllowed(request) else { return .text(403, "programmer role required") }
            // the last 64 KB of the engine log (System › Logs); `?download=1` sends the whole file
            let file = logFile
            guard let handle = try? FileHandle(forReadingFrom: file) else { return .text(404, "no log file") }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            let download = request.target.contains("download=1")
            let from = download ? 0 : max(0, Int(size) - 65_536)
            try? handle.seek(toOffset: UInt64(from))
            let data = (try? handle.readToEnd()) ?? Data()
            return HTTPResponse(
                status: 200,
                headers: [HTTPHeader("Content-Type", "text/plain; charset=utf-8")] + (download ? [HTTPHeader("Content-Disposition", "attachment; filename=\"fanousd.log\"")] : []),
                body: Array(data))
        case "/api/session":
            let role = auth.role(forCookie: RoleAuth.cookie(in: request))
            let session: JSONValue = [
                "role": role.map { .string($0.rawValue) } ?? .null,
                "open": .array(Role.allCases.filter { auth.isOpen($0) }.map { .string($0.rawValue) }),
            ]
            return .json(200, Array(store.encode(session).utf8))
        case "/api/patch":
            return json(dmx.currentPatch)
        case "/api/gdtf":
            return HTTPResponse(
                status: 200,
                headers: [HTTPHeader("Content-Type", "application/zip"), HTTPHeader("Content-Disposition", "attachment; filename=\"Fanous.gdtf\"")],
                body: GDTFExporter.gdtf())
        case "/api/channel-map.md":
            return .text(200, ChannelMapDocument.markdown())
        case "/api/channel-map.json":
            return .json(200, Array(store.encode(ChannelMapDocument.json()).utf8))
        case "/api/library":
            // below operator: no absolute paths (B25); the UI keys files by `path`, which stays unique relative to the root
            let snapshot = allowed(.operator, request) ? library.snapshot : library.snapshot.redacted()
            return json(snapshot)
        case let path where path.hasPrefix("/api/thumbnail/"):
            // thumbnail file names are hashes written by the engine itself: no path component may escape the cache
            let name = String(path.dropFirst("/api/thumbnail/".count))
            guard !name.contains("/"), !name.contains(".."), name.hasSuffix(".jpg"),
                let data = try? Data(contentsOf: thumbnails.appending(path: name))
            else { return .text(404, "no thumbnail") }
            return HTTPResponse(status: 200, headers: [HTTPHeader("Content-Type", "image/jpeg"), HTTPHeader("Cache-Control", "max-age=86400")], body: Array(data))
        case "/api/metrics":
            return metricsText()
        default:
            return nil
        }
    }
}
