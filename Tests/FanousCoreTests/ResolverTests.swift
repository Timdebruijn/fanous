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
}
