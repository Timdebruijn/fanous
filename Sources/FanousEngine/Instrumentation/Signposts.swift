// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import os

/// Intervals for Instruments (os_signpost, Metal System Trace), subsystem `org.fanous`: `tick` (one compositor tick),
/// `gpu wait` (a tick waiting for its oldest frame in flight), `decode` (one frame on a layer's decode thread) and `open`
/// (a layer opening its media). Off unless the process starts with `FANOUS_SIGNPOSTS=1`: signposts of an ordinary
/// category are written to the persistent log store whether a tool records or not (about 600 a second here), and the
/// dynamicTracing category, meant for this, was not switched on by any `xctrace` template tried (macOS 27.2). Off is
/// `OSLog.disabled`, on which `os_signpost` returns at once.
/// The C-style `os_signpost`, not `OSSignposter`: its `beginInterval` allocates a state object per call, also when off,
/// and the compositor thread keeps a malloc budget (DESIGN.md §4.6).
/// Callers do not import os (its `Logger` would clash with swift-log's).
enum Signposts {
    static let log = ProcessInfo.processInfo.environment["FANOUS_SIGNPOSTS"] == "1" ? OSLog(subsystem: "org.fanous", category: "signposts") : .disabled

    static func begin(_ name: StaticString, id: OSSignpostID = .exclusive) { os_signpost(.begin, log: log, name: name, signpostID: id) }
    static func end(_ name: StaticString, id: OSSignpostID = .exclusive) { os_signpost(.end, log: log, name: name, signpostID: id) }
    /// An id for intervals that overlap other threads' intervals of the same name (one per decoder).
    static func id(_ object: AnyObject) -> OSSignpostID { OSSignpostID(log: log, object: object) }
}
