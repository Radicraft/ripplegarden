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
    float  c2;            // wave speed squared * dt^2
    float  damping;       // velocity retained per step
    float  edgeDamp;      // extra damping applied in the border band
    uint   edgeBand;      // width of that band, in cells
    float  nonlinearity;  // how much a crest outruns a trough
    uint   splatCount;
};

struct RenderParams {
    uint2  size;         // sim grid size
    float2 viewport;     // drawable size in pixels
    float  refraction;
    float  causticGain;
    float  specGain;
    float  time;
    float  crestGain;    // how hard a meeting of two crests announces itself
    float  sparkleGain;
    float  detailGain;   // fine capillary chop riding on the big waves
    float  dispersion;   // chromatic spread in the refraction
};

struct FloorParams {
    float2 viewport;
};

// ---------------------------------------------------------------------------
// Simulation
//
//   v += laplacian(h) * c2
//   v *= damping
//   h += v
//
// with one addition: in shallow water the wave speed depends on depth,
// c = sqrt(g * (H + h)), so a crest travels faster than a trough. Making c2
// depend on the local height reproduces that. It is what stops two ripples
// from sliding through each other like ghosts: crests steepen, the meeting
// point piles up, and the collision leaves a mark instead of passing clean
// through. The clamp keeps the step inside its stability limit.
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

    float c2 = clamp(p.c2 * (1.0 + h * p.nonlinearity), 0.02, 0.46);

    v += lap * c2;
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

    for (uint i = 0; i < p.splatCount; ++i) {
        float2 delta = float2(gid) - splats[i].pos;
        float  dist2 = dot(delta, delta);
        float  rad   = splats[i].radius;
        if (dist2 < rad * rad) {
            // Smooth cosine bump: no hard edges, so no high-frequency buzz.
            float falloff = 0.5 + 0.5 * cos(M_PI_F * sqrt(dist2) / rad);
            h += splats[i].amplitude * falloff;
        }
    }

    dst.write(float4(h, v, 0.0, 0.0), gid);
}

