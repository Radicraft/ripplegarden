#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Shared types (kept in sync by hand with WaterRenderer.swift)
// ---------------------------------------------------------------------------

struct Splat {
    float2 pos;        // in sim-grid cells
    float  radius;     // in cells
    float  amplitude;  // signed; negative = a dip, which is what a finger makes
};

struct SimParams {
    uint2  size;
    float  c2;         // wave speed squared * dt^2
    float  damping;    // velocity retained per step
    float  edgeDamp;   // extra damping applied in the border band
    uint   edgeBand;   // width of that band, in cells
    uint   splatCount;
};

struct RenderParams {
    uint2  size;         // sim grid size
    float2 viewport;     // drawable size in pixels
    float  refraction;   // how far the surface bends the floor
    float  causticGain;
    float  specGain;
    float  time;
};

// ---------------------------------------------------------------------------
// Simulation: damped wave equation on a height field.
//
//   v += laplacian(h) * c2
//   v *= damping
//   h += v
//
// Boundaries clamp, which makes the screen edges reflective. A narrow band of
// extra damping at the border stops the whole basin ringing forever.
// ---------------------------------------------------------------------------

kernel void wave_step(texture2d<float, access::read>  src   [[texture(0)]],
                      texture2d<float, access::write> dst   [[texture(1)]],
                      constant SimParams &p                 [[buffer(0)]],
                      constant Splat *splats                [[buffer(1)]],
                      uint2 gid                             [[thread_position_in_grid]])
{
    if (gid.x >= p.size.x || gid.y >= p.size.y) { return; }

    uint2 maxc = p.size - 1;
    uint2 l = uint2(gid.x > 0 ? gid.x - 1 : 0, gid.y);
    uint2 r = uint2(min(gid.x + 1, maxc.x), gid.y);
    uint2 d = uint2(gid.x, gid.y > 0 ? gid.y - 1 : 0);
    uint2 u = uint2(gid.x, min(gid.y + 1, maxc.y));

    float2 c = src.read(gid).rg;
    float  h = c.r;
    float  v = c.g;

    float lap = src.read(l).r + src.read(r).r + src.read(d).r + src.read(u).r - 4.0 * h;

    v += lap * p.c2;
    v *= p.damping;

    // Soft absorbing border.
    uint edgeDist = min(min(gid.x, maxc.x - gid.x), min(gid.y, maxc.y - gid.y));
    if (edgeDist < p.edgeBand) {
        float t = 1.0 - float(edgeDist) / float(p.edgeBand);
        float k = mix(1.0, p.edgeDamp, t * t);
        v *= k;
        h *= k;
    }

    h += v;

    // Inject this frame's touches. A finger pushes water down, then the
    // surface tension pulls it back up; that rebound is what reads as a ripple.
    for (uint i = 0; i < p.splatCount; ++i) {
        float2 delta = float2(gid) - splats[i].pos;
        float  dist2 = dot(delta, delta);
        float  rad   = splats[i].radius;
        float  r2    = rad * rad;
        if (dist2 < r2) {
            // Smooth cosine bump: no hard edges, so no high-frequency buzz.
            float falloff = 0.5 + 0.5 * cos(M_PI_F * sqrt(dist2) / rad);
            h += splats[i].amplitude * falloff;
        }
    }

    dst.write(float4(h, v, 0.0, 0.0), gid);
}

// ---------------------------------------------------------------------------
// Render: fullscreen triangle, no vertex buffer.
// ---------------------------------------------------------------------------

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut fullscreen_vertex(uint vid [[vertex_id]])
{
    // One oversized triangle covering the clip rect.
    float2 p = float2((vid << 1) & 2, vid & 2);
    VertexOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

// Cheap value noise, used only for large-scale mottling on the floor.
static float hash21(float2 p)
{
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 34.56);
    return fract(p.x * p.y);
}

static float valueNoise(float2 p)
{
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1));
    float d = hash21(i + float2(1, 1));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// What lies under the water. Deliberately quiet: a cool slate basin with soft
// mottling, so the ripples are the only thing with edges.
static float3 poolFloor(float2 uv, float aspect)
{
    float2 p = float2(uv.x * aspect, uv.y);

    float3 deep    = float3(0.031, 0.098, 0.129);
    float3 shallow = float3(0.086, 0.216, 0.243);

    // Light pooling toward the upper third.
    float radial = distance(p, float2(0.5 * aspect, 0.34));
    float lift   = smoothstep(1.05, 0.05, radial);

    float3 base = mix(deep, shallow, lift);

    float n = valueNoise(p * 3.4) * 0.6 + valueNoise(p * 8.1) * 0.4;
    base *= 0.88 + 0.24 * n;

    // Faint sediment banding, very low contrast.
    base += 0.012 * sin(p.y * 44.0 + n * 6.0);

    return base;
}

fragment float4 water_fragment(VertexOut in                            [[stage_in]],
                               texture2d<float, access::sample> field   [[texture(0)]],
                               constant RenderParams &p                 [[buffer(0)]])
{
    constexpr sampler smp(filter::linear, address::clamp_to_edge);

    float2 texel  = 1.0 / float2(p.size);
    float  aspect = p.viewport.x / p.viewport.y;

    float hL = field.sample(smp, in.uv - float2(texel.x, 0)).r;
    float hR = field.sample(smp, in.uv + float2(texel.x, 0)).r;
    float hD = field.sample(smp, in.uv - float2(0, texel.y)).r;
    float hU = field.sample(smp, in.uv + float2(0, texel.y)).r;
    float hC = field.sample(smp, in.uv).r;

    float2 grad = float2(hR - hL, hU - hD) * 0.5;
    float3 N = normalize(float3(-grad * 42.0, 1.0));

    // Refraction: the surface slope displaces where we look at the floor.
    float2 offset = grad * p.refraction;
    float3 col = poolFloor(in.uv + offset, aspect);

    // Caustics. Converging rays brighten; the laplacian is a good stand-in for
    // that convergence and costs four taps we have already paid for.
    float lap = (hL + hR + hD + hU - 4.0 * hC);
    float caustic = clamp(-lap * p.causticGain, -0.55, 1.6);
    col += float3(0.42, 0.72, 0.78) * max(caustic, 0.0) * 0.55;
    col *= 1.0 + min(caustic, 0.0) * 0.30;

    // Specular glint from a fixed key light.
    float3 L = normalize(float3(-0.42, 0.58, 0.70));
    float3 V = float3(0.0, 0.0, 1.0);
    float3 H = normalize(L + V);
    float  spec = pow(max(dot(N, H), 0.0), 96.0);
    col += float3(0.80, 0.92, 1.0) * spec * p.specGain;

    // Fresnel toward a cold sky at grazing slopes; adds body to big swells.
    float fres = pow(1.0 - max(N.z, 0.0), 3.0);
    col = mix(col, float3(0.36, 0.55, 0.63), fres * 0.5);

    // Vignette, then a touch of dither so the wide flat gradients do not band.
    float2 vc = in.uv - 0.5;
    col *= 1.0 - dot(vc, vc) * 0.42;
    col += (hash21(in.uv * p.viewport + p.time) - 0.5) * (1.5 / 255.0);

    return float4(col, 1.0);
}
