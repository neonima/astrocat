#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    /// Columns of the map from normalised device coordinates to texture
    /// coordinates. Zoom, pan, rotation, flip and the aspect fit are all
    /// resolved into this on the CPU, so the shader only multiplies.
    float2 viewX;
    float2 viewY;
    float2 viewC;
    float3 shadows;
    float3 midtone;
    float3 calOffset;
    float3 calGain;
    float3 paletteR;
    float3 paletteG;
    float3 paletteB;
    int algorithm;
    float p0;
    float p1;
    float blend;
    float saturation;
    int zonesOn;
    float exposure;
    float contrast;
    float toneHighlights;
    float toneShadows;
    float whites;
    float blacks;
    float vibrance;
    float scnr;
    float clarity;
    float texture;
    int opCount;
    /// Set on the pass that reaches the screen. The offscreen pass leaves it
    /// clear so its blur sees edge-extended pixels instead of a black border,
    /// which would darken the rim of the frame.
    int maskOutside;
    /// The kept region, x0 y0 x1 y1 in texture units. Everything outside is
    /// black, so zooming out shows the crop shrinking on the canvas rather than
    /// revealing what the crop was meant to remove.
    float4 crop;
};

/// Covers the whole target and folds the aspect fit into the texture
/// coordinate instead of the quad, so the offscreen pass is edge-extended
/// rather than letterboxed — a blur over a black border would darken the rim.
struct VOut {
    float4 pos [[position]];
    /// Where to sample the source frame: carries the aspect fit, so it leaves
    /// [0,1] in the letterbox.
    float2 uv;
    /// Where this fragment sits in the target. The offscreen pass has already
    /// baked the fit in, so anything sampling its output must use this instead
    /// or the fit is applied twice.
    float2 screen;
};

/// Both passes cover the whole target and place the frame through the view
/// matrix, so panning and zooming cost nothing beyond the coordinate they
/// already had to compute.
static inline VOut place(float2 pos, constant Uniforms &u) {
    VOut o;
    o.pos = float4(pos, 0, 1);
    o.uv = u.viewX * pos.x + u.viewY * pos.y + u.viewC;
    // Rendering puts NDC y=+1 at texture row 0, and sampling puts v=0 there
    // too, so reading back the same fragment means flipping y.
    o.screen = float2(pos.x * 0.5 + 0.5, 0.5 - pos.y * 0.5);
    return o;
}