// ---------------------------------------------------------------------------
// Shared bits
// ---------------------------------------------------------------------------

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut fullscreen_vertex(uint vid [[vertex_id]])
{
    float2 p = float2((vid << 1) & 2, vid & 2);
    VertexOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

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

static float fbm(float2 p, int octaves)
{
    float sum = 0.0, amp = 0.5, norm = 0.0;
    for (int i = 0; i < octaves; ++i) {
        sum  += valueNoise(p) * amp;
        norm += amp;
        p    *= 2.02;
        amp  *= 0.5;
    }
    return sum / norm;
}

// ---------------------------------------------------------------------------
// Floor bake. This runs once per resize into its own texture, so it can afford
// detail the per-frame path never could. The water shader then samples it three
// times for chromatic dispersion at the cost of three texture reads.
// ---------------------------------------------------------------------------

fragment float4 floor_fragment(VertexOut in           [[stage_in]],
                               constant FloorParams &p [[buffer(0)]])
{
    float aspect = p.viewport.x / p.viewport.y;
    float2 q = float2(in.uv.x * aspect, in.uv.y);

    float3 deep    = float3(0.012, 0.046, 0.066);
    float3 mid     = float3(0.036, 0.120, 0.142);
    float3 shallow = float3(0.082, 0.208, 0.226);

    // Light pools toward the upper third, the way a window falls on a basin.
    float radial = distance(q, float2(0.5 * aspect, 0.30));
    float lift   = smoothstep(1.15, 0.02, radial);

    float3 col = mix(deep, mix(mid, shallow, lift * lift), lift);

    // Grain, kept high-frequency. Low-frequency noise on a floor this large
    // reads as fog rather than as a surface.
    float big   = fbm(q * 5.5, 4);
    float small = fbm(q * 19.0, 4);
    col *= 0.90 + 0.20 * big;
    col *= 0.94 + 0.12 * small;

    // A few darker patches, like stones settled on the bottom.
    float patch = smoothstep(0.60, 0.82, fbm(q * 7.2 + 11.3, 3));
    col = mix(col, col * 0.70, patch * 0.70);

    // Warm sediment, only where the light already reaches.
    col += float3(0.032, 0.023, 0.009) * lift * smoothstep(0.50, 0.88, small);

    // Very low contrast banding, to break up the flat areas.
    col += 0.007 * sin(q.y * 62.0 + big * 7.0);

    return float4(max(col, 0.0), 1.0);
}

// ---------------------------------------------------------------------------
// Water
// ---------------------------------------------------------------------------

/// What the surface reflects. Not a real environment map, just a gradient with
/// a sun in it, but the sun is what sells a moving surface.
static float3 skyLook(float3 R, float3 L)
{
    float up = saturate(R.z);
    float3 zenith  = float3(0.075, 0.155, 0.225);
    float3 horizon = float3(0.400, 0.530, 0.580);
    float3 sky = mix(horizon, zenith, pow(up, 0.65));
    float sun = pow(saturate(dot(R, L)), 180.0);
    sky += float3(1.00, 0.95, 0.86) * sun * 2.4;
    return sky;
}

fragment float4 water_fragment(VertexOut in                              [[stage_in]],
                               texture2d<float, access::sample> field     [[texture(0)]],
                               texture2d<float, access::sample> floorTex  [[texture(1)]],
                               constant RenderParams &p                   [[buffer(0)]])
{
    constexpr sampler smp(filter::linear, address::clamp_to_edge);

    float2 texel = 1.0 / float2(p.size);

    float hL = field.sample(smp, in.uv - float2(texel.x, 0)).r;
    float hR = field.sample(smp, in.uv + float2(texel.x, 0)).r;
    float hD = field.sample(smp, in.uv - float2(0, texel.y)).r;
    float hU = field.sample(smp, in.uv + float2(0, texel.y)).r;
    float hC = field.sample(smp, in.uv).r;

    float2 grad = float2(hR - hL, hU - hD) * 0.5;
    float  lap  = (hL + hR + hD + hU - 4.0 * hC);

    // How busy this patch of water is. Fine chop only appears on water that is
    // already moving, so still water stays glassy.
    float activity = saturate(abs(hC) * 5.0 + abs(lap) * 26.0);

    // Capillary detail: small fast ripples riding on the big slow ones. Two
    // noise taps differenced into a gradient, scrolling against each other.
    float2 dp = float2(0.004, 0.0);
    float2 sc = in.uv * 34.0 + float2(p.time * 0.55, -p.time * 0.42);
    float  n0 = valueNoise(sc);
    float2 fineGrad = float2(valueNoise(sc + dp.xy) - n0,
                             valueNoise(sc + dp.yx) - n0);

    float3 N = normalize(float3(-(grad * 46.0 + fineGrad * p.detailGain * activity), 1.0));

    // --- refraction, with dispersion ---------------------------------------
    // Red bends least, blue most. A single-channel offset looks like plastic;
    // the split is most of what makes it read as water.
    float2 offset = grad * p.refraction;
    float  spread = p.dispersion;
    float3 col;
    col.r = floorTex.sample(smp, in.uv + offset * (1.0 + spread)).r;
    col.g = floorTex.sample(smp, in.uv + offset).g;
    col.b = floorTex.sample(smp, in.uv + offset * (1.0 - spread)).b;

    // Deeper apparent path length under a trough: tint and darken slightly.
    float depth = saturate(-hC * 1.6 + length(offset) * 5.0);
    col *= mix(1.0, 0.80, depth);
    col = mix(col, col * float3(0.72, 0.96, 1.06), depth * 0.65);

    // --- caustics -----------------------------------------------------------
    // Converging rays brighten the floor. The laplacian stands in for that
    // convergence and costs four taps already paid for above.
    float caustic = clamp(-lap * p.causticGain, -0.6, 2.2);
    col += float3(0.40, 0.74, 0.80) * max(caustic, 0.0) * 0.50;
    col *= 1.0 + min(caustic, 0.0) * 0.34;

    // --- where two crests meet ---------------------------------------------
    // Superposition doubles the height. Keying a bloom off a threshold the
    // single wave sits below means a lone ripple stays quiet and a collision
    // flares, which is the whole readability problem in one term.
    float crest = smoothstep(0.055, 0.20, hC);
    col += float3(0.62, 0.86, 0.92) * crest * p.crestGain;

    // --- lighting -----------------------------------------------------------
    float3 L = normalize(float3(-0.40, 0.56, 0.72));
    float3 V = float3(0.0, 0.0, 1.0);
    float3 H = normalize(L + V);

    float tight = pow(max(dot(N, H), 0.0), 220.0);
    float broad = pow(max(dot(N, H), 0.0), 26.0);
    col += float3(0.85, 0.94, 1.00) * (tight * 1.5 + broad * 0.16) * p.specGain;

    // Schlick fresnel, F0 = 0.02 for water. Near flat we look straight through
    // to the floor; on the steep flank of a wave the sky takes over.
    float f = 0.02 + 0.98 * pow(1.0 - saturate(N.z), 5.0);
    float3 R = reflect(-V, N);
    col = mix(col, skyLook(R, L), saturate(f * 1.5));

    // --- sparkle ------------------------------------------------------------
    // Twinkling specks on the brightest caustic bands. Quantised in space and
    // time so they pop on and off rather than sliding around.
    float cell  = hash21(floor(in.uv * p.viewport / 3.0) + floor(p.time * 18.0));
    float glint = step(0.9955, cell) * smoothstep(0.35, 1.3, caustic + crest);
    col += float3(1.0, 0.99, 0.95) * glint * p.sparkleGain;

    // --- finish -------------------------------------------------------------
    float2 vc = in.uv - 0.5;
    col *= 1.0 - dot(vc, vc) * 0.40;
    col += (hash21(in.uv * p.viewport + p.time) - 0.5) * (1.5 / 255.0);

    return float4(col, 1.0);
}
