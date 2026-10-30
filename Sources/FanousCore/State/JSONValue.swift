// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

fileprivate typealias PatchError = JSONPatch.PatchError

/// A JSON document. Numbers are `Double`; whole numbers within ±2^53 encode without a fractional part.
public enum JSONValue: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Int64.self) {
            self = .number(Double(v))
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? c.decode([String: JSONValue].self) {
            self = .object(v)
        } else if c.decodeNil() {
            self = .null
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v):
            if v.rounded() == v, abs(v) <= 9_007_199_254_740_992 {  // 2^53
                try c.encode(Int64(v))
            } else {
                try c.encode(v)
            }
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

/// Lets `["message": "slot \(n)"]` build a `.string`.
extension JSONValue: ExpressibleByStringInterpolation {
    public init(stringInterpolation: DefaultStringInterpolation) {
        self = .string(String(stringInterpolation: stringInterpolation))
    }
}

// MARK: - Accessors

extension JSONValue {
    public var object: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    public var string: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    public var double: Double? {
        if case .number(let v) = self { return v }
        return nil
    }

    /// The number as an `Int`, only if it is a whole number that fits.
    public var int: Int? {
        if case .number(let v) = self { return Int(exactly: v) }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        object?[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard let a = array, a.indices.contains(index) else { return nil }
        return a[index]
    }

    /// The value at `pointer`, or nil if the path does not resolve. A present JSON `null` is `.null`, not nil.
    public subscript(pointer: JSONPointer) -> JSONValue? {
        var current = self
        for token in pointer.tokens {
            switch current {
            case .object(let o):
                guard let next = o[token] else { return nil }
                current = next
            case .array(let a):
                guard let i = JSONPointer.arrayIndex(token), i < a.count else { return nil }
                current = a[i]
            default:
                return nil
            }
        }
        return current
    }
}

// MARK: - Editing

extension JSONValue {
    /// Writes `value` at `pointer`. Missing object members along the path are created as empty objects (arrays are
    /// never created or extended implicitly). An existing array element is replaced; the token `-` appends.
    /// Throws without modifying `self`.
    public mutating func set(_ value: JSONValue, at pointer: JSONPointer) throws {
        try perform(.set(value), at: pointer)
    }

    /// Removes the object member or array element at `pointer`. Throws without modifying `self`.
    public mutating func remove(at pointer: JSONPointer) throws {
        try perform(.remove, at: pointer)
    }

    enum Edit {
        case add(JSONValue)  // RFC 6902 add: object member set/replaced, array element inserted or appended
        case replace(JSONValue)  // target must exist
        case set(JSONValue)  // like add, but replaces an array element and creates missing intermediate objects
        case remove  // target must exist
    }

    // ponytail: rebuilds (copies) each container on the path; fine for small documents, in-place mutation if not.
    mutating func perform(_ edit: Edit, at path: JSONPointer) throws {
        guard let last = path.last else {
            switch edit {
            case .add(let v), .replace(let v), .set(let v): self = v
            case .remove: throw PatchError.unsupportedOperation("remove at the document root")
            }
            return
        }
        let createMissing: Bool
        if case .set = edit { createMissing = true } else { createMissing = false }
        self = try edited(edit, walking: path.tokens.dropLast(), to: last, path: path, createMissing: createMissing)
    }

    private func edited(
        _ edit: Edit, walking tokens: ArraySlice<String>, to last: String, path: JSONPointer, createMissing: Bool
    ) throws -> JSONValue {
        guard let token = tokens.first else { return try applying(edit, token: last, path: path) }
        let rest = tokens.dropFirst()
        switch self {
        case .object(var o):
            let child: JSONValue
            if let existing = o[token] {
                child = existing
            } else if createMissing {
                child = .object([:])
            } else {
                throw PatchError.missingPath(path)
            }
            o[token] = try child.edited(edit, walking: rest, to: last, path: path, createMissing: createMissing)
            return .object(o)
        case .array(var a):
            let i = try Self.existingIndex(token, count: a.count, path: path)
            a[i] = try a[i].edited(edit, walking: rest, to: last, path: path, createMissing: createMissing)
            return .array(a)
        default:
            throw PatchError.notAContainer(path)
        }
    }

