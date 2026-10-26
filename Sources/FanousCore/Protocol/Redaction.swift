// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

/// Per-role redaction of the `project` and `live` documents (DESIGN.md §11.2, backlog B25). A value that a role may
/// not see is replaced by a same-typed placeholder (never removed), so the UI keeps rendering. Applies to
/// welcome/snapshot documents and to patches alike, so a client's copy never desyncs. Roles gate commands separately.
public enum Redaction {
    struct Rule {
        let doc: String
        let pointer: JSONPointer
        let placeholder: JSONValue
        /// Lowest role that sees the real value.
        let from: Role
    }

    // Monitor (read-only, may be a wall display or a guest): no filesystem paths, host identity or addresses.
    // Operator: still no TLS fingerprint / Bonjour name (connection trust material is for the programmer).
    static let rules: [Rule] = [
        Rule(doc: "project", pointer: "/library/root", placeholder: "", from: .operator),
        Rule(doc: "live", pointer: "/library/root", placeholder: "", from: .operator),
        Rule(doc: "live", pointer: "/ingest", placeholder: [], from: .operator),  // job source/destination paths
        Rule(doc: "live", pointer: "/system/host", placeholder: "", from: .operator),
        Rule(doc: "live", pointer: "/system/addresses", placeholder: [], from: .operator),
        Rule(doc: "live", pointer: "/system/bonjour", placeholder: "", from: .programmer),
        Rule(doc: "live", pointer: "/system/tlsFingerprint", placeholder: "", from: .programmer),
    ]

    private static func applicable(_ doc: String, _ role: Role) -> [Rule] {
        rules.filter { $0.doc == doc && role < $0.from }
    }

    /// `value` as `role` may see it.
    public static func document(_ value: JSONValue, doc: String, role: Role) -> JSONValue {
        var result = value
        for rule in applicable(doc, role) where result[rule.pointer] != nil {
            try? result.set(rule.placeholder, at: rule.pointer)
        }
        return result
    }

    /// `patch` as `role` may see it: operations inside a redacted value are dropped, values written at or above one
    /// are redacted. The result may be empty; send it anyway so the client's revision chain stays unbroken.
    public static func patch(_ patch: JSONPatch, doc: String, role: Role) -> JSONPatch {
        let rules = applicable(doc, role)
        if rules.isEmpty { return patch }
        let operations = patch.operations.compactMap { operation -> JSONPatch.Operation? in
            let path: JSONPointer
            var value: JSONValue?
            switch operation {
            case .add(let p, let v): (path, value) = (p, v)
            case .replace(let p, let v): (path, value) = (p, v)
            case .remove(let p): (path, value) = (p, nil)
            }
            for rule in rules {
                let target = rule.pointer.tokens
                if path.tokens.count > target.count, path.tokens.starts(with: target) { return nil }
                if target.starts(with: path.tokens), let current = value {
                    let rest = JSONPointer(tokens: Array(target.dropFirst(path.tokens.count)))
                    if current[rest] != nil {
                        var redacted = current
                        try? redacted.set(rule.placeholder, at: rest)
                        value = redacted
                    }
                }
            }
            switch operation {
            case .add: return value.map { .add(path, $0) }
            case .replace: return value.map { .replace(path, $0) }
            case .remove: return operation
            }
        }
        return JSONPatch(operations: operations)
    }
}
