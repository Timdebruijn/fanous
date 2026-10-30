// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import Metal
import Testing

@testable import FanousEngine

/// The compile cache (DESIGN.md §9.10 item 0): a recompile reuses every texture whose settings and size did not change,
/// and a texture lives exactly as long as a plan holds it.
struct OutputCompileCacheTests {
    /// Blend, warp and a feathered mask: one texture of each kind.
    static func output(_ id: Int, region: PixelRect? = nil) -> OutputConfig {
        var o = OutputConfig(id: id)
        o.region = region
        o.blend.right = BlendEdge(overlap: 40)
        o.blend.lift = 0.05
        o.warp.cornerPin[1] = MapPoint(0.95, 0.02)
        o.slices[0].mask = MaskSettings(path: [MapPoint(0.1, 0.1), MapPoint(0.9, 0.1), MapPoint(0.5, 0.9)], feather: 8)
        return o
    }

    @Test func aRecompileReusesWhatDidNotChange() throws {
        let compiler = try OutputCompiler(device: MetalContext().device)
        let config = Self.output(1)
        let first = try compiler.compile(config, index: 1, drawable: (320, 180))
        let same = try compiler.compile(config, index: 1, drawable: (320, 180))
        #expect(first.blendMap != nil && first.warpField != nil && first.slices[0].mask != nil)
        #expect(same.blendMap === first.blendMap && same.warpField === first.warpField && same.slices[0].mask === first.slices[0].mask)
        var edited = config
        edited.blend.right.overlap = 41
        edited.slices[0].dest[0] = MapPoint(0.05, 0)  // a moved slice keeps its mask raster
        let blendEdit = try compiler.compile(edited, index: 1, drawable: (320, 180))
        #expect(blendEdit.blendMap !== first.blendMap)
        #expect(blendEdit.warpField === first.warpField && blendEdit.slices[0].mask === first.slices[0].mask)
        // another size is another key (a region, a display mode, a preview)
        let resized = try compiler.compile(config, index: 1, drawable: (160, 90))
        #expect(resized.blendMap !== first.blendMap && resized.warpField !== first.warpField && resized.slices[0].mask !== first.slices[0].mask)
    }

