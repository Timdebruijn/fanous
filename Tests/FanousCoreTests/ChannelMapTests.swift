// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Testing

@testable import FanousCore

@Suite struct ChannelMapTests {
    @Test(arguments: FixtureMode.allCases) func footprintsAreLockedAndContiguous(mode: FixtureMode) {
        let specs = ChannelMap.specs(for: mode)
        var used = Set<Int>()
        for spec in specs {
            for channel in spec.channels {
                #expect(!used.contains(channel), "channel \(channel) used twice in \(mode)")
                used.insert(channel)
            }
        }
        let highest = used.max()!
        #expect(Set(1...highest) == used, "channels 1…\(highest) must be contiguous in \(mode)")
        let reserved: ClosedRange<Int> =
            switch mode {
            case .layer: ChannelMap.reservedLayerChannels
            case .master: ChannelMap.reservedMasterChannels
            case .output: ChannelMap.reservedOutputChannels
            }
        #expect(reserved.lowerBound == highest + 1)
        #expect(reserved.upperBound == mode.footprint)
        #expect([FixtureMode.layer: 64, .master: 8, .output: 8][mode] == mode.footprint)
    }

    @Test func layerUsesFiftyChannels() {
        #expect(ChannelMap.layer.count == LayerParameter.allCases.count)
        #expect(ChannelMap.layer.map(\.channels.upperBound).max() == 50)
        #expect(ChannelMap.master.map(\.channels.upperBound).max() == 6)
        #expect(ChannelMap.output.map(\.channels.upperBound).max() == 5)
    }

    @Test func decodesRawValuesFromAUniverse() {
        var slots = [UInt8](repeating: 0, count: 512)
        let address = 65
        slots[address - 1] = 0x80  // intensity coarse
        slots[address] = 0x01  // intensity fine
        slots[address + 1] = 12  // folder (channel 3)
        slots[address + 2] = 4  // file (channel 4)
        let raw = ChannelMap.rawValues(mode: .layer, slots: slots, address: address)!
        #expect(raw[ChannelMap.index(of: .layer(.intensity))] == 0x8001)
        #expect(raw[ChannelMap.index(of: .layer(.folder))] == 12)
        #expect(raw[ChannelMap.index(of: .layer(.file))] == 4)
        #expect(ChannelMap.rawValues(mode: .layer, slots: slots, address: 449) != nil)
        #expect(ChannelMap.rawValues(mode: .layer, slots: slots, address: 450) == nil)
        #expect(ChannelMap.rawValues(mode: .layer, slots: slots, address: 0) == nil)
    }

    @Test func physicalConversions() {
        func physical(_ p: LayerParameter, _ raw: UInt16) -> Double { ChannelMap.spec(.layer(p)).physical(fromRaw: raw) }
        #expect(physical(.intensity, 65535) == 100)
        #expect(physical(.speed, 32768) == 100)
        #expect(physical(.speed, 65535) == 400)
        #expect(abs(physical(.speed, 16384) - 50.0015) < 0.01)
        #expect(physical(.scaleX, 65535) == 800)
        #expect(physical(.positionX, 32768) == 0)
        #expect(physical(.positionX, 0) == -100)
        #expect(physical(.rotationZ, 65535) == 180)
        #expect(physical(.brightness, 128) == 0)
        #expect(physical(.contrast, 255) == 200)
        #expect(physical(.dissolve, 255) == 25.5)
        #expect(physical(.hue, 255) == 360)
        #expect(Int(physical(.playMode, 17)) == PlayMode.loopReverse.rawValue)
        #expect(Int(physical(.playMode, 200)) == PlayMode.loopForward.rawValue)
        #expect(Int(physical(.blendMode, 85)) == BlendMode.difference.rawValue)
        #expect(Int(physical(.blendMode, 100)) == BlendMode.lighten.rawValue)
        #expect(Int(physical(.effect1, 176)) == Effect.tint.rawValue)
        #expect(Int(physical(.fitMode, 255)) == FitMode.native.rawValue)
        #expect(Int(physical(.control, 9)) == LayerControl.retrigger.rawValue)
        #expect(Int(ChannelMap.spec(.output(.blend)).physical(fromRaw: 128)) == BlendSwitch.raw.rawValue)
        #expect(Int(ChannelMap.spec(.master(.control)).physical(fromRaw: 128)) == MasterControl.blackout.rawValue)
    }

