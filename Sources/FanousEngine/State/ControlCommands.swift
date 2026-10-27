// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation

/// Fixture values from the UI (DESIGN.md §7.2 "UI override"): the `ui` source in the resolver, so the project's source
/// policy decides whether they show (LTP/HTP/internal) — the same rule as cues and OSC. Refused under show lock.
public enum ControlCommands {
    public struct Hooks: Sendable {
        public var set: @Sendable (FixtureRef, ParameterID, UInt16) -> Void
        /// nil = every fixture
        public var release: @Sendable (FixtureRef?) -> Void
        /// Restart the 10-minute expiry of a fixture's UI values (it only runs while a console is received).
        public var keep: @Sendable (FixtureRef) -> Void
        public init(
            set: @escaping @Sendable (FixtureRef, ParameterID, UInt16) -> Void, release: @escaping @Sendable (FixtureRef?) -> Void,
            keep: @escaping @Sendable (FixtureRef) -> Void
        ) {
            self.set = set
            self.release = release
            self.keep = keep
        }
    }

    public static func register(on store: StateStore, hooks: Hooks) {
        store.register(
            CommandSpec(
                name: "fixture.set", role: .programmer, undoable: false,
                summary: "Set one fixture parameter from the UI (source ui; shown when the source policy is internal, ltp or htp).",
                argsType: "{ fixture: string; parameter: string; raw: number }"
            ) { _, args in
                guard let name = args["fixture"]?.string, let fixture = FixtureRef(parsing: name) else { throw CommandError.invalidArgs("fixture: \"Layer n\", \"Master\" or \"Output n\"") }
                guard let key = args["parameter"]?.string, let spec = ChannelMap.specs(for: fixture.mode).first(where: { $0.id.key == key }) else {
                    throw CommandError.invalidArgs("unknown parameter for \(name)")
                }
                guard let raw = args["raw"]?.int else { throw CommandError.invalidArgs("raw must be a number") }
                hooks.set(fixture, spec.id, UInt16(clamping: max(0, min(Int(spec.rawMax), raw))))
                return nil
            })
        store.register(
            CommandSpec(
                name: "fixture.release", role: .programmer, mutatesConfig: false, undoable: false,
                summary: "Drop the UI and MIDI values of one fixture, or of all fixtures without a fixture argument.", argsType: "{ fixture?: string }"
            ) { _, args in
                if let name = args["fixture"]?.string {
                    guard let fixture = FixtureRef(parsing: name) else { throw CommandError.invalidArgs("fixture: \"Layer n\", \"Master\" or \"Output n\"") }
                    hooks.release(fixture)
                } else {
                    hooks.release(nil)
                }
                return nil
            })
        store.register(
            CommandSpec(
                name: "fixture.keep", role: .programmer, undoable: false,
                summary: "Restart the 10-minute expiry of a fixture's UI values (it runs only while a console is received for the fixture).",
                argsType: "{ fixture: string }"
            ) { _, args in
                guard let name = args["fixture"]?.string, let fixture = FixtureRef(parsing: name) else { throw CommandError.invalidArgs("fixture: \"Layer n\", \"Master\" or \"Output n\"") }
                hooks.keep(fixture)
                return nil
            })
    }
}
