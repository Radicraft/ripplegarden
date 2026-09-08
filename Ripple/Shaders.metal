#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Shared types (kept in sync by hand with WaterRenderer.swift). Every field is
// a float4/uint4 so the Swift and Metal layouts cannot drift apart.
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
    float  shallowSpeed;  // c2 multiplier where the depth map reads 0 (just above a wall)
    float  _pad0, _pad1, _pad2;
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
    float4 waterTint;    // season colour cast on the refracted floor (rgb) + strength (a)
};

struct FloorParams {
    float4 viewport;      // xy = drawable size in pixels
    float4 deep;          // season floor palette
    float4 mid;
    float4 shallow;
    float4 mosaic;        // xy = centre in uv, z = radius as a fraction of height, w = ghost alpha
    float4 counts;        // x = sector count
    float4 reveal[4];     // 16 per-sector reveal amounts, 0...1
};

// ---------------------------------------------------------------------------
// Simulation
//
//   v += laplacian(h) * c2
//   v *= damping
//   h += v
//
// with two additions. In shallow water the wave speed depends on depth,
// c = sqrt(g * (H + h)), so a crest travels faster than a trough. Making c2
// depend on the local height reproduces that. It is what stops two ripples
// from sliding through each other like ghosts: crests steepen, the meeting
// point piles up, and the collision leaves a mark instead of passing clean
// through. The clamp keeps the step inside its stability limit.
//
// The second is the depth map. A cell reading zero is a wall: its height is
// pinned to zero, so neighbouring cells see a fixed end and reflect. Between
// zero and one the water is shallow and waves slow down, so a wavefront
// crossing a slope bends the way light bends through glass.
// ---------------------------------------------------------------------------

kernel void wave_step(texture2d<float, access::read>  src   [[texture(0)]],
                      texture2d<float, access::write> dst   [[texture(1)]],
                      texture2d<float, access::read>  depth [[texture(2)]],
                      constant SimParams &p                 [[buffer(0)]],
                      constant Splat *splats                [[buffer(1)]],
                      uint2 gid                             [[thread_position_in_grid]])
{
    if (gid.x >= p.size.x || gid.y >= p.size.y) { return; }

    float d = depth.read(gid).r;
    if (d < 0.02) {
        dst.write(float4(0.0, 0.0, 0.0, 0.0), gid);
        return;
    }

    uint2 maxc = p.size - 1;
    uint2 l = uint2(gid.x > 0 ? gid.x - 1 : 0, gid.y);
    uint2 r = uint2(min(gid.x + 1, maxc.x), gid.y);
    uint2 dn = uint2(gid.x, gid.y > 0 ? gid.y - 1 : 0);
    uint2 up = uint2(gid.x, min(gid.y + 1, maxc.y));

    float2 c = src.read(gid).rg;
    float  h = c.r;
    float  v = c.g;

    float lap = src.read(l).r + src.read(r).r + src.read(dn).r + src.read(up).r - 4.0 * h;

    float speed = mix(p.shallowSpeed, 1.0, smoothstep(0.0, 1.0, d));
    float c2 = clamp(p.c2 * (1.0 + h * p.nonlinearity) * speed, 0.02, 0.46);

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
// Probes. The game asks "what is the water doing under this floating thing?"
// for a few dozen points a frame. Reading the whole field back would cost
// megabytes; reading a handful of cells costs nothing.
//
// result = (height, dh/dx, dh/dy, vertical velocity), all in cell units.
// ---------------------------------------------------------------------------

kernel void sample_field(texture2d<float, access::read> field   [[texture(0)]],
                         constant float2 *probes                [[buffer(0)]],
                         device float4 *results                 [[buffer(1)]],
                         constant uint &count                   [[buffer(2)]],
                         uint i                                 [[thread_position_in_grid]])
{
    if (i >= count) { return; }
    float2 size = float2(field.get_width(), field.get_height());
    float2 p = clamp(probes[i], float2(2.0), size - 3.0);
    uint2 c = uint2(p);

    // Average over a small footprint so a one-cell spike cannot fling a petal.
    float hL = 0.5 * (field.read(uint2(c.x - 2, c.y)).r + field.read(uint2(c.x - 1, c.y)).r);
    float hR = 0.5 * (field.read(uint2(c.x + 2, c.y)).r + field.read(uint2(c.x + 1, c.y)).r);
    float hD = 0.5 * (field.read(uint2(c.x, c.y - 2)).r + field.read(uint2(c.x, c.y - 1)).r);
    float hU = 0.5 * (field.read(uint2(c.x, c.y + 2)).r + field.read(uint2(c.x, c.y + 1)).r);
    float2 hv = field.read(c).rg;

    results[i] = float4(hv.r, (hR - hL) / 3.0, (hU - hD) / 3.0, hv.g);
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
// Floor bake. Runs once per resize, and again on any frame the mosaic reveal
// is animating, into its own texture. The water shader then samples it three
// times for chromatic dispersion.
//
// The mosaic is a roundel etched into the pond floor. It sits under a film of
// silt; each cleared piece of debris lifts the silt off one sector, wiping
// outward from the centre. Under the silt it is a ghost, so the player senses
// that something is there before they know what.
// ---------------------------------------------------------------------------

fragment float4 floor_fragment(VertexOut in                             [[stage_in]],
                               texture2d<float, access::sample> mosaic  [[texture(0)]],
                               constant FloorParams &p                  [[buffer(0)]])
{
    constexpr sampler smp(filter::linear, address::clamp_to_edge);

    float aspect = p.viewport.x / p.viewport.y;
    float2 q = float2(in.uv.x * aspect, in.uv.y);

    float3 deep    = p.deep.rgb;
    float3 mid     = p.mid.rgb;
    float3 shallow = p.shallow.rgb;

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

    // --- the mosaic ---------------------------------------------------------
    float2 centre = float2(p.mosaic.x * aspect, p.mosaic.y);
    float  radius = p.mosaic.z;
    float2 rel = (q - centre) / radius;
    float  r = length(rel);
    if (r < 1.0) {
        float2 muv = rel * 0.5 + 0.5;
        float4 m = mosaic.sample(smp, muv);

        uint sectors = max(uint(p.counts.x), 1u);
        float ang = atan2(rel.y, rel.x) + M_PI_F;             // 0 ... 2pi
        uint s = min(uint(ang / (2.0 * M_PI_F) * float(sectors)), sectors - 1);
        float rv = p.reveal[s >> 2][s & 3];

        // Wipe outward from the centre, with a soft leading edge.
        float edge = rv * 1.18;
        float shown = 1.0 - smoothstep(edge - 0.10, edge + 0.04, r);
        shown *= step(0.001, rv);

        // Neighbouring sectors bleed a little into each other so the seams
        // between them read as silt drifting rather than as pie slices.
        float ghost = p.mosaic.w;
        float alpha = m.a * mix(ghost, 1.0, shown);

        // Tone the tile toward the floor so it reads as stone under water,
        // not as a sticker on top of it.
        float3 tile = m.rgb * 0.70 + col * 0.30;
        tile = mix(col, tile, 0.84);
        col = mix(col, tile, alpha);
    }

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

    // Season cast: the water column itself carries a colour.
    col = mix(col, col * p.waterTint.rgb, p.waterTint.a);

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
