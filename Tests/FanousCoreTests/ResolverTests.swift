// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Testing

@testable import FanousCore

@Suite struct ResolverTests {
    func dmxFrame(intensity: UInt16, playMode: UInt16 = 0) -> [UInt16] {
        var raw = ChannelMap.defaults(for: .layer)
        raw[ChannelMap.index(of: .layer(.intensity))] = intensity
        raw[ChannelMap.index(of: .layer(.playMode))] = playMode
        return raw
    }

    @Test func updateDMXReportsOnlyRealChanges() {
        var resolver = FixtureResolver(mode: .layer)
        let first = resolver.updateDMX(dmxFrame(intensity: 1000), at: 1)
        let same = resolver.updateDMX(dmxFrame(intensity: 1000), at: 2)
        let moved = resolver.updateDMX(dmxFrame(intensity: 1001), at: 3)
        resolver.markDMXLost()
        let back = resolver.updateDMX(dmxFrame(intensity: 1001), at: 4)
        #expect(first && !same && moved && back)  // first frame, identical refresh, new value, signal back
    }

    @Test func lookupTablesAgreeWithTheSpecOrder() {
        for mode in [FixtureMode.layer, .master, .output] {
            for (i, spec) in ChannelMap.specs(for: mode).enumerated() {
                #expect(ChannelMap.index(of: spec.id) == i)
                #expect(ChannelMap.spec(spec.id).id == spec.id)
            }
        }
    }

    @Test func dmxPolicyIgnoresInternalSources() {
        var resolver = FixtureResolver(mode: .layer, policy: .dmx)
        resolver.updateDMX(dmxFrame(intensity: 1000), at: 1)
        resolver.setInternal(.layer(.intensity), raw: 60000, source: .osc, at: 2)
        #expect(resolver.resolved(.layer(.intensity)) == ResolvedValue(raw: 1000, source: .dmx, changedAt: 1))
        #expect(resolver.hasDMX)
    }

    @Test func internalPolicyIgnoresDMX() {
        var resolver = FixtureResolver(mode: .layer, policy: .internal)
        resolver.updateDMX(dmxFrame(intensity: 1000), at: 1)
        #expect(resolver.resolved(.layer(.intensity)).raw == 0)  // default, nothing internal yet
        resolver.setInternal(.layer(.intensity), raw: 60000, source: .cue, at: 2)
        #expect(resolver.resolved(.layer(.intensity)) == ResolvedValue(raw: 60000, source: .cue, changedAt: 2))
        #expect(resolver.physical(.layer(.intensity)) > 91)
    }

    @Test func ltpTakesTheLatestChange() {
        var resolver = FixtureResolver(mode: .layer, policy: .ltp)
        resolver.updateDMX(dmxFrame(intensity: 1000), at: 1)
        resolver.setInternal(.layer(.intensity), raw: 60000, source: .osc, at: 2)
        #expect(resolver.resolved(.layer(.intensity)).source == .osc)
        resolver.updateDMX(dmxFrame(intensity: 2000), at: 3)
        #expect(resolver.resolved(.layer(.intensity)) == ResolvedValue(raw: 2000, source: .dmx, changedAt: 3))
        resolver.updateDMX(dmxFrame(intensity: 2000), at: 4)  // unchanged value does not count as a change
        resolver.setInternal(.layer(.intensity), raw: 100, source: .ui, at: 3.5)
        #expect(resolver.resolved(.layer(.intensity)).source == .ui)
    }

    @Test func htpTakesTheHighestForContinuousAndLatestForBands() {
        var resolver = FixtureResolver(mode: .layer, policy: .htp)
        resolver.updateDMX(dmxFrame(intensity: 50000, playMode: 17), at: 1)
        resolver.setInternal(.layer(.intensity), raw: 100, source: .osc, at: 2)
        resolver.setInternal(.layer(.playMode), raw: 96, source: .osc, at: 2)
        #expect(resolver.resolved(.layer(.intensity)).raw == 50000)
        #expect(resolver.resolved(.layer(.playMode)).raw == 96)  // bands: LTP
        resolver.updateDMX(dmxFrame(intensity: 50000, playMode: 17), at: 3)  // no change → no new timestamp
        #expect(resolver.resolved(.layer(.playMode)).raw == 96)
    }

