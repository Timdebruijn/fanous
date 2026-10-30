// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore

extension JSONValue {
    /// Any `Encodable` as a document tree (through `JSONEncoder`; fine for the 10 Hz live feed).
    public init<T: Encodable>(encoding value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }

    /// The tree as a `Decodable` model: the inverse of `init(encoding:)`, dates included.
    public func decoded<T: Decodable>(as type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: JSONEncoder().encode(self))
    }
}