    /// `self` is the parent container; applies `edit` to its child `token`.
    private func applying(_ edit: Edit, token: String, path: JSONPointer) throws -> JSONValue {
        switch self {
        case .object(var o):
            switch edit {
            case .add(let v), .set(let v):
                o[token] = v
            case .replace(let v):
                guard o.keys.contains(token) else { throw PatchError.missingPath(path) }
                o[token] = v
            case .remove:
                guard o.keys.contains(token) else { throw PatchError.missingPath(path) }
                o.removeValue(forKey: token)
            }
            return .object(o)
        case .array(var a):
            switch edit {
            case .add(let v):
                if token == "-" {
                    a.append(v)
                } else {
                    guard let i = JSONPointer.arrayIndex(token), i <= a.count else { throw PatchError.invalidIndex(path) }
                    a.insert(v, at: i)
                }
            case .set(let v):
                if token == "-" {
                    a.append(v)
                } else {
                    a[try Self.existingIndex(token, count: a.count, path: path)] = v
                }
            case .replace(let v):
                a[try Self.existingIndex(token, count: a.count, path: path)] = v
            case .remove:
                a.remove(at: try Self.existingIndex(token, count: a.count, path: path))
            }
            return .array(a)
        default:
            throw PatchError.notAContainer(path)
        }
    }

    /// Index of an existing element: malformed (or `-`) is `invalidIndex`, well-formed but out of range `missingPath`.
    private static func existingIndex(_ token: String, count: Int, path: JSONPointer) throws -> Int {
        guard let i = JSONPointer.arrayIndex(token) else { throw PatchError.invalidIndex(path) }
        guard i < count else { throw PatchError.missingPath(path) }
        return i
    }
}

// MARK: - JSON Pointer (RFC 6901)

public struct JSONPointer: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public enum ParseError: Error, Equatable {
        case missingLeadingSlash
        case invalidEscape
    }

    /// Unescaped reference tokens; empty for the root (whole document).
    public let tokens: [String]

    public init(tokens: [String]) {
        self.tokens = tokens
    }

    /// Parses `""` (root) or `"/a/b"`. `~1` is `/`, `~0` is `~`; any other `~` sequence is an error.
    /// Note: `JSONPointer("/x")` with a string *literal* argument calls `init(stringLiteral:)` (which traps on
    /// invalid input), not this initializer. Pass a `String` variable to get the throwing parse.
    public init(_ string: String) throws {
        let scalars = string.unicodeScalars
        guard let first = scalars.first else {
            tokens = []
            return
        }
        guard first == "/" else { throw ParseError.missingLeadingSlash }
        tokens = try scalars.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(Self.unescape)
    }

    /// For literals in code; an invalid literal is a programmer error.
    public init(stringLiteral value: String) {
        do { try self.init(value) } catch { preconditionFailure("Invalid JSON pointer literal: \(value)") }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let string = try c.decode(String.self)
        do {
            try self.init(string)
        } catch {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid JSON pointer: \(string)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }

    public var description: String {
        tokens.map { "/" + Self.escape($0) }.joined()
    }

    public func appending(_ token: String) -> JSONPointer {
        JSONPointer(tokens: tokens + [token])
    }

    /// The last token; nil for the root.
    public var last: String? {
        tokens.last
    }

    /// A decimal array index without leading zeros (RFC 6901 §4). `-` and anything else is nil.
    static func arrayIndex(_ token: String) -> Int? {
        guard !token.isEmpty, token.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        guard token == "0" || token.utf8.first != 0x30 else { return nil }
        return Int(token)
    }

    private static func unescape(_ token: Substring.UnicodeScalarView) throws -> String {
        var out = String.UnicodeScalarView()
        var it = token.makeIterator()
        while let c = it.next() {
            guard c == "~" else {
                out.append(c)
                continue
            }
            switch it.next() {
            case "0"?: out.append("~")
            case "1"?: out.append("/")
            default: throw ParseError.invalidEscape
            }
        }
        return String(out)
    }

    private static func escape(_ token: String) -> String {
        var out = String.UnicodeScalarView()
        for c in token.unicodeScalars {
            switch c {
            case "~": out.append(contentsOf: "~0".unicodeScalars)
            case "/": out.append(contentsOf: "~1".unicodeScalars)
            default: out.append(c)
            }
        }
        return String(out)
    }
}
