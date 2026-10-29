// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore

/// Metal shader source, compiled at engine start (`MTLDevice.makeLibrary(source:)`)
/// so no offline Metal toolchain is needed. One string on purpose: the layer
/// uber-shader (DESIGN.md §4.3) and the output pass are small enough to read.
///
/// Per-pixel effects branch on per-draw uniforms (free on Apple GPUs). The
/// neighbourhood effects (blur, edge) are function-constant specialisations:
/// inlined into the one shader they cost every draw its occupancy (measured
/// 2026-10-23: 3.7 ms per 1080p layer for 13 taps), so four pipelines are
/// built at start (none / blur / edge / both) and nothing is ever compiled
/// during a show. Blend modes read the destination with framebuffer fetch
/// (`[[color(0)]]`), so no extra passes.
public enum ShaderSource {
    public static let metal = """
    #include <metal_stdlib>
    using namespace metal;

    struct LayerUniforms {
        float4x4 transform;   // canvas units → clip space (perspective)
        float4 quadRect;      // x0 y0 x1 y1, canvas units, y up
        float4 uvRect;        // u0 v0 u1 v1 after crop (v0 = top)
        float4 colour;        // rgb multiply, intensity (layer × crossfade: the alpha)
        float4 adjust;        // brightness, contrast, saturation, hue (radians)
        float4 effect1;       // id, A, B, 1 when the texture rows are bottom-up (Syphon)
        float4 effect2;
        float4 texel;         // 1/width, 1/height, width/height, time (s)
        uint kind;            // SourcePixelKind
        uint blend;           // BlendMode
        float master;         // Master intensity: scales the colour, not the alpha (B108)
        uint pad1;
    };

    constant bool hasBlur [[function_constant(0)]];
    constant bool hasEdge [[function_constant(1)]];

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    constant float2 quadCorners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };

    vertex VertexOut layer_vertex(uint vid [[vertex_id]], constant LayerUniforms& u [[buffer(0)]]) {
        float2 t = quadCorners[vid];
        float2 pos = float2(mix(u.quadRect.x, u.quadRect.z, t.x), mix(u.quadRect.y, u.quadRect.w, t.y));
        VertexOut out;
        out.position = u.transform * float4(pos, 0, 1);
        out.uv = float2(mix(u.uvRect.x, u.uvRect.z, t.x), mix(u.uvRect.w, u.uvRect.y, t.y));
        return out;
    }

    // Rec.709 video range in 8-bit ratios (16/255, 255/219, 255/224): exact for 8-bit live frames; 16-/10-bit sources
    // read about 1 code low at white and about 1 code off in neutral chroma (B119).
    static float3 ycbcr_to_rgb(float y, float cb, float cr) {
        float yy = (y - 16.0 / 255.0) * (255.0 / 219.0);
        float u = (cb - 128.0 / 255.0) * (255.0 / 224.0);
        float v = (cr - 128.0 / 255.0) * (255.0 / 224.0);
        return saturate(float3(yy + 1.5748 * v, yy - 0.1873 * u - 0.4681 * v, yy + 1.8556 * u));
    }

    static float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

    static float3 rgb2hsv(float3 c) {
        float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
        float4 p = c.g < c.b ? float4(c.bg, K.wz) : float4(c.gb, K.xy);
        float4 q = c.r < p.x ? float4(p.xyw, c.r) : float4(c.r, p.yzx);
        float d = q.x - min(q.w, q.y);
        float e = 1.0e-10;
        return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
    }

    static float3 hsv2rgb(float3 c) {
        float3 p = abs(fract(c.xxx + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
        return c.z * mix(float3(1.0), saturate(p - 1.0), c.y);
    }

    // Exact hue shift (HSV), so 120° turns green into blue like a console expects.
    static float3 hue_rotate(float3 c, float h) {
        float3 hsv = rgb2hsv(saturate(c));
        hsv.x = fract(hsv.x + h / (2.0 * M_PI_F));
        return hsv2rgb(hsv);
    }

    // Source conversion: straight (non-premultiplied) RGBA in the source's own colour.
    static float4 fetch(constant LayerUniforms& u, texture2d<float> tex0, texture2d<float> tex1, texture2d<float> tex2,
                        sampler linearSampler, sampler nearestSampler, float2 uv) {
        float4 rgba;
        switch (u.kind) {
        case 1: {  // v216: texel = (Cb, Y0, Cr, Y1) for a pixel pair
            float width = 1.0 / u.texel.x;
            float px = uv.x * width;
            float2 pairUV = float2((floor(px * 0.5) + 0.5) / (width * 0.5), uv.y);
            float4 p = tex0.sample(nearestSampler, pairUV);
            float y = fract(px * 0.5) < 0.5 ? p.g : p.a;
            rgba = float4(ycbcr_to_rgb(y, p.r, p.b), 1.0);
            break;
        }
        case 2: {  // y416: (A, Y, Cb, Cr)
            float4 p = tex0.sample(linearSampler, uv);
            rgba = float4(ycbcr_to_rgb(p.g, p.b, p.a), p.r);
            break;
        }
        case 3:    // HAP Q: scaled YCoCg in BC3
        case 5: {  // HAP Q Alpha
            float4 c = tex0.sample(linearSampler, uv);
            float scale = (c.b * (255.0 / 8.0)) + 1.0;
            float co = (c.r - (0.5 * 256.0 / 255.0)) / scale;
            float cg = (c.g - (0.5 * 256.0 / 255.0)) / scale;
            float y = c.a;
            float alpha = u.kind == 5 ? tex1.sample(linearSampler, uv).r : 1.0;
            rgba = float4(saturate(float3(y + co - cg, y + cg, y - co - cg)), alpha);
            break;
        }
        case 4: {  // alpha-only
            rgba = float4(1.0, 1.0, 1.0, tex0.sample(linearSampler, uv).r);
            break;
        }
        case 6:    // bi-planar YCbCr (4:2:2 or 4:4:4)
        case 7: {  // + alpha plane
            float y = tex0.sample(linearSampler, uv).r;
            float2 cbcr = tex1.sample(linearSampler, uv).rg;
            float alpha = u.kind == 7 ? tex2.sample(linearSampler, uv).r : 1.0;
            rgba = float4(ycbcr_to_rgb(y, cbcr.x, cbcr.y), alpha);
            break;
        }
        default:   // straight RGBA (stills, HAP, HAP Alpha, HAP R, live inputs)
            rgba = tex0.sample(linearSampler, uv);
            break;
        }
        return rgba;
    }

    // Colour adjust (RGB multiply, brightness, contrast, saturation, hue), once per pixel after the neighbourhood stage.
    static float4 adjust(constant LayerUniforms& u, float4 rgba) {
        float3 c = rgba.rgb * u.colour.rgb;
        c += u.adjust.x;
        c = (c - 0.5) * u.adjust.y + 0.5;
        c = mix(float3(luma(saturate(c))), c, u.adjust.z);
        if (u.adjust.w != 0.0) c = hue_rotate(c, u.adjust.w);
        return float4(c, rgba.a);
    }

    // Mirrored repeat into 0…1 (kaleidoscope reflections past the edge).
    static float2 mirror01(float2 x) { return 1.0 - abs(fract(x * 0.5) * 2.0 - 1.0); }

    // Effects that move the sampling position (DESIGN.md §6.2, EffectSpec in Core).
    static float2 effect_uv(uint id, float a, float b, float2 uv, float aspect) {
        switch (id) {
        case 2: {  // pixelate: block size 0–10 % of frame height
            float bs = a * 0.1;
            if (bs <= 0.0) return uv;
            float2 block = float2(bs / aspect, bs);
            return (floor(uv / block) + 0.5) * block;
        }
        case 3: {  // mirror: A = mode, B = mirror line from centre (0) to the edge (1)
            uint mode = min(3u, uint(a * 4.0));
            float p = 0.5 + 0.5 * b, q = 0.5 - 0.5 * b;
            if (mode == 0u && uv.x > p) uv.x = 2.0 * p - uv.x;
            else if (mode == 1u && uv.x < q) uv.x = 2.0 * q - uv.x;
            else if (mode == 2u && uv.y > p) uv.y = 2.0 * p - uv.y;
            else if (mode == 3u && uv.y < q) uv.y = 2.0 * q - uv.y;
            return uv;
        }
        case 4: {  // kaleidoscope: A = segments 2–16, B = rotation
            float n = round(2.0 + a * 14.0);
            float2 c = (uv - 0.5) * float2(aspect, 1.0);
            float ang = atan2(c.y, c.x) + b * 2.0 * M_PI_F;
            float r = length(c);
            float seg = 2.0 * M_PI_F / n;
            ang = fmod(ang, seg);
            if (ang < 0.0) ang += seg;
            if (ang > seg * 0.5) ang = seg - ang;
            c = float2(cos(ang), sin(ang)) * r;
            return mirror01(c / float2(aspect, 1.0) + 0.5);
        }
        default:
            return uv;
        }
    }

    // Per-pixel colour effects.
    static float4 effect_colour(uint id, float a, float b, float4 c, float time) {
        switch (id) {
        case 5:  // invert
            c.rgb = 1.0 - c.rgb;
            break;
        case 6: {  // strobe: A = rate 1–30 Hz, B = on time 10–90 %
            float rate = 1.0 + 29.0 * a;
            float duty = 0.1 + 0.8 * b;
            if (fract(time * rate) >= duty) c.a = 0.0;
            break;
        }
        case 7: {  // luma key: darker than A is transparent, B = softness
            float s = b * 0.5;
            c.a *= smoothstep(a - s, a + s + 1e-4, luma(c.rgb));
            break;
        }
        case 8: {  // chroma key: A = tolerance, B = hue
            float3 hsv = rgb2hsv(c.rgb);
            float d = abs(hsv.x - b);
            d = min(d, 1.0 - d) * 2.0;  // 0 = key hue, 1 = opposite hue
            float keyed = (1.0 - smoothstep(a * 0.5, a + 1e-4, d)) * smoothstep(0.1, 0.4, hsv.y);
            c.a *= 1.0 - keyed;
            break;
        }
        case 10: {  // threshold: A = level, B = softness
            float s = b * 0.5;
            c.rgb = float3(smoothstep(a - s, a + s + 1e-4, luma(c.rgb)));
            break;
        }
        case 11: {  // tint: A = amount, B = hue
            float3 t = hsv2rgb(float3(b, 1.0, 1.0)) * luma(c.rgb);
            c.rgb = mix(c.rgb, t, a);
            break;
        }
        default:
            break;
        }
        return c;
    }

    constant float2 poisson[12] = {
        float2(-0.326, -0.406), float2(-0.840, -0.074), float2(-0.696, 0.457), float2(-0.203, 0.621),
        float2(0.962, -0.195), float2(0.473, -0.480), float2(0.519, 0.767), float2(0.185, -0.893),
        float2(0.507, 0.064), float2(0.896, 0.412), float2(-0.322, -0.933), float2(-0.792, -0.598),
    };

    fragment float4 layer_fragment(VertexOut in [[stage_in]],
                                   constant LayerUniforms& u [[buffer(0)]],
                                   texture2d<float> tex0 [[texture(0)]],
                                   texture2d<float> tex1 [[texture(1)]],
                                   texture2d<float> tex2 [[texture(2)]],
                                   sampler linearSampler [[sampler(0)]],
                                   sampler nearestSampler [[sampler(1)]],
                                   float4 dst [[color(0)]]) {
        uint e1 = uint(u.effect1.x), e2 = uint(u.effect2.x);
        float aspect = u.texel.z;
        // slot 1 is applied to the image first, so its coordinate warp runs last. Effects work in picture
        // order (v down); a bottom-up texture is flipped into that order around them and back.
        bool bottomUp = u.effect1.w > 0.5;
        float2 uv = bottomUp ? float2(in.uv.x, 1.0 - in.uv.y) : in.uv;
        uv = effect_uv(e2, u.effect2.y, u.effect2.z, uv, aspect);
        uv = effect_uv(e1, u.effect1.y, u.effect1.z, uv, aspect);
        if (bottomUp) uv.y = 1.0 - uv.y;

        float4 c;
        float radius = (e1 == 1u ? u.effect1.y : 0.0) + (e2 == 1u ? u.effect2.y : 0.0);
        if (hasBlur && radius > 0.0) {  // blur: A = radius 0–5 % of height, B = 0 round, else motion blur angle
            float angle = e1 == 1u ? u.effect1.z : u.effect2.z;
            float2 scale = float2(1.0 / aspect, 1.0) * radius * 0.05;
            float4 sum = fetch(u, tex0, tex1, tex2, linearSampler, nearestSampler, uv);
            if (angle > 0.0) {
                float2 dir = float2(cos(angle * 2.0 * M_PI_F), sin(angle * 2.0 * M_PI_F));
                for (int i = 0; i < 12; i++) {
                    float t = (float(i) - 5.5) / 5.5;
                    sum += fetch(u, tex0, tex1, tex2, linearSampler, nearestSampler, uv + dir * t * scale);
                }
            } else {
                for (int i = 0; i < 12; i++) sum += fetch(u, tex0, tex1, tex2, linearSampler, nearestSampler, uv + poisson[i] * scale);
            }
            c = sum / 13.0;
        } else {
            c = fetch(u, tex0, tex1, tex2, linearSampler, nearestSampler, uv);
        }

        if (hasEdge && (e1 == 9u || e2 == 9u)) {  // edge (Sobel): A = gain 1–8×, B = mix with original
            float a = e1 == 9u ? u.effect1.y : u.effect2.y, b = e1 == 9u ? u.effect1.z : u.effect2.z;
            float2 d = u.texel.xy;
            float l[9];
            int k = 0;
            for (int y = -1; y <= 1; y++)
                for (int x = -1; x <= 1; x++)
                    l[k++] = luma(fetch(u, tex0, tex1, tex2, linearSampler, nearestSampler, uv + float2(x, y) * d).rgb);
            float gx = -l[0] - 2.0 * l[3] - l[6] + l[2] + 2.0 * l[5] + l[8];
            float gy = -l[0] - 2.0 * l[1] - l[2] + l[6] + 2.0 * l[7] + l[8];
            float mag = saturate(length(float2(gx, gy)) * (1.0 + 7.0 * a));
            c.rgb = mix(float3(mag), c.rgb, b);
        }

        c = adjust(u, c);
        c = effect_colour(e1, u.effect1.y, u.effect1.z, c, u.texel.w);
        c = effect_colour(e2, u.effect2.y, u.effect2.z, c, u.texel.w);

        // The Master m scales the colour, not the opacity: dst is m × the canvas at Master 100 % (black at the clear),
        // so each mode is m × its own formula at dst / m and the result stays m × that canvas (B108).
        float a = saturate(c.a) * u.colour.a;
        float m = u.master;
        float3 s = saturate(c.rgb);
        float3 sm = s * m;
        float3 d = dst.rgb;
        float3 b;
        switch (u.blend) {
        case 1: b = d + sm; break;                     // add
        case 2: b = m - (1.0 - s) * (m - d); break;    // screen
        case 3: b = s * d; break;                      // multiply
        case 4: b = d - sm; break;                     // subtract
        case 5: b = abs(d - sm); break;                // difference
        case 6: b = max(sm, d); break;                 // lighten
        case 7: b = min(sm, d); break;                 // darken
        default: b = sm; break;                        // normal
        }
        return float4(mix(d, clamp(b, float3(0.0), float3(m)), a), a + dst.a * (1.0 - a));
    }

    // Plain output pass: canvas → drawable, also the canvas preview and the thumbnail copy (pattern 0). A test pattern at
    // full level only without an output set (the Master's, in tests and fanous-bench); the engine's displays always get the
    // mapped pass below, which dims patterns like the content.
    struct OutputUniforms {
        float2 size;     // drawable pixels
        uint pattern;    // TestPattern
        uint index;      // output number, 1-based
    };

    vertex VertexOut output_vertex(uint vid [[vertex_id]]) {
        float2 t = quadCorners[vid];
        VertexOut out;
        out.position = float4(t * 2.0 - 1.0, 0, 1);
        out.uv = float2(t.x, 1.0 - t.y);
        return out;
    }

    constant uint segMasks[10] = { 0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F };  // gfedcba

    // one seven-segment character in its cell (q in [0,1]², y down)
    static float seven_seg(float2 q, uint c) {
        if (c == 10u) {  // colon
            float2 a = q - float2(0.5, 0.33), b = q - float2(0.5, 0.67);
            return (dot(a, a) < 0.006 || dot(b, b) < 0.006) ? 1.0 : 0.0;
        }
        if (c > 9u) return 0.0;
        float2 p = (q - float2(0.18, 0.1)) / float2(0.64, 0.8);
        if (p.x < 0.0 || p.y < 0.0 || p.x > 1.0 || p.y > 1.0) return 0.0;
        float t = 0.14;
        if (c == 1u) return abs(p.x - 0.5) < t * 0.5 ? 1.0 : 0.0;  // centred, like a typeset 1
        uint m = segMasks[c];
        bool inX = p.x > t * 0.6 && p.x < 1.0 - t * 0.6;
        bool top = p.y < 0.5;
        if ((m & 1u) && inX && p.y < t) return 1.0;
        if ((m & 64u) && inX && abs(p.y - 0.5) < t * 0.5) return 1.0;
        if ((m & 8u) && inX && p.y > 1.0 - t) return 1.0;
        if ((m & 32u) && p.x < t && top) return 1.0;
        if ((m & 2u) && p.x > 1.0 - t && top) return 1.0;
        if ((m & 16u) && p.x < t && !top) return 1.0;
        if ((m & 4u) && p.x > 1.0 - t && !top) return 1.0;
        return 0.0;
    }

    // Test patterns (Master/Output fixtures; 1–7 also as folder 0 files 101–107). Sizes follow the region's height, so a pattern
    // reads the same on a 720p monitor and a 4K projector; line width is ≥ 1 px per 540 px of height.
    static float3 test_pattern(uint pattern, uint index, float2 uv, float2 size) {
        float2 px = uv * size;
        float h = size.y;
        float lw = max(1.0, h / 540.0);
        float2 c = px - size * 0.5;
        float cell = h / 12.0;
        bool border = px.x < lw * 3.0 || px.y < lw * 3.0 || size.x - px.x < lw * 3.0 || size.y - px.y < lw * 3.0;
        switch (pattern) {
        case 1: {  // alignment grid: centred square cells, half-cell dim lines, border, centre cross, aspect circle, diagonals
            float2 m = abs(fmod(abs(c) + cell * 0.5, cell) - cell * 0.5);
            float2 half_ = abs(fmod(abs(c), cell) - cell * 0.5);
            if (border) return float3(1.0);
            if (abs(c.x) < lw * 1.5 || abs(c.y) < lw * 1.5) return float3(1.0, 0.3, 0.3);
            if (abs(length(c) - h * 0.45) < lw * 1.5) return float3(1.0);
            float2 n = normalize(size);
            if (abs(c.x * n.y - c.y * n.x) < lw || abs(c.x * n.y + c.y * n.x) < lw) return float3(0.5);
            if (m.x < lw || m.y < lw) return float3(0.85);
            if (half_.x < lw * 0.5 || half_.y < lw * 0.5) return float3(0.22);
            return float3(0.04);
        }
        case 2: {  // colour bars: 75 % SMPTE order above, 100 % white/red/green/blue/black references below
            if (uv.y < 0.67) {
                uint bar = min(7u, uint(uv.x * 8.0));
                const float3 bars[8] = { float3(0.75), float3(0.75, 0.75, 0), float3(0, 0.75, 0.75), float3(0, 0.75, 0),
                                         float3(0.75, 0, 0.75), float3(0.75, 0, 0), float3(0, 0, 0.75), float3(0) };
                return bars[bar];
            }
            uint ref = min(4u, uint(uv.x * 5.0));
            const float3 refs[5] = { float3(1.0), float3(1, 0, 0), float3(0, 1, 0), float3(0, 0, 1), float3(0) };
            return refs[ref];
        }
        case 3: {  // blend check: flat 50 % grey (the blend map shows a seam as a bright or dark band) with grid lines
                   // in this output's own colour, so two overlapping projectors' lines can be laid on top of each other
            float2 m = abs(fmod(abs(c) + cell * 0.5, cell) - cell * 0.5);
            float3 own = hsv2rgb(float3(fract(float(index) * 0.618034), 0.85, 1.0));
            if (m.x < lw * 1.5 || m.y < lw * 1.5) return own;
            return float3(0.5);
        }
        case 4: {  // output ID: the number, large, on this output's colour, with a white border
            float3 base = hsv2rgb(float3(fract(float(index) * 0.618034), 0.6, 0.5));
            if (border) return float3(1.0);
            uint tens = index / 10u, ones = index % 10u;
            uint count = tens > 0u ? 2u : 1u;
            float th = h * 0.6, cw = th * 0.62;
            float2 p = (px - (size * 0.5 - float2(cw * float(count), th) * 0.5)) / float2(cw, th);
            if (p.x >= 0.0 && p.y >= 0.0 && p.y < 1.0 && p.x < float(count)) {
                uint digit = count == 2u && p.x < 1.0 ? tens : ones;
                if (seven_seg(float2(fract(p.x), p.y), digit) > 0.5) return float3(1.0);
            }
            return base;
        }
        case 5: {  // crosshair with circles every 1/8 of the height
            float r = length(c);
            float ring = abs(fmod(r + h / 16.0, h / 8.0) - h / 16.0);
            if (abs(c.x) < lw * 1.5 || abs(c.y) < lw * 1.5) return float3(1.0, 0.3, 0.3);
            if (border) return float3(1.0);
            return ring < lw * 1.5 ? float3(1.0) : float3(0.04);
        }
        case 6: {  // grey steps: 0–100 % in 10 % steps above, 0–10 % in 1 % steps below (black level, black lift)
            float step_ = floor(uv.x * 11.0) / 10.0;
            return float3(uv.y < 0.5 ? step_ : step_ * 0.1);
        }
        case 7: {  // checkerboard, square cells of 1/16 of the height, centred (focus, pixel geometry)
            float2 k = floor(c / (h / 16.0));
            return float3(fmod(abs(k.x + k.y), 2.0) < 1.0 ? 1.0 : 0.0);
        }
        // seam check (DESIGN §9.9): flat fields in output signal, like Blend check's 0.5 (0.25 → code 64, 0.75 → 191)
        case 8: return float3(0.0);
        case 9: return float3(0.25);
        case 10: return float3(0.75);
        case 11: return float3(1.0);
        default:
            return float3(0.0);
        }
    }

    // Generators (folder 0, DESIGN.md §8.2): drawn into a layer texture every frame.
    struct GeneratorUniforms {
        float2 size;
        uint kind;     // file number in folder 0
        uint frame;    // compositor tick count
        float time;    // seconds (for motion)
        uint pad0, pad1, pad2;
        uint4 d[5];    // characters: 0–9, 10 = colon, 11 = blank
    };

    static float gen_text(constant GeneratorUniforms& g, uint first, uint count, float2 px, float2 centre, float h) {
        float cw = h * 0.62;
        float2 p = (px - (centre - float2(cw * float(count), h) * 0.5)) / float2(cw, h);
        if (p.x < 0.0 || p.y < 0.0 || p.y >= 1.0 || p.x >= float(count)) return 0.0;
        uint i = first + uint(p.x);
        return seven_seg(float2(fract(p.x), p.y), g.d[i / 4u][i % 4u]);
    }

    fragment float4 generator_fragment(VertexOut in [[stage_in]], constant GeneratorUniforms& g [[buffer(0)]]) {
        float2 uv = in.uv;
        float2 px = uv * g.size;
        float h = g.size.y;
        float lw = max(1.0, h / 540.0);  // line width follows the resolution
        if (g.kind == 100u) return float4(1.0);
        if (g.kind >= 101u && g.kind <= 107u) return float4(test_pattern(g.kind - 100u, 1u, uv, g.size), 1.0);
        if (g.kind == 111u) {  // slow diagonal hue sweep
            float hue = fract(uv.x * 0.5 + uv.y * 0.25 + g.time * 0.05);
            return float4(hsv2rgb(float3(hue, 0.75, 0.9)), 1.0);
        }
        if (g.kind == 113u) {
            // motion test, locked to the frame counter (not to time): at a steady rate every step is equal, a dropped or
            // doubled frame shows as a jump or a stop. Top: a bar moving 16 px per frame at 1080p. Middle: stripes
            // scrolling 8 px per frame (follow them with the eyes: judder shows as stutter). Bottom: 60 cells, one lit
            // per frame; in a photo with a long exposure every cell of a run must be lit once.
            float3 c = float3(0.06);
            float step_ = lw * 16.0;
            if (uv.y > 0.08 && uv.y < 0.3) {
                float x = fmod(float(g.frame % 100000u) * step_, g.size.x + h * 0.08) - h * 0.08;
                if (px.x >= x && px.x < x + h * 0.08) c = float3(1.0);
            }
            if (uv.y > 0.38 && uv.y < 0.62) {
                float period = h / 8.0;
                float x = fmod(px.x + float(g.frame % 100000u) * lw * 8.0, period);
                c = x < period * 0.5 ? float3(0.85) : float3(0.15);
            }
            if (uv.y > 0.72 && uv.y < 0.88 && uv.x > 0.04 && uv.x < 0.96) {
                float cellW = 0.92 / 60.0;
                uint cell = uint((uv.x - 0.04) / cellW);
                float inCell = fract((uv.x - 0.04) / cellW);
                bool lit = cell == g.frame % 60u;
                c = inCell < 0.12 ? float3(0.06) : (lit ? float3(0.2, 1.0, 0.5) : float3(0.18));
            }
            return float4(c, 1.0);
        }
        if (g.kind == 112u) {  // time of day, hh:mm:ss
            float t = gen_text(g, 0u, 8u, px, g.size * 0.5, h * 0.22);
            return float4(mix(float3(0.02), float3(1.0), t), 1.0);
        }
        // 110 test card: grid, aspect circle, border, colour bars, running time and frame number, motion bar, frame flags
        float3 c = test_pattern(1u, 1u, uv, g.size) * 0.45;
        float r = length(px - g.size * 0.5);
        if (abs(r - h * 0.45) < lw * 1.5) c = float3(1.0);
        if (px.x < lw * 3.0 || px.y < lw * 3.0 || g.size.x - px.x < lw * 3.0 || g.size.y - px.y < lw * 3.0) c = float3(1.0);
        if (uv.y > 0.08 && uv.y < 0.2 && uv.x > 0.1 && uv.x < 0.9) c = test_pattern(2u, 1u, float2((uv.x - 0.1) / 0.8, 0.5), g.size);
        float boxW = h * 0.16 * 0.62 * 11.0 * 0.5 + h * 0.04;
        if (abs(uv.y - 0.5) < 0.12 && abs(px.x - g.size.x * 0.5) < boxW) c = float3(0.03);
        c = mix(c, float3(1.0), gen_text(g, 0u, 11u, px, float2(g.size.x * 0.5, h * 0.5), h * 0.16));
        c = mix(c, float3(1.0, 0.77, 0.2), gen_text(g, 11u, 6u, px, float2(g.size.x * 0.5, h * 0.7), h * 0.07));
        if (uv.y > 0.82 && uv.y < 0.9 && uv.x > 0.1 && uv.x < 0.9) {
            float x = 0.1 + 0.8 * fract(g.time);
            c = abs(uv.x - x) < 0.006 ? float3(1.0) : float3(0.08);
        }
        // alternate every frame: a dropped or doubled frame shows as both squares lit or both dark in a photo
        float sq = h * 0.06;
        bool odd = (g.frame & 1u) == 1u;
        if (px.y > sq && px.y < sq * 2.0 && px.x > sq && px.x < sq * 2.0) c = odd ? float3(0.18) : float3(1.0);
        if (px.y > sq && px.y < sq * 2.0 && px.x > g.size.x - sq * 2.0 && px.x < g.size.x - sq) c = odd ? float3(1.0) : float3(0.18);
        return float4(c, 1.0);
    }

    fragment float4 output_fragment(VertexOut in [[stage_in]],
                                    constant OutputUniforms& o [[buffer(0)]],
                                    texture2d<float> canvas [[texture(0)]],
                                    sampler linearSampler [[sampler(0)]]) {
        if (o.pattern != 0u) return float4(test_pattern(o.pattern, o.index, in.uv, o.size), 1.0);
        return float4(canvas.sample(linearSampler, in.uv).rgb, 1.0);
    }

    // Mapped output pass (DESIGN.md §9.5): slice mesh → warp → keystone → clip; canvas × mask × opacity → blend factor → colour
    // gain → black lift and black offset in linear light → intensity → dither. Slices alpha-blend over each other in
    // order (pipeline: one, one-minus-source-alpha).
    struct MappedUniforms {
        float2 size;      // region size in pixels (dither, patterns)
        float intensity;  // output intensity × output fixture (0 at a blackout or Master 0); × master on a pattern (the canvas carries it)
        float opacity;    // slice opacity
        uint flags;       // 1 = warp field present, 2 = mask present, 4 = raw (no blend/warp/mask), 8 = no blend map
        uint pattern;     // TestPattern drawn instead of the canvas (through warp and blend, no mask), 0 = canvas
        uint index;       // output number for the "output ID" pattern
        float scale;      // canvas sample factor: a held (Freeze) canvas follows the Master on the sample, not after the lift (B100)
        float4 color;     // per-output colour: gain r, g, b; a = black offset (the code value it gives on black)
        float3x3 keystone;  // Keystone homography after the warp (§9.10 item 2); the identity in raw and on previews
    };

    struct MappedVertex {
        float2 pos;  // normalized output coordinates, pre-warp
        float2 uv;   // canvas
    };

    struct MappedOut {
        float4 position [[position]];
        float2 uv;
        float2 pre;   // pre-warp output coordinates (mask, slice space)
        float2 post [[center_no_perspective]];  // final output coordinates (blend map, projector space): linear on screen
    };

    // the vertex side of MappedOut plus the clip distances, which a fragment's stage_in may not carry
    struct MappedVertexOut {
        float4 position [[position]];
        float2 uv;
        float2 pre;
        float2 post [[center_no_perspective]];
        float clip [[clip_distance]] [4];  // the output's own edges, before the keystone (§6.4a: outside the quad is black)
    };

    vertex MappedVertexOut mapped_vertex(uint vid [[vertex_id]],
                                   const device MappedVertex* vertices [[buffer(0)]],
                                   constant MappedUniforms& u [[buffer(1)]],
                                   texture2d<float> warp [[texture(0)]],
                                   sampler linearSampler [[sampler(0)]]) {
        MappedVertex v = vertices[vid];
        float2 p = v.pos;
        if ((u.flags & 1u) != 0u && (u.flags & 4u) == 0u) {
            // texel k holds f(k/(size-1)): sample at texel centres, not at pos*size
            float2 size = float2(warp.get_width(), warp.get_height());
            p = warp.sample(linearSampler, (v.pos * (size - 1.0) + 0.5) / size).xy;
        }
        // homogeneous: the rasteriser divides by w, so uv and pre stay perspective-correct across a keystoned triangle
        float3 k = u.keystone * float3(p, 1.0);
        MappedVertexOut out;
        out.position = float4(k.x * 2.0 - k.z, k.z - k.y * 2.0, 0.0, k.z);
        out.uv = v.uv;
        out.pre = v.pos;
        out.post = k.xy / k.z;
        // what the mapping puts outside the output stays outside when the keystone shrinks it: clip at p in [0, 1], which
        // is linear in clip space (p = K⁻¹·k), so the clip is exact; inside the square the DMX guard keeps w > 0
        out.clip[0] = p.x;
        out.clip[1] = 1.0 - p.x;
        out.clip[2] = p.y;
        out.clip[3] = 1.0 - p.y;
        return out;
    }

    // interleaved gradient noise: ±0.5 LSB of ordered dither without a texture
    // ponytail: blue-noise texture (DESIGN §4.4) when banding shows on a real projector
    static float ign(float2 px) {
        return fract(52.9829189 * fract(0.06711056 * px.x + 0.00583715 * px.y));
    }

    // ponytail: projector gamma fixed at 2.2 (the edges' default); a per-output gamma if a projector measurably differs
    constant float projectorGamma = \(Float(BlendMath.projectorGamma));

    // Per-output colour and the black floor (DESIGN.md §9.9): the gain multiplies the code value per channel (tuned by
    // eye); the black lift and the black offset add light, so they are added in linear light. Both are stored as the
    // code value they give on black, so Grey 0 % reads them as before; a mid grey brightens by the light they add, not
    // by their code value (a lift of 0.05 used to add 0.05 at 50 % grey instead of about 0.0013).
    static float3 output_colour(float3 c, float lift, float4 color) {
        c *= color.rgb;
        if (lift <= 0.0 && color.a <= 0.0) return c;
        float3 light = powr(max(c, 0.0), projectorGamma) + powr(max(lift, 0.0), projectorGamma) + powr(max(color.a, 0.0), projectorGamma);
        return powr(light, 1.0 / projectorGamma);
    }

    fragment float4 mapped_fragment(MappedOut in [[stage_in]],
                                    constant MappedUniforms& u [[buffer(1)]],
                                    texture2d<float> canvas [[texture(0)]],
                                    texture2d<float> mask [[texture(1)]],
                                    texture2d<float> blend [[texture(2)]],
                                    sampler linearSampler [[sampler(0)]]) {
        bool raw = (u.flags & 4u) != 0u;
        // blend factor and black lift: none in raw (no blend, warp or mask) or without a blend map. The colour is the
        // projector's, not the mapping's: it applies in raw too, like the output's intensity
        float4 b = float4(1.0, 1.0, 1.0, 0.0);  // factor r, g, b (per-channel blend gamma), lift
        if (!raw && (u.flags & 8u) == 0u) b = blend.sample(linearSampler, in.post);
        if (u.pattern != 0u) {
            // alignment: the pattern follows the warp, the blend map shows the overlaps, and the colour applies (the seam
            // check tunes the gain on Grey 25/75 % and White); at the output's level like the content (Dimmer × Master,
            // black at a blackout, Raw included), no dither
            float3 p = test_pattern(u.pattern, u.index, in.pre, u.size);
            return float4(output_colour(p * b.rgb, b.a, u.color) * u.intensity, 1.0);
        }
        float3 c = canvas.sample(linearSampler, in.uv).rgb * u.scale;
        float a = u.opacity;
        if (!raw && (u.flags & 2u) != 0u) a *= mask.sample(linearSampler, in.pre).r;
        // on the un-premultiplied colour, then × the slice's alpha (the lift and the black offset fade with the slice)
        c = output_colour(c * b.rgb, b.a, u.color) * a;
        c *= u.intensity;
        c += (ign(in.position.xy) - 0.5) / 255.0;
        return float4(c, a);
    }
    """
}