    @Test func rawFromPhysicalRoundTrips() {
        let speed = ChannelMap.spec(.layer(.speed))
        #expect(speed.raw(fromPhysical: 100) == 32767)
        #expect(speed.raw(fromPhysical: 400) == 65535)
        #expect(speed.raw(fromPhysical: 0) == 0)
        let rotation = ChannelMap.spec(.layer(.rotationZ))
        #expect(rotation.raw(fromPhysical: 0) == 32768)
        #expect(rotation.raw(fromPhysical: 90) == 49152)
        let mode = ChannelMap.spec(.layer(.playMode))
        #expect(mode.raw(fromPhysical: Double(PlayMode.bounce.rawValue)) == 96)
        #expect(ChannelMap.spec(.layer(.folder)).raw(fromPhysical: 300) == 255)
    }

    @Test func labels() {
        #expect(ChannelMap.spec(.layer(.intensity)).label(forRaw: 65535) == "100 %")
        #expect(ChannelMap.spec(.layer(.rotationZ)).label(forRaw: 65535) == "180°")
        #expect(ChannelMap.spec(.layer(.playMode)).label(forRaw: 17) == "Loop rev")
        #expect(ChannelMap.spec(.layer(.playMode)).label(forRaw: 250) == "Loop fwd")
        #expect(ChannelMap.spec(.layer(.folder)).label(forRaw: 12) == "12")
        #expect(ChannelMap.spec(.layer(.dissolve)).label(forRaw: 5) == "0.5 s")
    }

    @Test func defaultsAreBlackEmptyAndNativeSpeed() {
        let defaults = ChannelMap.defaults(for: .layer)
        #expect(defaults[ChannelMap.index(of: .layer(.intensity))] == 0)
        #expect(defaults[ChannelMap.index(of: .layer(.file))] == 0)
        #expect(defaults[ChannelMap.index(of: .layer(.speed))] == 32768)
        #expect(defaults[ChannelMap.index(of: .layer(.red))] == 255)
        #expect(ChannelMap.defaults(for: .master)[0] == 65535)
    }

    @Test func standardPatch() {
        let patch = Patch.standard(layers: 16, outputs: 4)
        #expect(patch.entry(for: .layer(1)) == PatchEntry(fixture: .layer(1), universe: UniverseID(.artnet, 0), address: 1))
        #expect(patch.entry(for: .layer(8))?.address == 449)
        #expect(patch.entry(for: .layer(9)) == PatchEntry(fixture: .layer(9), universe: UniverseID(.artnet, 1), address: 1))
        #expect(patch.entry(for: .master) == PatchEntry(fixture: .master, universe: UniverseID(.artnet, 2), address: 1))
        #expect(patch.entry(for: .output(4))?.address == 33)
        #expect(patch.collisions().isEmpty)
        #expect(patch.universes == [UniverseID(.artnet, 0), UniverseID(.artnet, 1), UniverseID(.artnet, 2)])
        let allFit = patch.entries.allSatisfy(\.fitsInUniverse)
        #expect(allFit)
        let colliding = Patch(entries: [
            PatchEntry(fixture: .layer(1), universe: UniverseID(.artnet, 0), address: 1),
            PatchEntry(fixture: .layer(2), universe: UniverseID(.artnet, 0), address: 64),
        ])
        #expect(colliding.collisions().count == 1)
        #expect(UniverseID.artnet(net: 1, subnet: 2, universe: 3).description == "artnet:1.2.3")
        #expect(UniverseID.artnet(net: 1, subnet: 2, universe: 3).number == 0x123)
    }
}