vertex VOut v_image(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
    const float2 pos[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    return place(pos[vid], u);
}

static inline float mtf(float m, float x) {
    if (x <= 0.0) return 0.0;
    if (x >= 1.0) return 1.0;
    if (abs(m - 0.5) < 1e-6) return x;
    return ((m - 1.0) * x) / (((2.0 * m - 1.0) * x) - m);
}

static inline float apply_arcsinh(float x, float k) {
    return asinh(k * x) / asinh(k);
}

static inline float apply_log(float x, float k) {
    return log(1.0 + k * x) / log(1.0 + k);
}

/// Generalised hyperbolic: `p0` is stretch, `p1` the symmetry point around
/// which contrast is added rather than crushed.
static inline float apply_gh(float x, float d, float sp) {
    float t = x - sp;
    float s = (d <= 0.0) ? t : (asinh(d * t) / asinh(d * max(1.0 - sp, sp)));
    return saturate(s * max(1.0 - sp, sp) + sp);
}

/// Interpolated so 256 entries do not band a 16-bit source.
static inline float zone_curve(constant float *table, float x) {
    float t = saturate(x) * 255.0;
    uint i = uint(t);
    uint j = min(i + 1u, 255u);
    return mix(table[i], table[j], t - float(i));
}

/// Re-lights a colour from one luminance to another.
///
/// Scaling by the ratio preserves hue, which is what you want in the midtones.
/// But the ratio is unbounded as luminance falls, and blue carries only 0.07 of
/// it — so a dark blue-leaning pixel gets an enormous multiplier and the blue
/// runs away. Fade to an additive lift where there is not enough luminance to
/// safely divide by.
static inline float3 relight(float3 v, float from, float to) {
    float weight = smoothstep(0.0, 0.05, from);
    return mix(v + (to - from), v * (to / max(from, 1e-4)), weight);
}

/// Lightroom-style tonal controls, following the shapes the Lighthouse script
/// uses: exposure as a soft compression rather than a multiply so highlights
/// roll instead of clipping, contrast as a cubic that pins both ends, and
/// blacks/whites as range remaps.
static inline float tone_luma(constant Uniforms &u, float l) {
    if (abs(u.exposure) > 1e-6) {
        float scale = exp2(u.exposure * (u.exposure > 0.0 ? 0.72 : 0.62));
        l = (l * scale) / (1.0 + l * (scale - 1.0));
    }
    if (abs(u.contrast) > 1e-6) {
        float c = 0.48 * u.contrast;
        float x = saturate(l);
        l = x + 4.0 * c * (x - 0.5) * x * (1.0 - x);
    }
    if (u.blacks < 0.0) {
        float bp = min(0.95, -u.blacks * 0.22);
        l = max((l - bp) / (1.0 - bp), 0.0);
    } else if (u.blacks > 0.0) {
        float lift = min(0.95, u.blacks * 0.22);
        l = lift + (1.0 - lift) * l;
    }
    if (u.whites > 0.0) {
        l = max(l / max(0.05, 1.0 - u.whites * 0.22), 0.0);
    } else if (u.whites < 0.0) {
        l = (1.0 - min(0.95, -u.whites * 0.22)) * l;
    }
    return l;
}

/// Shadows and highlights act through smooth masks on the pre-adjustment
/// luminance, so a lift stays in the band it was aimed at.
static inline float tone_bands(constant Uniforms &u, float l, float base) {
    if (abs(u.toneHighlights) > 1e-6) {
        float mask = pow(saturate((base - 0.25) / 0.75), 1.3);
        if (u.toneHighlights < 0.0) {
            float amount = -u.toneHighlights;
            float comp = l / (1.0 + amount * 3.0 * mask * l);
            l = mix(l, comp, mask * amount);
        } else {
            l += u.toneHighlights * mask * (1.0 - saturate(l) * saturate(l)) * 0.5;
        }
    }
    if (abs(u.toneShadows) > 1e-6) {
        float mask = pow(saturate((0.5 - base) / 0.5), 1.3);
        l += u.toneShadows * mask * saturate(1.0 - l) * 0.5;
    }
    return saturate(l);
}

vertex VOut v_offscreen(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
    const float2 pos[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    return place(pos[vid], u);
}

/// Unsharp masking at two radii: coarse for structure, fine for grain. Both act
/// on luminance, because sharpening chroma on a colour-sensor frame amplifies
/// demosaic artefacts rather than detail.
fragment float4 f_composite(VOut in [[stage_in]],
                            texture2d<float> scene [[texture(0)]],
                            texture2d<float> coarse [[texture(1)]],
                            texture2d<float> fine [[texture(2)]],
                            constant Uniforms &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    // The offscreen pass deliberately leaves the region outside unmasked so the
    // blur has something to reach into and does not darken the rim, which makes
    // this the only place the crop gets enforced on the two-pass path.
    if (any(in.uv < u.crop.xy) || any(in.uv > u.crop.zw)) return float4(0, 0, 0, 1);

    float3 base = scene.sample(s, in.screen).rgb;
    const float3 W = float3(0.2126, 0.7152, 0.0722);
    float bl = dot(base, W);

    float detail = 0.0;
    if (abs(u.clarity) > 1e-6) detail += u.clarity * (bl - dot(coarse.sample(s, in.screen).rgb, W));
    if (abs(u.texture) > 1e-6) detail += u.texture * (bl - dot(fine.sample(s, in.screen).rgb, W));

    // Local contrast in the sky background is local contrast in the noise: it
    // is the one part of an astro frame with no structure to bring out.
    detail *= smoothstep(0.0, 0.08, bl);
    if (abs(detail) < 1e-7) return float4(base, 1.0);

    return float4(saturate(relight(base, bl, saturate(bl + detail))), 1.0);
}

static inline float3 op_calibrate(constant Uniforms &u, float3 v) {
    return (v - u.calOffset) * u.calGain;
}

static inline float3 op_palette(constant Uniforms &u, float3 v) {
    return float3(dot(u.paletteR, v), dot(u.paletteG, v), dot(u.paletteB, v));
}

static inline float3 op_stretch(constant Uniforms &u, float3 v, constant float *lut) {
    float3 c = saturate((v - u.shadows) / max(float3(1e-6), 1.0 - u.shadows));
    float3 o = c;
    switch (u.algorithm) {
        case 0: o = c; break;
        case 1: o = float3(mtf(u.midtone.r, c.r), mtf(u.midtone.g, c.g), mtf(u.midtone.b, c.b)); break;
        case 2: o = float3(apply_arcsinh(c.r, u.p0), apply_arcsinh(c.g, u.p0), apply_arcsinh(c.b, u.p0)); break;
        case 3: o = float3(apply_gh(c.r, u.p0, u.p1), apply_gh(c.g, u.p0, u.p1), apply_gh(c.b, u.p0, u.p1)); break;
        case 4: o = float3(apply_log(c.r, u.p0), apply_log(c.g, u.p0), apply_log(c.b, u.p0)); break;
        case 5: {
            uint3 i = uint3(saturate(c) * 255.0);
            o = float3(lut[i.r], lut[i.g], lut[i.b]);
            break;
        }
    }
    float3 mixed = mix(c, saturate(o), u.blend);
    float luma = dot(mixed, float3(0.2126, 0.7152, 0.0722));
    return saturate(mix(float3(luma), mixed, u.saturation));
}

static inline float3 op_zones(float3 v, constant float *zones) {
    return float3(zone_curve(zones, v.r), zone_curve(zones, v.g), zone_curve(zones, v.b));
}

static inline float3 op_tone(constant Uniforms &u, float3 v) {
    const float3 W = float3(0.2126, 0.7152, 0.0722);
    float base = dot(v, W);
    float toned = tone_bands(u, tone_luma(u, base), base);
    v = saturate(relight(v, base, toned));

    float peak = max(v.r, max(v.g, v.b));
    float sat = (peak - min(v.r, min(v.g, v.b))) / max(peak, 1e-5);
    if (abs(u.vibrance) > 1e-6) {
        float amount = 1.0 + (u.vibrance > 0.0 ? u.vibrance * 1.8 : u.vibrance) * (1.0 - sat);
        v = saturate(mix(float3(dot(v, W)), v, amount));
    }
    if (u.scnr > 0.0) {
        v.g = mix(v.g, min(v.g, 0.5 * (v.r + v.b)), u.scnr);
    }
    return v;
}

/// Walks the operation list rather than a fixed sequence. Order is the user's
/// to choose except where it would be meaningless, and those cases are refused
/// before they reach here.
fragment float4 f_image(VOut in [[stage_in]],
                        texture2d<float> tex [[texture(0)]],
                        constant Uniforms &u [[buffer(0)]],
                        constant float *lut [[buffer(1)]],
                        constant float *zones [[buffer(2)]],
                        constant int *ops [[buffer(3)]]) {
    // Mip filtering is not optional at full resolution. Fitting 3840 rows into
    // a few hundred pixels of pane point-samples a periodic subset, and on
    // 1-2px stars that reads as a regular lattice rather than a star field.
    // Averaging happens on linear values, before the stretch, which is the same
    // thing the binned proxy used to do and the physically correct order.
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    if (u.maskOutside != 0 && (any(in.uv < u.crop.xy) || any(in.uv > u.crop.zw))) {
        return float4(0, 0, 0, 1);
    }
    float3 v = tex.sample(s, in.uv).rgb;

    for (int i = 0; i < u.opCount; i++) {
        switch (ops[i]) {
            case 1: v = op_calibrate(u, v); break;
            case 2: v = op_palette(u, v); break;
            case 3: v = op_stretch(u, v, lut); break;
            case 4: v = op_zones(v, zones); break;
            case 5: v = op_tone(u, v); break;
        }
    }
    return float4(saturate(v), 1.0);
}
