// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

/// An RFC 6902 patch, restricted to `add`, `remove` and `replace`. Encodes as the bare JSON array of operations.
public struct JSONPatch: Equatable, Sendable, Codable {
    public enum PatchError: Error, Equatable {
        /// An object member or array element along the path (or the target of remove/replace) does not exist.
        case missingPath(JSONPointer)
        /// An array token that is malformed (not decimal digits without leading zeros), `-` where an existing
        /// element is needed, or an `add` index beyond the end of the array.
        case invalidIndex(JSONPointer)
        /// The path goes through a string, number, bool or null.
        case notAContainer(JSONPointer)
        /// `move`, `copy`, `test`, unknown ops, or removing the document root.
        case unsupportedOperation(String)
    }

    public enum Operation: Equatable, Sendable, Codable {
        case add(JSONPointer, JSONValue)
        case remove(JSONPointer)
        case replace(JSONPointer, JSONValue)

        private enum CodingKeys: String, CodingKey {
            case op, path, value
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let op = try c.decode(String.self, forKey: .op)
            let path = try c.decode(JSONPointer.self, forKey: .path)
            switch op {
            case "add": self = .add(path, try c.decode(JSONValue.self, forKey: .value))
            case "remove": self = .remove(path)
            case "replace": self = .replace(path, try c.decode(JSONValue.self, forKey: .value))
            default: throw PatchError.unsupportedOperation(op)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .add(let path, let value):
                try c.encode("add", forKey: .op)
                try c.encode(path, forKey: .path)
                try c.encode(value, forKey: .value)
            case .remove(let path):
                try c.encode("remove", forKey: .op)
                try c.encode(path, forKey: .path)
            case .replace(let path, let value):
                try c.encode("replace", forKey: .op)
                try c.encode(path, forKey: .path)
                try c.encode(value, forKey: .value)
            }
        }
    }

    public var operations: [Operation]

    public init(operations: [Operation] = []) {
        self.operations = operations
    }

    public init(from decoder: Decoder) throws {
        operations = try decoder.singleValueContainer().decode([Operation].self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(operations)
    }

    public var isEmpty: Bool {
        operations.isEmpty
    }

    /// Applies the operations in order. All or nothing: if one throws, `document` is left unchanged.
    public func apply(to document: inout JSONValue) throws {
        var result = document
        for operation in operations {
            switch operation {
            case .add(let path, let value): try result.perform(.add(value), at: path)
            case .remove(let path): try result.perform(.remove, at: path)
            case .replace(let path, let value): try result.perform(.replace(value), at: path)
            }
        }
        document = result
    }

    /// The operations that turn `old` into `new`. Objects are diffed per key (sorted), arrays of equal length
    /// per element; anything else that differs (different array lengths, different kinds, scalars) is a `replace`.
    public static func diff(from old: JSONValue, to new: JSONValue) -> JSONPatch {
        var operations: [Operation] = []
        diff(old, new, at: JSONPointer(tokens: []), into: &operations)
        return JSONPatch(operations: operations)
    }

    private static func diff(_ old: JSONValue, _ new: JSONValue, at path: JSONPointer, into out: inout [Operation]) {
        guard old != new else { return }
        switch (old, new) {
        case (.object(let a), .object(let b)):
            for key in Set(a.keys).union(b.keys).sorted() {
                let child = path.appending(key)
                if let x = a[key], let y = b[key] {
                    diff(x, y, at: child, into: &out)
                } else if let y = b[key] {
                    out.append(.add(child, y))
                } else {
                    out.append(.remove(child))
                }
            }
        case (.array(let a), .array(let b)) where a.count == b.count:
            for i in a.indices {
                diff(a[i], b[i], at: path.appending(String(i)), into: &out)
            }
        default:
            out.append(.replace(path, new))
        }
    }
}
