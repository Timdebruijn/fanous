// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

/// Metal shader source, compiled at engine start (`MTLDevice.makeLibrary(source:)`)
/// so no offline Metal toolchain is needed. Kept in one string on purpose:
/// the layer uber-shader and the output pass are small.
public enum ShaderSource {
    public static let metal = """
    #include <metal_stdlib>
    using namespace metal;

    struct LayerUniforms {
        float4x4 transform;   // unit quad → clip space
        float intensity;      // 0…1, applied as premultiplied alpha
        uint kind;            // SourcePixelKind
        float textureWidth;   // for v216 pixel-pair addressing
        float padding;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    constant float2 quadPositions[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    constant float2 quadUVs[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };

    vertex VertexOut layer_vertex(uint vid [[vertex_id]], constant LayerUniforms& u [[buffer(0)]]) {
        VertexOut out;
        out.position = u.transform * float4(quadPositions[vid], 0, 1);
        out.uv = quadUVs[vid];
        return out;
    }

    // Rec.709 video range, 16-bit normalized (the ratios are the same for 10-bit).
    static float3 ycbcr_to_rgb(float y, float cb, float cr) {
        float yy = (y - 16.0 / 255.0) * (255.0 / 219.0);
        float u = (cb - 128.0 / 255.0) * (255.0 / 224.0);
        float v = (cr - 128.0 / 255.0) * (255.0 / 224.0);
        return saturate(float3(yy + 1.5748 * v, yy - 0.1873 * u - 0.4681 * v, yy + 1.8556 * u));
    }

    fragment float4 layer_fragment(VertexOut in [[stage_in]],
                                   constant LayerUniforms& u [[buffer(0)]],
                                   texture2d<float> tex0 [[texture(0)]],
                                   texture2d<float> tex1 [[texture(1)]],
                                   texture2d<float> tex2 [[texture(2)]],
                                   sampler linearSampler [[sampler(0)]],
                                   sampler nearestSampler [[sampler(1)]]) {
        float4 rgba;
        switch (u.kind) {
        case 1: {  // v216: texel = (Cb, Y0, Cr, Y1) for a pixel pair
            float px = in.uv.x * u.textureWidth;
            float2 pairUV = float2((floor(px * 0.5) + 0.5) / (u.textureWidth * 0.5), in.uv.y);
            float4 p = tex0.sample(nearestSampler, pairUV);
            float y = fract(px * 0.5) < 0.5 ? p.g : p.a;
            rgba = float4(ycbcr_to_rgb(y, p.r, p.b), 1.0);
            break;
        }
        case 2: {  // y416: (A, Y, Cb, Cr)
            float4 p = tex0.sample(linearSampler, in.uv);
            rgba = float4(ycbcr_to_rgb(p.g, p.b, p.a), p.r);
            break;
        }
        case 3:    // HAP Q: scaled YCoCg in BC3
        case 5: {  // HAP Q Alpha
            float4 c = tex0.sample(linearSampler, in.uv);
            float scale = (c.b * (255.0 / 8.0)) + 1.0;
            float co = (c.r - (0.5 * 256.0 / 255.0)) / scale;
            float cg = (c.g - (0.5 * 256.0 / 255.0)) / scale;
            float y = c.a;
            float alpha = u.kind == 5 ? tex1.sample(linearSampler, in.uv).r : 1.0;
            rgba = float4(saturate(float3(y + co - cg, y + cg, y - co - cg)), alpha);
            break;
        }
        case 4: {  // alpha-only
            rgba = float4(1.0, 1.0, 1.0, tex0.sample(linearSampler, in.uv).r);
            break;
        }
        case 6:    // bi-planar YCbCr (4:2:2 or 4:4:4)
        case 7: {  // + alpha plane
            float y = tex0.sample(linearSampler, in.uv).r;
            float2 cbcr = tex1.sample(linearSampler, in.uv).rg;
            float alpha = u.kind == 7 ? tex2.sample(linearSampler, in.uv).r : 1.0;
            rgba = float4(ycbcr_to_rgb(y, cbcr.x, cbcr.y), alpha);
            break;
        }
        default:   // straight RGBA (stills, HAP, HAP Alpha, HAP R)
            rgba = tex0.sample(linearSampler, in.uv);
            break;
        }
        float a = rgba.a * u.intensity;
        return float4(rgba.rgb * a, a);  // premultiplied, blended with (one, oneMinusSourceAlpha)
    }

    struct OutputUniforms { float2 scale; float2 offset; };

    vertex VertexOut output_vertex(uint vid [[vertex_id]]) {
        VertexOut out;
        out.position = float4(quadPositions[vid], 0, 1);
        out.uv = quadUVs[vid];
        return out;
    }

    fragment float4 output_fragment(VertexOut in [[stage_in]],
                                    texture2d<float> canvas [[texture(0)]],
                                    sampler linearSampler [[sampler(0)]]) {
        return float4(canvas.sample(linearSampler, in.uv).rgb, 1.0);
    }
    """
}