    /// A key carries everything its bytes depend on: with the base output's plan alive, each variant compiled through
    /// the warm cache has the bytes a fresh compiler gives it, so a key that drops a field fails here.
    @Test func aCacheHitHasTheBytesOfAFreshCompile() throws {
        let device = try MetalContext().device
        let warm = OutputCompiler(device: device)
        let base = Self.output(1)
        let basePlan = try warm.compile(base, index: 1, drawable: (320, 180))
        func bytes(_ texture: MTLTexture?) -> [UInt8] {
            guard let texture else { return [] }
            let bpp = texture.pixelFormat == .r8Unorm ? 1 : 8
            var out = [UInt8](repeating: 0, count: texture.width * texture.height * bpp)
            texture.getBytes(&out, bytesPerRow: texture.width * bpp, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            return out
        }
        let edits: [(String, (inout OutputConfig) -> Void)] = [
            ("mask feather", { $0.slices[0].mask?.feather = 3 }),
            ("mask path", { $0.slices[0].mask?.path[2] = MapPoint(0.5, 0.7) }),
            ("corner pin", { $0.warp.cornerPin[1] = MapPoint(0.9, 0.05) }),
            ("gammaRGB", { $0.blend.right.gammaRGB = [1.8, 2.2, 2.6] }),
            ("lift feather", { $0.blend.liftFeather = 12 }),
            ("second axis", { $0.blend.top = BlendEdge(overlap: 20) }),
        ]
        for (name, edit) in edits {
            var variant = base
            edit(&variant)
            let cached = try warm.compile(variant, index: 1, drawable: (320, 180))
            let fresh = try OutputCompiler(device: device).compile(variant, index: 1, drawable: (320, 180))
            #expect(bytes(cached.blendMap) == bytes(fresh.blendMap), "blend map, \(name)")
            #expect(bytes(cached.warpField) == bytes(fresh.warpField), "warp field, \(name)")
            #expect(bytes(cached.slices[0].mask) == bytes(fresh.slices[0].mask), "mask, \(name)")
        }
        withExtendedLifetime(basePlan) {}
    }

    /// The coordinator compiles every output of a display while the display's current set still holds its plans.
    @Test func anEditOnOneOutputLeavesTheOthersAlone() throws {
        let compiler = try OutputCompiler(device: MetalContext().device)
        var a = Self.output(1, region: PixelRect(x: 0, y: 0, w: 160, h: 180)), b = Self.output(2, region: PixelRect(x: 160, y: 0, w: 160, h: 180))
        b.blend.left = BlendEdge(overlap: 40)
        let rebind = { try OutputSet(plans: [a, b].map { try compiler.compile($0, index: $0.id, drawable: (320, 180)) }) }
        let before = try rebind()
        a.blend.right.overlap = 30
        let after = try rebind()
        let (oldA, oldB, newA, newB) = (before.plans[0], before.plans[1], after.plans[0], after.plans[1])
        #expect(newA.blendMap !== oldA.blendMap && newA.warpField === oldA.warpField && newA.slices[0].mask === oldA.slices[0].mask)
        #expect(newB.blendMap === oldB.blendMap && newB.warpField === oldB.warpField && newB.slices[0].mask === oldB.slices[0].mask)
    }

    /// A swapped-out set's textures go with it, unless a set still holds it: a frozen output's set takes its hold from
    /// the one it replaced (`OutputSet.previous`, B111), which keeps that one's textures until the render thread adopts.
    @Test func unusedTexturesGoAfterTheSwapAndAHeldSetKeepsItsOwn() throws {
        let compiler = try OutputCompiler(device: MetalContext().device)
        let config = Self.output(1)
        var edited = config
        edited.blend.lift = 0.06
        var current: OutputSet? = OutputSet(plans: [try compiler.compile(config, index: 1, drawable: (320, 180))])
        weak let oldBlend = current?.plans[0].blendMap
        weak let warp = current?.plans[0].warpField
        let next = OutputSet(plans: [try compiler.compile(edited, index: 1, drawable: (320, 180))], previous: current?.holdSource)
        current = nil  // swapped: only `next.previous` holds it now
        #expect(oldBlend != nil, "held by the replacing set until it adopts")
        #expect(try compiler.compile(config, index: 1, drawable: (320, 180)).blendMap === oldBlend)
        #expect(compiler.entries == 4)  // two blend maps, the shared warp field and mask
        OutputPass.adopt(next, canvas: { _ in nil }, outputs: [])  // the render thread releases `previous`
        #expect(oldBlend == nil, "no plan holds it: freed")
        #expect(warp === next.plans[0].warpField)
        _ = try compiler.compile(edited, index: 1, drawable: (320, 180))
        #expect(compiler.entries == 3, "the dead entry is dropped at the next compile")
    }

    /// The measurement of §9.10 "As built (M2.2)": a 2×2 wall of 1920×1080 outputs on one 3840×2160 drawable, blended on
    /// both axes, then 20 edits of one output's overlap, each a rebind of all four. Before: no cache (a fresh compiler per
    /// rebind compiles everything, as before M2.2); after: one compiler, the display's set alive during the rebind.
    /// `FANOUS_BENCH=1 scripts/test.sh -c release --filter compileCacheBench`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FANOUS_BENCH"] != nil)) func compileCacheBench() throws {
        let device = try MetalContext().device
        var wall: [OutputConfig] = []
        for (i, (x, y)) in [(0, 0), (1, 0), (0, 1), (1, 1)].enumerated() {
            var o = OutputConfig(id: i + 1)
            o.region = PixelRect(x: x * 1920, y: y * 1080, w: 1920, h: 1080)
            if x == 0 { o.blend.right = BlendEdge(overlap: 240) } else { o.blend.left = BlendEdge(overlap: 240) }
            if y == 0 { o.blend.bottom = BlendEdge(overlap: 135) } else { o.blend.top = BlendEdge(overlap: 135) }
            (o.blend.lift, o.blend.liftFeather) = (0.04, 24)
            wall.append(o)
        }
        func cpuMs(_ body: () throws -> Void) rethrows -> Double {
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            try body()
            return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e6
        }
        func median(_ cached: Bool) throws -> Double {
            var outputs = wall
            let shared = OutputCompiler(device: device)
            var set = OutputSet(plans: try outputs.map { try shared.compile($0, index: $0.id, drawable: (3840, 2160)) })
            var times: [Double] = []
            for edit in 1...20 {
                outputs[0].blend.right.overlap = 240 + Double(edit)
                let compiler = cached ? shared : OutputCompiler(device: device)
                times.append(try cpuMs { set = OutputSet(plans: try outputs.map { try compiler.compile($0, index: $0.id, drawable: (3840, 2160)) }) })
            }
            #expect(set.plans.count == 4)
            return times.sorted()[times.count / 2]
        }
        let (before, after) = (try median(false), try median(true))
        let compiler = OutputCompiler(device: device)
        let unchanged = try withExtendedLifetime(try compiler.compile(wall[1], index: 2, drawable: (3840, 2160))) {
            try cpuMs { _ = try compiler.compile(wall[1], index: 2, drawable: (3840, 2160)) }
        }
        print(String(format: "compile per rebind, 2×2 wall of 1920×1080 with blends, 20 edits of one output (median CPU): before %.1f ms, after %.1f ms; an unchanged output (meshes only) %.2f ms", before, after, unchanged))
        #expect(after < before)
    }
}
