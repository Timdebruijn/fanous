// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

/// UI roles (DESIGN.md §11.1): no user accounts, one optional password per role.
/// Ordered: a higher role may do everything a lower one may.
public enum Role: String, Codable, Sendable, CaseIterable, Comparable, CustomStringConvertible {
    case monitor
    case `operator`
    case programmer

    public var rank: Int {
        switch self {
        case .monitor: 0
        case .operator: 1
        case .programmer: 2
        }
    }

    public static func < (lhs: Role, rhs: Role) -> Bool { lhs.rank < rhs.rank }
    public var description: String { rawValue }
}
