// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Testing

@testable import FanousCore

@Suite struct RedactionTests {
    static let live: JSONValue = [
        "library": ["root": "/Users/x/lib", "fileCount": 3],
        "ingest": [["source": "/Users/x/a.mov"]],
        "system": ["host": "mac.local", "addresses": ["10.0.0.5"], "port": 8443, "bonjour": "mac._fanous._tcp", "tlsFingerprint": "AB:CD"],
        "layers": [["name": "a"]],
    ]
    static let project: JSONValue = ["name": "Show", "library": ["root": "/Users/x/lib"]]

    @Test func documentPerRole() {
        let monitor = Redaction.document(Self.live, doc: "live", role: .monitor)
        #expect(monitor["library"]?["root"]?.string == "")
        #expect(monitor["library"]?["fileCount"]?.int == 3)
        #expect(monitor["ingest"]?.array?.isEmpty == true)
        #expect(monitor["system"]?["host"]?.string == "")
        #expect(monitor["system"]?["addresses"]?.array?.isEmpty == true)
        #expect(monitor["system"]?["port"]?.int == 8443)
        #expect(monitor["layers"] == Self.live["layers"])

        let op = Redaction.document(Self.live, doc: "live", role: .operator)
        #expect(op["library"]?["root"]?.string == "/Users/x/lib")
        #expect(op["system"]?["host"]?.string == "mac.local")
        #expect(op["system"]?["tlsFingerprint"]?.string == "")
        #expect(op["system"]?["bonjour"]?.string == "")

        #expect(Redaction.document(Self.live, doc: "live", role: .programmer) == Self.live)
        #expect(Redaction.document(Self.project, doc: "project", role: .monitor)["library"]?["root"]?.string == "")
        #expect(Redaction.document(Self.project, doc: "project", role: .operator) == Self.project)
        #expect(Redaction.document(["a": 1], doc: "live", role: .monitor) == ["a": 1])  // absent paths stay absent
    }

    /// Whatever the patch: redacted document + redacted patch == redacted (document + patch).
    @Test func patchedRedactedCopyMatchesRedactedPatchedDocument() throws {
        let patches: [JSONPatch] = [
            JSONPatch(operations: [.replace("/library/root", "/other"), .replace("/library/fileCount", 4)]),
            JSONPatch(operations: [.replace("/library", ["root": "/new", "fileCount": 9])]),
            JSONPatch(operations: [.add("/ingest/0/state", "done"), .add("/ingest/-", ["source": "/z"])]),
            JSONPatch(operations: [.replace("/system", ["host": "h", "addresses": ["1.2.3.4"], "port": 1, "bonjour": "b", "tlsFingerprint": "x"])]),
            JSONPatch(operations: [.replace("/system/tlsFingerprint", "EF"), .replace("/system/port", 9)]),
            JSONPatch(operations: [.replace("/ingest", [["source": "/q"]])]),
            JSONPatch(operations: [.replace("/layers/0/name", "b")]),
        ]
        for role in Role.allCases {
            for p in patches {
                var client = Redaction.document(Self.live, doc: "live", role: role)
                try Redaction.patch(p, doc: "live", role: role).apply(to: &client)
                var full = Self.live
                try p.apply(to: &full)
                #expect(client == Redaction.document(full, doc: "live", role: role), "\(role) \(p)")
            }
        }
    }

    @Test func monitorPatchDropsOperationsInsideRedactedValues() {
        let patch = JSONPatch(operations: [.replace("/library/root", "/x"), .add("/ingest/-", ["source": "/z"])])
        #expect(Redaction.patch(patch, doc: "live", role: .monitor).operations == [.replace("/library/root", "")])
        #expect(Redaction.patch(patch, doc: "live", role: .operator) == patch)
        #expect(Redaction.patch(patch, doc: "project", role: .monitor).operations.last == patch.operations.last)  // /ingest is live-only
    }
}