    @Test func clearingASourceAndLosingDMX() {
        var resolver = FixtureResolver(mode: .layer, policy: .ltp)
        resolver.updateDMX(dmxFrame(intensity: 1000), at: 1)
        resolver.setInternal(.layer(.intensity), raw: 60000, source: .osc, at: 2)
        resolver.clearInternal(source: .osc)
        #expect(resolver.resolved(.layer(.intensity)).raw == 1000)
        resolver.markDMXLost()
        #expect(!resolver.hasDMX)
        #expect(resolver.resolved(.layer(.intensity)).raw == 1000)  // held
        #expect(resolver.resolvedAll().count == ChannelMap.layer.count)
    }

    /// DESIGN.md §6.6: with no DMX ever received, the default does not compete. A UI Master at 50 % wins under `htp`,
    /// where the default (full) is higher.
    @Test func htpWithoutDMXLetsAValueBelowTheDefaultWin() {
        var resolver = FixtureResolver(mode: .master, policy: .htp)
        resolver.setInternal(.master(.intensity), raw: 32768, source: .ui, at: 1)
        #expect(resolver.resolved(.master(.intensity)) == ResolvedValue(raw: 32768, source: .ui, changedAt: 1))
    }

    /// A console that held the Master at its default (full, so `dmxChangedAt` never moved) and then went silent with hold
    /// on loss: the held full still competes, so a lower UI value does not beat it under `htp`.
    @Test func heldDefaultAfterALossStillCompetes() {
        var resolver = FixtureResolver(mode: .master, policy: .htp)
        resolver.updateDMX(ChannelMap.defaults(for: .master), at: 1)
        resolver.markDMXLost()
        resolver.setInternal(.master(.intensity), raw: 32768, source: .ui, at: 2)
        #expect(resolver.resolved(.master(.intensity)).raw == 65535)
        #expect(resolver.dmxReceived && !resolver.hasDMX)
    }

    /// Unpatch: the DMX side goes back to the defaults and stops competing; the internal values stay.
    @Test func clearDMXResetsTheDMXSideAndKeepsInternalValues() {
        var resolver = FixtureResolver(mode: .layer, policy: .htp)
        resolver.updateDMX(dmxFrame(intensity: 60000, playMode: 17), at: 1)
        resolver.internalWithoutDMX = true
        resolver.setInternal(.layer(.file), raw: 3, source: .ui, at: 2)
        resolver.setInternal(.layer(.intensity), raw: 1000, source: .ui, at: 2)
        #expect(resolver.resolved(.layer(.intensity)).raw == 60000)
        resolver.clearDMX()
        #expect(!resolver.hasDMX && !resolver.dmxReceived && !resolver.internalWithoutDMX)
        #expect(resolver.resolved(.layer(.intensity)) == ResolvedValue(raw: 1000, source: .ui, changedAt: 2))
        #expect(resolver.resolved(.layer(.playMode)) == ResolvedValue(raw: 0, source: .none, changedAt: 0))
        #expect(resolver.internalCount == 2)
        resolver.policy = .dmx
        #expect(resolver.resolvedAll().map(\.raw) == ChannelMap.defaults(for: .layer))
    }

    @Test func internalCountFollowsSetAndClear() {
        var resolver = FixtureResolver(mode: .layer)
        resolver.setInternal(.layer(.file), raw: 1, source: .ui, at: 1)
        resolver.setInternal(.layer(.file), raw: 2, source: .cue, at: 2)  // overwritten, still one
        resolver.setInternal(.layer(.intensity), raw: 1, source: .ui, at: 3)
        #expect(resolver.internalCount == 2)
        resolver.clearInternal(.layer(.file), source: .ui)  // not the ui's any more: stays
        resolver.clearInternal(source: .ui)
        #expect(resolver.internalCount == 1)
        resolver.clearInternal(.layer(.file), source: .cue)
        resolver.clearInternal(.layer(.file), source: .cue)
        #expect(resolver.internalCount == 0 && resolver.internalValues().isEmpty)
    }
}
