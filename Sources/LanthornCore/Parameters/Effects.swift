// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

/// What the two effect parameter channels mean per effect (DESIGN.md §6.2).
/// Rendered into docs/channel-map.md and the UI; the shader in LanthornEngine
/// implements exactly these mappings.
public struct EffectSpec: Sendable, Equatable {
    public let effect: Effect
    public let paramA: String
    public let paramB: String

    public static let all: [EffectSpec] = [
        EffectSpec(effect: .none, paramA: "—", paramB: "—"),
        EffectSpec(effect: .blur, paramA: "radius 0–5 % of frame height", paramB: "0 = round · 1–100 % = motion blur at 0–360°"),
        EffectSpec(effect: .pixelate, paramA: "block size 0–10 % of frame height", paramB: "—"),
        EffectSpec(effect: .mirror, paramA: "0–24 % left→right · 25–49 % right→left · 50–74 % top→bottom · 75–100 % bottom→top", paramB: "mirror line: 0 = centre … 100 % = edge"),
        EffectSpec(effect: .kaleidoscope, paramA: "segments 2–16", paramB: "rotation 0–360°"),
        EffectSpec(effect: .invert, paramA: "—", paramB: "—"),
        EffectSpec(effect: .strobe, paramA: "rate 1–30 Hz", paramB: "on time 10–90 %"),
        EffectSpec(effect: .lumaKey, paramA: "key level 0–100 % (darker is transparent)", paramB: "softness 0–100 %"),
        EffectSpec(effect: .chromaKey, paramA: "tolerance 0–100 %", paramB: "key hue 0–360°"),
        EffectSpec(effect: .edge, paramA: "gain 1–8×", paramB: "mix with original 0–100 %"),
        EffectSpec(effect: .threshold, paramA: "level 0–100 %", paramB: "softness 0–100 %"),
        EffectSpec(effect: .tint, paramA: "amount 0–100 %", paramB: "hue 0–360°"),
    ]

    public static func spec(_ effect: Effect) -> EffectSpec { all[effect.rawValue] }
}
