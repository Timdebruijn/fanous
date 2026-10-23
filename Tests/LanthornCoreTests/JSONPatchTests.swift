// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Testing

@testable import LanthornCore

private func value(_ json: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
}

/// `JSONPointer("literal")` resolves to `init(stringLiteral:)`; going through a variable picks the throwing parser.
private func ptr(_ string: String) throws -> JSONPointer {
    try JSONPointer(string)
}

private func patch(_ json: String) throws -> JSONPatch {
    try JSONDecoder().decode(JSONPatch.self, from: Data(json.utf8))
}

private func encoded<T: Encodable>(_ v: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(v), as: UTF8.self)
}

struct RFCExample: Sendable, CustomTestStringConvertible {
    let name: String
    let document: String
    let patch: String
    let expected: String
    var testDescription: String { name }
}

@Suite struct JSONPatchTests {
    // MARK: RFC 6902 appendix A (add / remove / replace only), JSON text verbatim from the RFC

    static let rfcExamples = [
        RFCExample(
            name: "A.1 adding an object member",
            document: #"{ "foo": "bar"}"#,
            patch: #"[ { "op": "add", "path": "/baz", "value": "qux" } ]"#,
            expected: #"{ "baz": "qux", "foo": "bar" }"#),
        RFCExample(
            name: "A.2 adding an array element",
            document: #"{ "foo": [ "bar", "baz" ] }"#,
            patch: #"[ { "op": "add", "path": "/foo/1", "value": "qux" } ]"#,
            expected: #"{ "foo": [ "bar", "qux", "baz" ] }"#),
        RFCExample(
            name: "A.3 removing an object member",
            document: #"{ "baz": "qux", "foo": "bar" }"#,
            patch: #"[ { "op": "remove", "path": "/baz" } ]"#,
            expected: #"{ "foo": "bar" }"#),
        RFCExample(
            name: "A.4 removing an array element",
            document: #"{ "foo": [ "bar", "qux", "baz" ] }"#,
            patch: #"[ { "op": "remove", "path": "/foo/1" } ]"#,
            expected: #"{ "foo": [ "bar", "baz" ] }"#),
        RFCExample(
            name: "A.5 replacing a value",
            document: #"{ "baz": "qux", "foo": "bar" }"#,
            patch: #"[ { "op": "replace", "path": "/baz", "value": "boo" } ]"#,
            expected: #"{ "baz": "boo", "foo": "bar" }"#),
        RFCExample(
            name: "A.10 adding a nested member object",
            document: #"{ "foo": "bar" }"#,
            patch: #"[ { "op": "add", "path": "/child", "value": { "grandchild": { } } } ]"#,
            expected: #"{ "foo": "bar", "child": { "grandchild": { } } }"#),
        RFCExample(
            name: "A.16 adding an array value",
            document: #"{ "foo": [ "bar" ] }"#,
            patch: #"[ { "op": "add", "path": "/foo/-", "value": [ "abc", "def" ] } ]"#,
            expected: #"{ "foo": [ "bar", [ "abc", "def" ] ] }"#),
    ]

    @Test(arguments: rfcExamples) func rfc6902Examples(_ example: RFCExample) throws {
        var document = try value(example.document)
        try patch(example.patch).apply(to: &document)
        #expect(document == (try value(example.expected)))
    }

    // MARK: RFC 6901

    @Test func pointerEvaluationPerRFC6901Section5() throws {
        let json = #"""
            { "foo": ["bar", "baz"], "": 0, "a/b": 1, "c%d": 2, "e^f": 3, "g|h": 4,
              "i\\j": 5, "k\"l": 6, " ": 7, "m~n": 8 }
            """#
        let document = try value(json)
        let cases: [(String, JSONValue)] = [
            ("", document),
            ("/foo", ["bar", "baz"]),
            ("/foo/0", "bar"),
            ("/", 0),
            ("/a~1b", 1),
            ("/c%d", 2),
            ("/e^f", 3),
            ("/g|h", 4),
            ("/i\\j", 5),
            ("/k\"l", 6),
            ("/ ", 7),
            ("/m~0n", 8),
        ]
        for (pointer, expected) in cases {
            let p = try ptr(pointer)
            #expect(document[p] == expected, "pointer \(pointer)")
        }
        #expect(document["/foo/2" as JSONPointer] == nil)
        #expect(document["/foo/01" as JSONPointer] == nil)
        #expect(document["/foo/-" as JSONPointer] == nil)
        #expect(document["/nope/x" as JSONPointer] == nil)
        #expect(document["/a~1b/x" as JSONPointer] == nil)
    }

    @Test func pointerEscapesRoundTrip() throws {
        let p = try ptr("/a~1b/m~0n")
        #expect(p.tokens == ["a/b", "m~n"])
        #expect(p.description == "/a~1b/m~0n")
        #expect(try ptr("/~01").tokens == ["~1"])  // ~0 is decoded after ~1: not "/"
        #expect(JSONPointer(tokens: ["~1"]).description == "/~01")
        #expect(try ptr("").tokens.isEmpty)
        #expect(try ptr("/").tokens == [""])
        #expect(try ptr("/é/\u{1F39B}").description == "/é/\u{1F39B}")
    }

    @Test func pointerParentLastAppending() throws {
        let p = JSONPointer(tokens: []).appending("a").appending("b/c")
        #expect(p.description == "/a/b~1c")
        #expect(p.last == "b/c")
        #expect(p.parent == "/a")
        #expect(p.parent?.parent == "")
        #expect(p.parent?.parent?.parent == nil)
        #expect(try ptr("").last == nil)
    }

    @Test func invalidPointersThrow() {
        #expect(throws: JSONPointer.ParseError.missingLeadingSlash) { try ptr("a/b") }
        #expect(throws: JSONPointer.ParseError.invalidEscape) { try ptr("/a~2") }
        #expect(throws: JSONPointer.ParseError.invalidEscape) { try ptr("/a~") }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([JSONPointer].self, from: Data(#"["x"]"#.utf8)) }
    }

    @Test func pointerCodableIsItsStringForm() throws {
        #expect(try encoded([ptr("/a~1b")]) == #"["/a~1b"]"#)
        #expect(try JSONDecoder().decode([JSONPointer].self, from: Data(#"["/a~1b",""]"#.utf8)) == ["/a~1b", ""])
    }

    // MARK: Patch semantics

    @Test func dashAppendsToArrays() throws {
        var document: JSONValue = ["xs": [1, 2]]
        try JSONPatch(operations: [.add("/xs/-", 3), .add("/xs/-", nil)]).apply(to: &document)
        #expect(document == ["xs": [1, 2, 3, nil]])
        var root: JSONValue = [1]
        try JSONPatch(operations: [.add("/-", 2), .add("/0", 0)]).apply(to: &root)
        #expect(root == [0, 1, 2])
    }

    @Test func addReplacesExistingObjectMemberAndRootOperations() throws {
        var document: JSONValue = ["a": 1]
        try JSONPatch(operations: [.add("/a", 2)]).apply(to: &document)
        #expect(document == ["a": 2])
        try JSONPatch(operations: [.replace("", [1, 2])]).apply(to: &document)
        #expect(document == [1, 2])
        try JSONPatch(operations: [.add("", "x")]).apply(to: &document)
        #expect(document == "x")
    }

    @Test func missingPathErrors() {
        var document: JSONValue = ["a": ["b": 1], "xs": [1, 2]]
        let before = document
        #expect(throws: JSONPatch.PatchError.missingPath("/nope")) {
            try JSONPatch(operations: [.remove("/nope")]).apply(to: &document)
        }
        #expect(throws: JSONPatch.PatchError.missingPath("/nope/x")) {
            try JSONPatch(operations: [.add("/nope/x", 1)]).apply(to: &document)
        }
        #expect(throws: JSONPatch.PatchError.missingPath("/a/zzz")) {
            try JSONPatch(operations: [.replace("/a/zzz", 1)]).apply(to: &document)
        }
        #expect(throws: JSONPatch.PatchError.missingPath("/xs/2")) {
            try JSONPatch(operations: [.remove("/xs/2")]).apply(to: &document)
        }
        #expect(throws: JSONPatch.PatchError.missingPath("/xs/5/x")) {
            try JSONPatch(operations: [.add("/xs/5/x", 1)]).apply(to: &document)
        }
        #expect(document == before)
    }

    @Test func badIndexErrors() {
        var document: JSONValue = ["xs": [1, 2]]
        for path: JSONPointer in ["/xs/01", "/xs/x", "/xs/+1", "/xs/-1", "/xs/ 1", "/xs/"] {
            #expect(throws: JSONPatch.PatchError.invalidIndex(path)) {
                try JSONPatch(operations: [.add(path, 0)]).apply(to: &document)
            }
        }
        #expect(throws: JSONPatch.PatchError.invalidIndex("/xs/3")) {  // beyond the end: only the length is allowed
            try JSONPatch(operations: [.add("/xs/3", 0)]).apply(to: &document)
        }
        #expect(throws: JSONPatch.PatchError.invalidIndex("/xs/-")) {  // "-" names no existing element
            try JSONPatch(operations: [.remove("/xs/-")]).apply(to: &document)
        }
        #expect(throws: JSONPatch.PatchError.invalidIndex("/xs/-")) {
            try JSONPatch(operations: [.replace("/xs/-", 0)]).apply(to: &document)
        }
        #expect(document == ["xs": [1, 2]])
    }

    @Test func notAContainerAndUnsupportedErrors() throws {
        var document: JSONValue = ["a": 1]
        #expect(throws: JSONPatch.PatchError.notAContainer("/a/b")) {
            try JSONPatch(operations: [.add("/a/b", 1)]).apply(to: &document)
        }
        #expect(throws: JSONPatch.PatchError.notAContainer("/a/b/c")) {
            try JSONPatch(operations: [.add("/a/b/c", 1)]).apply(to: &document)
        }
        #expect(throws: JSONPatch.PatchError.unsupportedOperation("remove at the document root")) {
            try JSONPatch(operations: [.remove("")]).apply(to: &document)
        }
        for op in ["move", "copy", "test", "bogus"] {
            let json = #"[{"op":"\#(op)","path":"/a","from":"/b","value":1}]"#
            #expect(throws: JSONPatch.PatchError.unsupportedOperation(op)) { try patch(json) }
        }
        #expect(throws: DecodingError.self) { try patch(#"[{"op":"add","path":"/a"}]"#) }  // add needs a value
        #expect(throws: DecodingError.self) { try patch(#"[{"op":"add","path":"a","value":1}]"#) }  // bad pointer
    }

    @Test func applyIsAtomic() {
        var document: JSONValue = ["a": 1]
        #expect(throws: JSONPatch.PatchError.missingPath("/zzz")) {
            try JSONPatch(operations: [.add("/b", 2), .remove("/zzz")]).apply(to: &document)
        }
        #expect(document == ["a": 1])
    }

    // MARK: Codable

    @Test func documentRoundTripsThroughJSONEncoder() throws {
        let document: JSONValue = [
            "int": 42, "negative": -7, "zero": 0, "double": 0.1, "big": 1e300, "exp": 2.5e-8,
            "string": "héllo wörld 日本語 \u{1F39B}\u{FE0F} \"quoted\" \\ /",
            "nested": [[1, [2, [3, nil]]], [], [[]]],
            "null": nil, "yes": true, "no": false,
            "object": ["empty": [:], "deep": ["k": ["v"]]],
        ]
        let data = try JSONEncoder().encode(document)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == document)
        #expect(try value(#"{"a":1,"b":[true,null]}"#) == ["a": 1, "b": [true, nil]])
    }

    @Test func wholeNumbersEncodeWithoutFractionalPart() throws {
        #expect(try encoded(JSONValue.number(1)) == "1")
        #expect(try encoded(JSONValue.number(-3)) == "-3")
        #expect(try encoded(JSONValue.number(0)) == "0")
        #expect(try encoded(JSONValue.number(1.0)) == "1")
        #expect(try encoded(JSONValue.number(9_007_199_254_740_992)) == "9007199254740992")
        #expect(try encoded(JSONValue.number(1.5)) == "1.5")
        #expect(try encoded(JSONValue.number(0.1)) == "0.1")
        let doc: JSONValue = ["a": 1, "b": [true, nil]]
        #expect(try encoded(doc) == #"{"a":1,"b":[true,null]}"#)
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data("1e300".utf8)) == .number(1e300))
    }

    @Test func decodingKeepsKindsApart() throws {
        let v = try value(#"[true, false, 1, 0, 1.5, "true", "1", null, {}, []]"#)
        #expect(v == [true, false, 1, 0, 1.5, "true", "1", nil, [:], []])
        #expect(v[0]?.bool == true)
        #expect(v[2]?.bool == nil)
        #expect(v[5]?.string == "true")
        #expect(v[7] == .null)
    }

    @Test func patchEncodesInRFC6902Shape() throws {
        #expect(try encoded(JSONPatch.Operation.replace("/a/b", 1)) == #"{"op":"replace","path":"/a/b","value":1}"#)
        #expect(try encoded(JSONPatch.Operation.add("/a~1b", nil)) == #"{"op":"add","path":"/a~1b","value":null}"#)
        #expect(try encoded(JSONPatch.Operation.remove("/a")) == #"{"op":"remove","path":"/a"}"#)
        let p = JSONPatch(operations: [.add("/x", ["k": 1]), .remove("/y"), .replace("", 2.5)])
        #expect(try encoded(p) == #"[{"op":"add","path":"/x","value":{"k":1}},{"op":"remove","path":"/y"},{"op":"replace","path":"","value":2.5}]"#)
        #expect(try patch(try encoded(p)) == p)
        #expect(try patch(#"[{"op":"add","path":"/a","value":null}]"#).operations == [.add("/a", nil)])
    }

    // MARK: Accessors and literals

    @Test func stringInterpolationLiteral() {
        let n = 3
        let doc: JSONValue = ["message": "slot \(n)", "plain": "x"]
        #expect(doc == ["message": "slot 3", "plain": .string("x")])
    }

    @Test func accessorsAndSubscripts() {
        let doc: JSONValue = ["a": 1, "f": 1.5, "s": "x", "b": true, "xs": [10, 20], "o": ["k": nil]]
        #expect(doc["a"]?.int == 1)
        #expect(doc["a"]?.double == 1)
        #expect(doc["f"]?.int == nil)
        #expect(doc["f"]?.double == 1.5)
        #expect(doc["s"]?.string == "x")
        #expect(doc["s"]?.int == nil)
        #expect(doc["b"]?.bool == true)
        #expect(doc["xs"]?[1] == 20)
        #expect(doc["xs"]?[2] == nil)
        #expect(doc["xs"]?[-1] == nil)
        #expect(doc["xs"]?.array?.count == 2)
        #expect(doc["o"]?.object?.count == 1)
        #expect(doc["o"]?["k"] == .null)  // present null is not nil
        #expect(doc["missing"] == nil)
        #expect(doc["a"]?["x"] == nil)
        #expect(doc.object?.count == 6)
    }

    @Test func setCreatesIntermediateObjects() throws {
        var doc: JSONValue = ["a": 1]
        try doc.set(5, at: "/x/y/z")
        #expect(doc == ["a": 1, "x": ["y": ["z": 5]]])
        try doc.set("w", at: "/x/y/z")
        #expect(doc["/x/y/z" as JSONPointer] == "w")
        try doc.set(2, at: "/a2")
        #expect(doc["a2"] == 2)
        try doc.set(["n": 1], at: "")
        #expect(doc == ["n": 1])
    }

    @Test func setNeverCreatesArraysAndLeavesDocumentUntouchedOnError() throws {
        var doc: JSONValue = ["xs": [1, 2], "n": 1]
        let before = doc
        #expect(throws: JSONPatch.PatchError.missingPath("/xs/2/k")) { try doc.set(1, at: "/xs/2/k") }
        #expect(throws: JSONPatch.PatchError.invalidIndex("/xs/k/j")) { try doc.set(1, at: "/xs/k/j") }
        #expect(throws: JSONPatch.PatchError.notAContainer("/n/k")) { try doc.set(1, at: "/n/k") }
        #expect(doc == before)
        try doc.set(9, at: "/xs/0")  // existing element is replaced
        try doc.set(3, at: "/xs/-")  // "-" appends
        #expect(doc["xs"] == [9, 2, 3])
    }

    @Test func removeAt() throws {
        var doc: JSONValue = ["a": ["b": 1, "c": 2], "xs": [1, 2, 3]]
        try doc.remove(at: "/a/b")
        try doc.remove(at: "/xs/1")
        #expect(doc == ["a": ["c": 2], "xs": [1, 3]])
        #expect(throws: JSONPatch.PatchError.missingPath("/a/b")) { try doc.remove(at: "/a/b") }
        #expect(throws: JSONPatch.PatchError.unsupportedOperation("remove at the document root")) { try doc.remove(at: "") }
        #expect(doc == ["a": ["c": 2], "xs": [1, 3]])
    }

    // MARK: Diff

    static let diffPairs: [(JSONValue, JSONValue)] = [
        ([:], [:]),
        ([:], ["a": 1]),  // key added
        (["a": 1], [:]),  // key removed
        (["a": 1], ["a": 2]),  // value changed
        (["a": 1, "b": 2, "c": 3], ["a": 1, "b": 20, "d": 4]),  // added + removed + changed
        (["a": ["b": ["c": 1]]], ["a": ["b": ["c": 2, "d": nil]]]),  // nested objects
        (["xs": [1, 2, 3]], ["xs": [1, 9, 3]]),  // arrays of equal length: element-wise
        (["xs": [1, 2, 3]], ["xs": [1, 2]]),  // shorter
        (["xs": [1, 2]], ["xs": [1, 2, 3]]),  // longer
        (["xs": [[1, 2], [3]]], ["xs": [[1, 5], [3, 4]]]),  // nested arrays, mixed lengths
        (["xs": [["k": 1], ["k": 2]]], ["xs": [["k": 1], ["k": 3, "m": true]]]),  // objects inside arrays
        (["a": 1], ["a": "1"]),  // number to string
        (["a": nil], ["a": false]),  // null to bool
        (["a": [1]], ["a": ["b": 1]]),  // array to object
        (["a": ["b": 1]], ["a": nil]),  // object to null
        ([1, 2], [1, 3]),  // root arrays
        ([1, 2], [1]),
        (1, 2),  // root scalars
        (1, "x"),
        (nil, [:]),  // root kind change
        ([:], [1]),
        ([[]], [[1]]),
        (["a/b": 1, "m~n": 2, "": 3], ["a/b": 2, "m~n": 2, "x/~1": 4]),  // keys that need pointer escaping
        (["k": "héllo \u{1F39B}"], ["k": "wörld"]),
    ]

    @Test(arguments: diffPairs.indices) func diffAppliesBackToTarget(_ i: Int) throws {
        let (a, b) = Self.diffPairs[i]
        let diff = JSONPatch.diff(from: a, to: b)
        var document = a
        try diff.apply(to: &document)
        #expect(document == b)
        // the patch survives being sent over the wire
        document = a
        try patch(try encoded(diff)).apply(to: &document)
        #expect(document == b)
        #expect(JSONPatch.diff(from: a, to: a).isEmpty)
        #expect(JSONPatch.diff(from: b, to: b).isEmpty)
        #expect(diff.isEmpty == (a == b))
    }

    @Test func diffShapeAndOrder() {
        let old: JSONValue = ["b": 1, "a": 1, "d": 1, "xs": [1, 2], "ys": [1, 2]]
        let new: JSONValue = ["b": 2, "c": 1, "d": 1, "xs": [1, 3], "ys": [1]]
        #expect(JSONPatch.diff(from: old, to: new).operations == [
            .remove("/a"),
            .replace("/b", 2),
            .add("/c", 1),
            .replace("/xs/1", 3),
            .replace("/ys", [1]),
        ])
        #expect(JSONPatch.diff(from: 1, to: "x").operations == [.replace("", "x")])
        #expect(JSONPatch.diff(from: ["a": 1], to: ["a": 1]).operations == [])
        #expect(JSONPatch.diff(from: ["a/b": 1], to: [:]).operations == [.remove("/a~1b")])
    }
}
