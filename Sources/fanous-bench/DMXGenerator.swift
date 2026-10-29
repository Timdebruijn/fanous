// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import Network

/// Soak-test traffic (DESIGN.md §18): Art-Net for `layers` layers at the standard patch at `hz`, every layer picks a
/// random file, play mode, dissolve and intensity every 3–8 s, position and scale drift slowly. Deterministic per seed.
@MainActor
enum DMXGenerator {
    struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }

    static func run(layers: Int, files: Int, seconds: Double) {
        let (hz, host, seed): (Double, String, UInt64) = (40, "127.0.0.1", 1)
        let patch = Patch.standard(layers: layers, outputs: 1)
        let specs = ChannelMap.specs(for: .layer)
        var universes: [Int: [UInt8]] = [:]
        var slots: [(universe: Int, base: Int)] = []
        for n in 1...layers {
            guard let entry = patch.entry(for: .layer(n)) else { continue }
            if universes[entry.universe.number] == nil { universes[entry.universe.number] = Array(repeating: 0, count: 512) }
            slots.append((entry.universe.number, entry.address - 1))
            for spec in specs { set(&universes[entry.universe.number]!, base: entry.address - 1, spec, spec.defaultRaw) }
        }
        func set(_ data: inout [UInt8], base: Int, _ spec: ParameterSpec, _ raw: UInt16) {
            let index = base + spec.channel - 1
            if spec.bits == 16 {
                data[index] = UInt8(raw >> 8)
                data[index + 1] = UInt8(raw & 0xFF)
            } else {
                data[index] = UInt8(clamping: raw)
            }
        }
        func spec(_ key: String) -> ParameterSpec { specs.first { $0.id.key == key }! }
        let (intensity, folder, file, playMode, dissolve, positionX, scaleX, scaleY) =
            (spec("intensity"), spec("folder"), spec("file"), spec("playMode"), spec("dissolve"), spec("positionX"), spec("scaleX"), spec("scaleY"))
        let playModes: [UInt16] = [0, 16, 96, 32]  // loop fwd, loop rev, bounce, once hold (docs/channel-map.md)

        let connection = NWConnection(host: NWEndpoint.Host(host), port: 6454, using: .udp)
        connection.start(queue: DispatchQueue(label: "bench.dmx"))
        var rng = SplitMix64(state: seed)
        var sequence: UInt8 = 1
        var nextChange = [Double](repeating: 0, count: slots.count)
        var ticks = 0
        let start = Date()
        var nextTick = start
        print("dmx: \(layers) layers → \(host):6454 at \(hz) Hz for \(Int(seconds)) s (seed \(seed))")
        // a plain paced loop: 40 Hz needs no timer precision, and no closure has to capture the mutable state
        while true {
            let t = Date().timeIntervalSince(start)
            if t >= seconds { break }
            for (i, slot) in slots.enumerated() {
                var data = universes[slot.universe]!
                if t >= nextChange[i] {
                    nextChange[i] = t + 3 + rng.unit() * 5
                    set(&data, base: slot.base, folder, 1)
                    set(&data, base: slot.base, file, UInt16(1 + Int(rng.unit() * Double(files))))
                    set(&data, base: slot.base, playMode, playModes[Int(rng.unit() * Double(playModes.count))])
                    set(&data, base: slot.base, dissolve, UInt16(rng.unit() * 20))  // 0–2 s
                    set(&data, base: slot.base, intensity, UInt16(32768 + rng.unit() * 32767))
                }
                set(&data, base: slot.base, positionX, UInt16(32768 + 6000 * sin(t / 7 + Double(i))))
                let scale = UInt16(32768 + 3000 * sin(t / 11 + Double(i)))
                set(&data, base: slot.base, scaleX, scale)
                set(&data, base: slot.base, scaleY, scale)
                universes[slot.universe] = data
            }
            for (universe, data) in universes {
                connection.send(content: Data(ArtDmx(sequence: sequence, portAddress: UInt16(universe), data: data).encoded()), completion: .idempotent)
            }
            sequence = sequence == 255 ? 1 : sequence + 1
            ticks += 1
            nextTick += 1 / hz
            let delay = nextTick.timeIntervalSinceNow
            if delay > 0 { usleep(UInt32(delay * 1_000_000)) }
        }
        connection.cancel()
        print("dmx: \(ticks) ticks, \(universes.count) universe(s), \(slots.count) layers")
    }
}
