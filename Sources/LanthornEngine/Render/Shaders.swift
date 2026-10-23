// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

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
        float4 colour;        // rgb multiply, intensity
        float4 adjust;        // brightness, contrast, saturation, hue (radians)
        float4 effect1;       // id, A, B, 0
        float4 effect2;
        float4 texel;         // 1/width, 1/height, width/height, time (s)
        uint kind;            // SourcePixelKind
        uint blend;           // BlendMode
        uint pad0;
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

    // Rec.709 video range, 16-bit normalized (the ratios are the same for 10-bit).
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
        // slot 1 is applied to the image first, so its coordinate warp runs last
        float2 uv = effect_uv(e2, u.effect2.y, u.effect2.z, in.uv, aspect);
        uv = effect_uv(e1, u.effect1.y, u.effect1.z, uv, aspect);

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

        float a = saturate(c.a) * u.colour.a;
        float3 s = saturate(c.rgb);
        float3 d = dst.rgb;
        float3 b;
        switch (u.blend) {
        case 1: b = d + s; break;                      // add
        case 2: b = 1.0 - (1.0 - s) * (1.0 - d); break; // screen
        case 3: b = s * d; break;                      // multiply
        case 4: b = d - s; break;                      // subtract
        case 5: b = abs(d - s); break;                 // difference
        case 6: b = max(s, d); break;                  // lighten
        case 7: b = min(s, d); break;                  // darken
        default: b = s; break;                         // normal
        }
        return float4(mix(d, saturate(b), a), a + dst.a * (1.0 - a));
    }

    // Output pass: canvas → drawable, or a test pattern (Master/Output fixtures).
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

    static float3 test_pattern(uint pattern, uint index, float2 uv, float2 size) {
        float2 px = uv * size;
        switch (pattern) {
        case 1: {  // grid: 100 px lines, 10 px hairlines, centre cross
            float2 m100 = fmod(px, 100.0), m10 = fmod(px, 10.0);
            float g = (m100.x < 1.0 || m100.y < 1.0) ? 1.0 : ((m10.x < 1.0 || m10.y < 1.0) ? 0.25 : 0.05);
            float2 centre = abs(px - size * 0.5);
            if (centre.x < 1.5 || centre.y < 1.5) return float3(1.0, 0.3, 0.3);
            return float3(g);
        }
        case 2: {  // colour bars (75 %), SMPTE order
            uint bar = min(7u, uint(uv.x * 8.0));
            const float3 bars[8] = { float3(0.75), float3(0.75, 0.75, 0), float3(0, 0.75, 0.75), float3(0, 0.75, 0),
                                     float3(0.75, 0, 0.75), float3(0.75, 0, 0), float3(0, 0, 0.75), float3(0) };
            return bars[bar];
        }
        case 3: {  // blend zones: linear ramps over the outer 10 % of each edge
            float2 e = min(uv, 1.0 - uv) / 0.1;
            float r = saturate(min(e.x, e.y));
            return float3(r, r * 0.5 + 0.25, 1.0 - r);
        }
        case 4: {  // output ID: solid hue per output with a 1-bit binary strip of the number
            float3 base = hsv2rgb(float3(fract(float(index) * 0.618034), 0.6, 0.6));
            if (uv.y > 0.45 && uv.y < 0.55) {
                uint bit = uint(uv.x * 8.0);
                bool on = ((index >> (7u - bit)) & 1u) == 1u;
                return on ? float3(1.0) : float3(0.0);
            }
            return base;
        }
        case 5: {  // crosshair with circles
            float2 c = px - size * 0.5;
            float r = length(c);
            float ring = fmod(r, 100.0);
            bool line = abs(c.x) < 1.0 || abs(c.y) < 1.0;
            bool circle = ring < 1.5;
            return line ? float3(1.0, 0.3, 0.3) : (circle ? float3(1.0) : float3(0.05));
        }
        case 6: {  // 11 grey steps
            return float3(floor(uv.x * 11.0) / 10.0);
        }
        case 7: {  // 64 px checkerboard
            float2 cell = floor(px / 64.0);
            return float3(fmod(cell.x + cell.y, 2.0) < 1.0 ? 1.0 : 0.0);
        }
        default:
            return float3(0.0);
        }
    }

    fragment float4 output_fragment(VertexOut in [[stage_in]],
                                    constant OutputUniforms& o [[buffer(0)]],
                                    texture2d<float> canvas [[texture(0)]],
                                    sampler linearSampler [[sampler(0)]]) {
        if (o.pattern != 0u) return float4(test_pattern(o.pattern, o.index, in.uv, o.size), 1.0);
        return float4(canvas.sample(linearSampler, in.uv).rgb, 1.0);
    }

    // Mapped output pass (DESIGN.md §9.5): slice mesh → warp → clip; canvas × mask × opacity → blend map →
    // intensity → dither. Slices alpha-blend over each other in order (pipeline: one, one-minus-source-alpha).
    struct MappedUniforms {
        float2 size;      // region size in pixels (dither, patterns)
        float intensity;  // output intensity × master intensity × output fixture
        float opacity;    // slice opacity
        uint flags;       // 1 = warp field present, 2 = mask present, 4 = raw (no blend/warp/mask), 8 = no blend map
        uint pad0, pad1, pad2;
    };

    struct MappedVertex {
        float2 pos;  // normalized output coordinates, pre-warp
        float2 uv;   // canvas
    };

    struct MappedOut {
        float4 position [[position]];
        float2 uv;
        float2 pre;   // pre-warp output coordinates (mask, slice space)
        float2 post;  // post-warp output coordinates (blend map, projector space)
    };

    vertex MappedOut mapped_vertex(uint vid [[vertex_id]],
                                   const device MappedVertex* vertices [[buffer(0)]],
                                   constant MappedUniforms& u [[buffer(1)]],
                                   texture2d<float> warp [[texture(0)]],
                                   sampler linearSampler [[sampler(0)]]) {
        MappedVertex v = vertices[vid];
        float2 p = v.pos;
        if ((u.flags & 1u) != 0u && (u.flags & 4u) == 0u) p = warp.sample(linearSampler, v.pos).xy;
        MappedOut out;
        out.position = float4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0);
        out.uv = v.uv;
        out.pre = v.pos;
        out.post = p;
        return out;
    }

    // interleaved gradient noise: ±0.5 LSB of ordered dither without a texture
    // ponytail: blue-noise texture (DESIGN §4.4) when banding shows on a real projector
    static float ign(float2 px) {
        return fract(52.9829189 * fract(0.06711056 * px.x + 0.00583715 * px.y));
    }

    fragment float4 mapped_fragment(MappedOut in [[stage_in]],
                                    constant MappedUniforms& u [[buffer(1)]],
                                    texture2d<float> canvas [[texture(0)]],
                                    texture2d<float> mask [[texture(1)]],
                                    texture2d<float> blend [[texture(2)]],
                                    sampler linearSampler [[sampler(0)]]) {
        float3 c = canvas.sample(linearSampler, in.uv).rgb;
        float a = u.opacity;
        bool raw = (u.flags & 4u) != 0u;
        if (!raw && (u.flags & 2u) != 0u) a *= mask.sample(linearSampler, in.pre).r;
        c *= a;
        if (!raw && (u.flags & 8u) == 0u) {
            float2 b = blend.sample(linearSampler, in.post).rg;
            c = c * b.x + b.y * a;
        }
        c *= u.intensity;
        c += (ign(in.position.xy) - 0.5) / 255.0;
        return float4(c, a);
    }
    """
}
