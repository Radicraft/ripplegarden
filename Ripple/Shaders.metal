#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Shared types (kept in sync by hand with WaterRenderer.swift and
// Sprites.swift). Fields are ordered so Swift and Metal agree on padding.
// ---------------------------------------------------------------------------

struct Splat {
    float2 pos;        // in sim-grid cells
    float  radius;     // in cells
    float  amplitude;  // signed; negative = a dip, which is what a finger makes
};

struct SimParams {
    uint2  size;
    float  c2;
    float  damping;
    float  edgeDamp;
    uint   edgeBand;
    float  nonlinearity;
    uint   splatCount;
    float  shallowSpeed;
    uint   wallCount;      // dynamic walls (heavy floaters) in `walls`
    float  _pad0, _pad1;
};

struct RenderParams {
    uint2  size;
    float2 viewport;
    float  refraction;
    float  causticGain;
    float  specGain;
    float  time;
    float  crestGain;
    float  sparkleGain;
    float  detailGain;
    float  dispersion;
    float4 waterTint;      // rgb cast, a = strength
    float4 style;          // x = 0 photographic, 1 woodblock
    float4 inkColour;      // woodblock line colour
    float4 view;           // x zoom, yz view centre in world pixels
    float4 world;          // xy world size in pixels
    float4 menuRect;       // xy centre, zw radii of the clear water, world uv
    float  menuDim;        // 0...1, the cloud passing over the pond
    float  _menuPad0, _menuPad1, _menuPad2;
};

// One Voronoi seed of the fractured sheet: mirrors `IceSeedGPU` in
// Game/IceTypes.swift byte for byte (32 bytes).
struct IceSeed {
    float2 pos;            // world points
    float  strength;       // how visible this cell's edges are
    float  reach;          // in ring multiples, before the edge tapers out
    float  strike;         // index into the strikes array
    float  broken;         // 1 when the shard has gone
    float2 pad;
};

// One blow on the sheet: mirrors `IceStrikeGPU` (16 bytes).
struct IceStrike {
    float2 centre;         // world points
    float  ring;           // radius of the breakable region, world points
    float  time;           // renderer clock when it landed
};

struct IceBakeParams {
    float2 world;          // world size in points
    uint2  tex;            // crack texture size in texels
    uint   strikeCount;
    float  _pad0, _pad1, _pad2;
};

struct FloorParams {
    float4 viewport;
    float4 deep;
    float4 mid;
    float4 shallow;
    float4 mosaic;         // xy centre (uv), z radius (fraction of height), w silt tint strength
    float4 siltColour;     // rgb of the silt film
    float4 camera;         // xy lateral camera offset in points, z height, w shift gain
    float4 bed;            // x bed strength, y bed depth (positive, below the surface)
    float4 view;           // xy view centre in world pixels (the perspective centre)
    float4 bank;           // x on, y mouth (fraction of height), z stretch (fraction of height)
};

struct SiltParams {
    float4 viewport;       // xy drawable size
    float4 size;           // xy silt texture size
    float4 gains;          // x |h| gain, y |lap| gain, z threshold, w rate*dt
    float4 mosaic;         // xy centre uv, z radius (fraction of height)
    uint   coverCount;
    uint   _pad0, _pad1, _pad2;
};

/// A camera above and behind the pond, looking across it and down. World
/// x is right, world y is away from the viewer (up the screen), z is up,
/// all in points; the surface is z = 0. depthScale turns a layer's depth in
/// pond units (bed = 1) into points.
struct CameraParams {
    float4 position;       // xyz camera position in world points
    float4 right;          // xyz unit vectors of the camera frame
    float4 down;           // screen-down direction
    float4 forward;
    float4 focal;          // x focal length in points, y depthScale, zw screen size in points
    float4 world;          // xy world size in points
};

/// World point to screen point.
static float2 projectToScreen(float3 P, constant CameraParams &c)
{
    float3 d = P - c.position.xyz;
    float depth = max(dot(d, c.forward.xyz), 1.0);
    float2 centre = c.focal.zw * 0.5;
    return centre + float2(dot(d, c.right.xyz), dot(d, c.down.xyz)) * (c.focal.x / depth);
}

/// Where the line of sight through a world point meets the surface plane.
/// Things below the surface are painted into the surface's own texture at
/// this point, so the water refracts and lights them like everything else.
static float2 projectToSurface(float3 P, constant CameraParams &c)
{
    float3 C = c.position.xyz;
    float t = C.z / max(C.z - P.z, 1.0);
    return (C + (P - C) * t).xy;
}

/// The surface point under a screen pixel: a ray traced to z = 0.
static float2 surfaceUnderPixel(float2 screenPt, constant CameraParams &c)
{
    float2 centre = c.focal.zw * 0.5;
    float2 o = (screenPt - centre) / c.focal.x;
    float3 dir = c.forward.xyz + c.right.xyz * o.x + c.down.xyz * o.y;
    float t = -c.position.z / min(dir.z, -0.05);
    return (c.position.xyz + dir * t).xy;
}

/// The same ray traced to a plane `height` points above the surface: the
/// top of the bank, which stands out of the water.
static float2 planeUnderPixel(float2 screenPt, float height, constant CameraParams &c)
{
    float2 centre = c.focal.zw * 0.5;
    float2 o = (screenPt - centre) / c.focal.x;
    float3 dir = c.forward.xyz + c.right.xyz * o.x + c.down.xyz * o.y;
    float t = (height - c.position.z) / min(dir.z, -0.05);
    return (c.position.xyz + dir * t).xy;
}

struct SpriteInstance {
    float2 center;         // points, origin top-left
    float2 size;           // points
    float  rotation;       // radians, clockwise on screen
    float  alpha;
    float  depth;          // submerged: 0 at the surface, 1 deep
    float  wave;           // spine phase
    float  waveAmp;        // lateral wag as a fraction of width
    uint   mode;           // low 2 bits: 0 plain, 1 floater, 2 submerged, 3 shadow; bit 3: flip x
    float2 _pad;
    float4 tint;
};

struct SpriteParams {
    float4 viewport;       // xy drawable size in points
    float4 gains;          // x lift, y tilt, z wet threshold, w bob
    float4 floorTint;      // rgb cast for submerged things at full depth
    float4 light;          // xyz direction toward the light, screen space
    float4 relief;         // x diffuse, y specular, z edge darkening, w ink alpha
    float4 camera;         // xy lateral camera offset in points, z camera height above the surface (surface-to-bed = 1), w shift gain
    float4 haze;           // rgb colour the water swallows deep things into
    float4 screen;         // xy screen size in points, z zoom, w 1 = drawing into the world-sized floor texture
    float4 view;           // xy view centre in world points
};

// ---------------------------------------------------------------------------
// Simulation. See the notes in git history for the physics; in short:
//   v += laplacian(h) * c2 ; v *= damping ; h += v
// with a height-dependent wave speed (crests outrun troughs, so two ripples
// collide instead of ghosting through) and a depth map: zero is a wall that
// reflects, between zero and one the water is shallow and waves slow and bend.
// Heavy floating things are walls too, passed in as circles per step.
// ---------------------------------------------------------------------------

kernel void wave_step(texture2d<float, access::read>  src   [[texture(0)]],
                      texture2d<float, access::write> dst   [[texture(1)]],
                      texture2d<float, access::read>  depth [[texture(2)]],
                      texture2d<float, access::sample> ice  [[texture(3)]],
                      constant SimParams &p                 [[buffer(0)]],
                      constant Splat *splats                [[buffer(1)]],
                      constant float4 *walls                [[buffer(2)]],
                      uint2 gid                             [[thread_position_in_grid]])
{
    if (gid.x >= p.size.x || gid.y >= p.size.y) { return; }
    constexpr sampler iceSmp(filter::linear, address::clamp_to_edge);

    float d = depth.read(gid).r;
    // Under the ice the water is held still; at the sheet's edge a wave
    // meets something nearly solid and turns back.
    float frozen = ice.sample(iceSmp, (float2(gid) + 0.5) / float2(p.size)).r;
    d = mix(d, 0.06, smoothstep(0.35, 0.8, frozen));
    // Heavy floaters are shallows, not walls: a wave slows and partly
    // reflects under a log, but the water there still rises, which is what
    // lifts the log when a big enough swell arrives.
    for (uint i = 0; i < p.wallCount; ++i) {
        float2 delta = float2(gid) - walls[i].xy;
        if (dot(delta, delta) < walls[i].z * walls[i].z) { d = min(d, walls[i].w); }
    }
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
    v *= p.damping * (1.0 - frozen * 0.6);

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
            float falloff = 0.5 + 0.5 * cos(M_PI_F * sqrt(dist2) / rad);
            h += splats[i].amplitude * falloff;
        }
    }

    dst.write(float4(h, v, 0.0, 0.0), gid);
}

// ---------------------------------------------------------------------------
// Probes: (height, dh/dx, dh/dy, vertical velocity) under a few dozen points.
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

    float hL = 0.5 * (field.read(uint2(c.x - 2, c.y)).r + field.read(uint2(c.x - 1, c.y)).r);
    float hR = 0.5 * (field.read(uint2(c.x + 2, c.y)).r + field.read(uint2(c.x + 1, c.y)).r);
    float hD = 0.5 * (field.read(uint2(c.x, c.y - 2)).r + field.read(uint2(c.x, c.y - 1)).r);
    float hU = 0.5 * (field.read(uint2(c.x, c.y + 2)).r + field.read(uint2(c.x, c.y + 1)).r);
    float2 hv = field.read(c).rg;

    results[i] = float4(hv.r, (hR - hL) / 3.0, (hU - hD) / 3.0, hv.g);
}

// ---------------------------------------------------------------------------
// Silt. A film over the pond floor that wave energy scours away, more where
// the water is busiest (two crests meeting), and not at all under anything
// floating over it. This is the reveal: the player's ripples wash the mosaic
// clean, and debris has to be moved before the tile beneath it can appear.
// ---------------------------------------------------------------------------

struct WetParams {
    float4 size;           // xy texels
    float4 rate;           // x keep per frame (drying), y unused
};

/// Where the water has been. Ground under water is wet; ground the water has
/// just drawn back from stays wet and dries slowly, so a wave that runs up
/// the bank leaves its mark behind for a while.
kernel void wet_update(texture2d<float, access::read>   wetIn  [[texture(0)]],
                       texture2d<float, access::write>  wetOut [[texture(1)]],
                       texture2d<float, access::sample> field  [[texture(2)]],
                       texture2d<float, access::sample> depth  [[texture(3)]],
                       constant WetParams &p                   [[buffer(0)]],
                       uint2 gid                               [[thread_position_in_grid]])
{
    if (gid.x >= uint(p.size.x) || gid.y >= uint(p.size.y)) { return; }
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / p.size.xy;
    float h = field.sample(smp, uv).r;
    float d = depth.sample(smp, uv).r;
    float lift = clamp(h * 14.0, -0.05, 0.16);
    float covered = smoothstep(0.07 - lift, 0.11 - lift, d);
    float was = wetIn.read(gid).r;
    wetOut.write(float4(max(was * p.rate.x, covered), 0.0, 0.0, 1.0), gid);
}

kernel void silt_erode(texture2d<float, access::read>   siltIn  [[texture(0)]],
                       texture2d<float, access::write>  siltOut [[texture(1)]],
                       texture2d<float, access::sample> field   [[texture(2)]],
                       constant SiltParams &p                   [[buffer(0)]],
                       constant float4 *covers                  [[buffer(1)]],
                       uint2 gid                                [[thread_position_in_grid]])
{
    if (gid.x >= uint(p.size.x) || gid.y >= uint(p.size.y)) { return; }
    constexpr sampler smp(filter::linear, address::clamp_to_edge);

    float2 uv = (float2(gid) + 0.5) / p.size.xy;
    float2 texel = 1.0 / float2(field.get_width(), field.get_height());
    float hC = field.sample(smp, uv).r;
    float hL = field.sample(smp, uv - float2(texel.x, 0)).r;
    float hR = field.sample(smp, uv + float2(texel.x, 0)).r;
    float hD = field.sample(smp, uv - float2(0, texel.y)).r;
    float hU = field.sample(smp, uv + float2(0, texel.y)).r;
    float lap = hL + hR + hD + hU - 4.0 * hC;

    float activity = abs(hC) * p.gains.x + abs(lap) * p.gains.y;
    float e = max(0.0, activity - p.gains.z);

    float aspect = p.viewport.x / p.viewport.y;
    float2 q = float2(uv.x * aspect, uv.y);
    for (uint i = 0; i < p.coverCount; ++i) {
        float2 c = float2(covers[i].x * aspect, covers[i].y);
        float r = covers[i].z;
        float dist = distance(q, c);
        e *= smoothstep(r * 0.85, r * 1.15, dist);   // shaded underneath, soft edge
    }

    float s = siltIn.read(gid).r - e * p.gains.w;
    siltOut.write(float4(max(s, 0.0), 0.0, 0.0, 0.0), gid);
}

/// One thread per silt row: the silt total inside the mosaic circle.
kernel void silt_rowsum(texture2d<float, access::read> silt [[texture(0)]],
                        device float *rows                    [[buffer(0)]],
                        constant SiltParams &p                [[buffer(1)]],
                        uint y                                [[thread_position_in_grid]])
{
    if (y >= uint(p.size.y)) { return; }
    float aspect = p.viewport.x / p.viewport.y;
    float2 c = float2(p.mosaic.x * aspect, p.mosaic.y);
    float r = p.mosaic.z;
    float sum = 0.0;
    uint w = uint(p.size.x);
    for (uint x = 0; x < w; ++x) {
        float2 uv = (float2(x, y) + 0.5) / p.size.xy;
        float2 q = float2(uv.x * aspect, uv.y);
        if (distance(q, c) < r) { sum += silt.read(uint2(x, y)).r; }
    }
    rows[y] = sum;
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
// Floor base: baked once per resize. Sediment, grain, a pool of light.
// ---------------------------------------------------------------------------

fragment float4 floor_base_fragment(VertexOut in           [[stage_in]],
                                    constant FloorParams &p [[buffer(0)]])
{
    float aspect = p.viewport.x / p.viewport.y;
    float2 q = float2(in.uv.x * aspect, in.uv.y);

    float radial = distance(q, float2(0.5 * aspect, 0.30));
    float lift   = smoothstep(1.15, 0.02, radial);
    float3 col = mix(p.deep.rgb, mix(p.mid.rgb, p.shallow.rgb, lift * lift), lift);

    float big   = fbm(q * 5.5, 4);
    float small = fbm(q * 19.0, 4);
    col *= 0.90 + 0.20 * big;
    col *= 0.94 + 0.12 * small;

    float patch = smoothstep(0.60, 0.82, fbm(q * 7.2 + 11.3, 3));
    col = mix(col, col * 0.70, patch * 0.70);
    col += float3(0.032, 0.023, 0.009) * lift * smoothstep(0.50, 0.88, small);
    col += 0.007 * sin(q.y * 62.0 + big * 7.0);

    return float4(max(col, 0.0), 1.0);
}

// ---------------------------------------------------------------------------
// Floor compose: every frame. Base + mosaic under its silt; submerged sprites
// are drawn on top of this in the same pass. The water then refracts all of it.
// ---------------------------------------------------------------------------

fragment float4 floor_compose_fragment(VertexOut in                             [[stage_in]],
                                       texture2d<float, access::sample> base    [[texture(0)]],
                                       texture2d<float, access::sample> mosaic  [[texture(1)]],
                                       texture2d<float, access::sample> silt    [[texture(2)]],
                                       texture2d<float, access::sample> depth   [[texture(3)]],
                                       texture2d<float, access::sample> bed     [[texture(4)]],
                                       texture2d<float, access::sample> field   [[texture(5)]],
                                       texture2d<float, access::sample> bank0   [[texture(6)]],
                                       texture2d<float, access::sample> bank1   [[texture(7)]],
                                       texture2d<float, access::sample> bank2   [[texture(8)]],
                                       texture2d<float, access::sample> bank3   [[texture(9)]],
                                       constant FloorParams &p                  [[buffer(0)]],
                                       constant CameraParams &cam               [[buffer(1)]])
{
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    // This texel is a point on the surface. The line of sight through it
    // carries on down to the bed, which lies at the bowl's depth here; that
    // is the bed point we show, so the bed sits in true perspective below.
    float dHere = depth.sample(smp, in.uv).r;
    float bedZ = -dHere * cam.focal.y;
    float3 C = cam.position.xyz;
    float3 S = float3(in.uv * cam.world.xy, 0.0);
    float t = (C.z - bedZ) / max(C.z, 1.0);
    float2 bedPoint = (C + (S - C) * t).xy;
    float2 buv = 0.5 + (bedPoint / cam.world.xy - 0.5) * 0.80;
    float3 col = base.sample(smp, in.uv).rgb;
    float3 painted = bed.sample(smp, buv).rgb;
    // Quieten the painting: less contrast, tinted toward the season, so it
    // reads as a bed a metre down and not a print laid on the surface.
    float lum = dot(painted, float3(0.3, 0.59, 0.11));
    painted = mix(float3(lum), painted, 0.7);
    painted = mix(painted, painted * (p.mid.rgb * 2.4 + 0.1), 0.6) * 0.74;
    col = mix(col, painted, p.bed.x);

    // Depth: the pond is a bowl. The middle is deep, and the water column
    // above it swallows the bed into a dark blue haze; toward the banks the
    // bed shelves up into sand and pebbles that catch the light.
    float d = depth.sample(smp, in.uv).r;
    float aspect = p.viewport.x / p.viewport.y;
    float2 q = float2(in.uv.x * aspect, in.uv.y);
    float deepness = smoothstep(0.35, 1.0, d);
    // The column of water above the deep middle swallows the bed: darker,
    // bluer, softer. The shelves near the bank stay bright and sharp.
    float3 abyss = p.deep.rgb * 0.75;
    col = mix(col, abyss, deepness * 0.7);

    // Sunlight through the real surface. Light coming straight down is bent
    // by the surface's slope and lands on the bed a little displaced, more
    // so the deeper the bed; where neighbouring rays are bent together the
    // bed brightens, where they are spread it dims. The convergence is the
    // curvature of the surface (its laplacian) at the point the light came
    // through, scaled by the depth it travelled. Calm water gives nothing,
    // a passing ring gives a bright travelling line, two rings crossing
    // give a knot of light: exactly what a pond does.
    float tm = p.bed.z;
    {
        float2 fieldTexel = 1.0 / float2(field.get_width(), field.get_height());
        float2 above = in.uv;
        float depthHere = 0.35 + 0.65 * d;
        float2 tx = float2(fieldTexel.x * 2.0, 0.0), ty = float2(0.0, fieldTexel.y * 2.0);
        float hL = field.sample(smp, above - tx).r, hR = field.sample(smp, above + tx).r;
        float hD = field.sample(smp, above - ty).r, hU = field.sample(smp, above + ty).r;
        float hC = field.sample(smp, above).r;
        float2 slope = float2(hR - hL, hU - hD) * 0.5;
        // The light through this surface point lands displaced downhill.
        float2 landing = above - slope * depthHere * 1.6;
        // Convergence at the landing point, from the curvature there.
        float lL = field.sample(smp, landing - tx).r, lR = field.sample(smp, landing + tx).r;
        float lD = field.sample(smp, landing - ty).r, lU = field.sample(smp, landing + ty).r;
        float lC = field.sample(smp, landing).r;
        float lap = (lL + lR + lD + lU - 4.0 * lC);
        float focus = 1.0 / max(1.0 + lap * 55.0 * depthHere, 0.25);
        float caustic = clamp(focus - 1.0, -0.6, 2.5);
        float3 sun = p.shallow.rgb * 0.5 + 0.5;
        col += sun * max(caustic, 0.0) * 0.55 * mix(1.0, 0.5, deepness);
        col *= 1.0 + min(caustic, 0.0) * 0.45;
        (void)hC;
    }

    float shaftCoord = q.x * 2.2 + q.y * 0.8 + tm * 0.03;
    float shafts = pow(0.5 + 0.5 * sin(shaftCoord * 6.28318), 4.0) * (0.4 + 0.6 * fbm(float2(shaftCoord * 1.7, tm * 0.02), 2));
    col += (p.shallow.rgb * 0.6 + 0.25) * shafts * deepness * 0.45;
    if (d < 0.98) {
        float grain = 0.85 + 0.30 * fbm(q * 30.0, 3);
        float3 sand = mix(p.shallow.rgb, float3(0.70, 0.62, 0.42), 0.6) * grain;
        float shallowness = smoothstep(0.75, 0.15, d);
        col = mix(col, sand, shallowness * 0.55);
        col *= 1.0 - smoothstep(0.15, 0.0, d) * 0.55;
    }

    float2 mcentre = float2(p.mosaic.x * aspect, p.mosaic.y);
    float2 rel = (q - mcentre) / p.mosaic.z;
    float r = length(rel);
    if (r < 1.02) {
        float2 muv = rel * 0.5 + 0.5;
        float4 m = mosaic.sample(smp, muv);
        float s = silt.sample(smp, in.uv).r;
        // Silt is a sandy film with its own grain; as it thins the stone shows.
        // The film is patchy and thins toward its own edge, so it reads as
        // sediment that has settled rather than a disc laid on the floor.
        float grain = 0.80 + 0.40 * fbm(q * 40.0, 3);
        float patch = 0.7 + 0.6 * fbm(q * 9.0 + 3.7, 3);
        float rim = smoothstep(1.02, 0.80, r);
        float3 siltCol = mix(col, p.siltColour.rgb * grain, 0.8);
        float3 tile = m.rgb * 0.82 + col * 0.18;
        float film = smoothstep(0.03, 0.70, s * patch) * p.mosaic.w * rim;
        float3 under = mix(tile, siltCol, film);
        col = mix(col, under, m.a);
    }
    // The bank. Where the bed rises out of the water (p.view.z on, depth
    // near nothing) the floor is earth: moss, grass and pebbles from a
    // seamless tile, under snow above the snow line; a dark damp margin
    // where the water laps it.
    if (p.bank.x > 0.5) {
        constexpr sampler rep(filter::linear, address::repeat);
        float bankness = 1.0 - smoothstep(0.05, 0.15, d);
        if (bankness > 0.001) {
            // Which stretch this is, counted up from the mouth, and where in
            // it: each stretch wears one painting of its season's ground,
            // never repeated, the seams feathered by the paintings themselves.
            float up = (p.bank.y - in.uv.y) / max(p.bank.z, 0.001);
            int si = clamp(int(floor(up)), 0, 3);
            float v = 1.0 - fract(clamp(up, 0.0, 3.999));
            float2 tuv = float2(in.uv.x, v);
            float3 ground = si == 0 ? bank0.sample(rep, tuv).rgb
                          : si == 1 ? bank1.sample(rep, tuv).rgb
                          : si == 2 ? bank2.sample(rep, tuv).rgb
                                    : bank3.sample(rep, tuv).rgb;
            // Damp and dark right at the water, drying out up the bank.
            float damp = 1.0 - smoothstep(0.0, 0.12, d);
            ground *= mix(1.0, 0.62, damp * 0.9);
            col = mix(col, ground, bankness);
        }
    }
    return float4(col, 1.0);
}

// ---------------------------------------------------------------------------
// Sprites. One mesh (a strip of 12 quads) for everything; the strip lets a koi
// wag along its spine. Modes: plain, floater (tilts on the surface and goes
// wet where the water rises over it), submerged (into the floor, tinted by
// depth) and shadow (the sprite's silhouette, dark, through the water).
// ---------------------------------------------------------------------------

struct SpriteVertexIn {
    float2 uv [[attribute(0)]];
};

/// A camera looking straight down from height H above the surface. The
/// surface itself is the reference plane and stays put on screen; a point at
/// depth z (negative below the surface, positive above) shrinks toward the
/// centre when deep and grows when high, and slides with the camera's
/// lateral offset in proportion to how far it is from the surface.
static float2 project(float2 pointOnSurfacePlane, float z, float4 camera, float2 centre)
{
    float H = camera.z;
    float s = H / max(H - z, 0.1);
    return centre + (pointOnSurfacePlane - centre) * s + camera.xy * (1.0 - s) * camera.w;
}

struct SpriteOut {
    float4 position [[position]];
    float2 uv;
    float4 tint;
    float  alpha;
    float  wet;
    float  depth;
    uint   mode;
    uint   flags;
    float2 rot;            // cos, sin of the sprite rotation, for the normal
    float  roll;           // signed, brightens the flank turned to the light
    float2 worldUV;        // where this vertex sits on the pond, for masks
};

vertex SpriteOut sprite_vertex(SpriteVertexIn vin                         [[stage_in]],
                               constant SpriteInstance *instances         [[buffer(1)]],
                               constant SpriteParams &p                   [[buffer(2)]],
                               constant float4 *spines                    [[buffer(3)]],
                               constant CameraParams &cam                 [[buffer(4)]],
                               texture2d<float, access::sample> field     [[texture(0)]],
                               uint iid                                   [[instance_id]])
{
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    SpriteInstance s = instances[iid];
    uint mode = s.mode & 3u;
    bool flip = (s.mode & 8u) != 0;
    bool weed = (s.mode & 32u) != 0;
    bool stands = (s.mode & 64u) != 0;

    float2 uv = vin.uv;
    float2 local = (uv - 0.5) * s.size;          // v grows downward in the image
    if (flip) { local.x = -local.x; }
    float tailness = 1.0 - uv.y;                 // 0 at the image bottom (root / head), 1 at the top (tip / tail)
    int spine = int(s._pad.x) - 1;

    // Height of this vertex above the surface, in points. Most sprites lie
    // flat at their layer's depth; a weed stands up from the bed.
    float depthScale = cam.focal.y;
    float z = s._pad.y * depthScale;
    // A fish banks into its turn: it narrows, and one flank catches the light.
    float roll = s.tint.w;
    if (spine >= 0) { local.x *= 1.0 - 0.35 * abs(roll); }

    float wet = 0.0;
    float rotation = s.rotation;
    float2 onSurface;                            // position on the surface plane (x, y in world points)

    if (spine >= 0) {
        // A fish: rows sit along the recorded path of the head. Thirteen
        // samples, interpolated so a finer mesh bends without facets.
        float f = uv.y * 12.0;
        int i0 = int(floor(f));
        int i1 = min(i0 + 1, 12);
        float t = f - float(i0);
        float4 a = spines[spine * 13 + i0];
        float4 b = spines[spine * 13 + i1];
        float2 pos = mix(a.xy, b.xy, t);
        float2 tan = normalize(mix(a.zw, b.zw, t));
        float2 n = float2(-tan.y, tan.x);
        // The wag rides on the spine, largest at the tail.
        float wag = sin(s.wave + uv.y * 4.2) * s.waveAmp * s.size.x * tailness * tailness;
        onSurface = pos + n * (local.x + wag) + s.center;
        float4 head = spines[spine * 13 + 12];
        rotation = atan2(head.w, head.z) - M_PI_F * 0.5;
    } else if (weed) {
        // A strand stands up from the bed. Its root is at the bed's depth
        // (in s.depth, pond units), its tip rises toward the surface. The
        // lean (in waveAmp) and the idle sway (in wave) tip it over along its
        // lean direction, growing with the square of the distance up the stem.
        float bend = 0.18 + s.waveAmp + sin(s.wave + tailness * 2.4) * 0.09;
        float2 leanDir = float2(cos(s.rotation), sin(s.rotation));
        float2 lateral = float2(-leanDir.y, leanDir.x);
        float height = s.size.y;
        float rootZ = -s.depth * depthScale;
        float rise = tailness * height;
        float tip = bend * tailness * tailness;
        onSurface = s.center + leanDir * (tip * height * 0.8) + lateral * local.x;
        z = min(rootZ + rise * (1.0 - abs(tip) * 0.5), -12.0);
    } else if (stands) {
        // A tuft standing on the bank: its root sits on the surface plane and
        // it rises straight up, swaying a little at the tips.
        float sway = sin(s.wave + tailness * 1.5) * 0.05 * tailness * tailness;
        float2 leanDir = float2(cos(s.rotation), sin(s.rotation));
        float2 lateral = float2(-leanDir.y, leanDir.x);
        onSurface = s.center + lateral * local.x + leanDir * (sway * s.size.y);
        z = s._pad.y * depthScale + tailness * s.size.y;
    } else {
        float cs = cos(s.rotation), sn = sin(s.rotation);
        float2 rotated = float2(local.x * cs - local.y * sn, local.x * sn + local.y * cs);
        if (mode == 1u) {
            float2 cuv = s.center / p.viewport.xy;
            float2 texel = 1.0 / float2(field.get_width(), field.get_height());
            float hc = field.sample(smp, cuv).r;
            float gx = field.sample(smp, cuv + float2(texel.x * 2.0, 0)).r - field.sample(smp, cuv - float2(texel.x * 2.0, 0)).r;
            float gy = field.sample(smp, cuv + float2(0, texel.y * 2.0)).r - field.sample(smp, cuv - float2(0, texel.y * 2.0)).r;
            float bob = 1.0 + clamp(hc * p.gains.w, -0.25, 0.25);
            onSurface = s.center + rotated * bob;
            float hv = field.sample(smp, onSurface / p.viewport.xy).r;
            onSurface.y -= (hv - hc) * p.gains.x;
            onSurface -= float2(gx, gy) * p.gains.y;
            wet = smoothstep(0.0, p.gains.z, hv - hc);
        } else {
            onSurface = s.center + rotated;
        }
    }

    float3 P = float3(onSurface, z);
    float2 clip;
    if (p.screen.w > 0.5) {
        clip = projectToSurface(P, cam) / cam.world.xy;     // into the surface's own texture
    } else {
        clip = projectToScreen(P, cam) / cam.focal.zw;
    }

    SpriteOut out;
    out.position = float4(clip.x * 2.0 - 1.0, 1.0 - clip.y * 2.0, 0.0, 1.0);
    out.roll = roll * (uv.x - 0.5) * 2.0;
    out.worldUV = onSurface / cam.world.xy;
    out.uv = uv;
    out.tint = s.tint;
    out.alpha = s.alpha;
    out.wet = wet;
    // A weed's root is hazed like the bed; its tip is nearly clear.
    out.depth = weed ? mix(0.85, 0.15, tailness) : s.depth;
    out.mode = mode;
    out.flags = s.mode;
    out.rot = float2(cos(rotation), sin(rotation)) * float2(flip ? -1.0 : 1.0, 1.0);
    return out;
}

fragment float4 sprite_fragment(SpriteOut in                             [[stage_in]],
                                texture2d<float, access::sample> tex     [[texture(0)]],
                                texture2d<float, access::sample> relief  [[texture(1)]],
                                texture2d<float, access::sample> iceMask [[texture(2)]],
                                constant SpriteParams &p                 [[buffer(0)]])
{
    constexpr sampler smp(filter::linear, address::clamp_to_edge, mip_filter::linear);
    float4 c = tex.sample(smp, in.uv);
    // Textures load premultiplied.
    float a = c.a * in.alpha;
    float3 rgb = c.rgb * in.tint.rgb * in.alpha;
    if ((in.flags & 128u) != 0u) {
        // A fracture exists only in ice: fade it out where the water is open.
        float onIce = smoothstep(0.35, 0.7, iceMask.sample(smp, in.worldUV).r);
        a *= onIce;
        rgb *= onIce;
    }

    if (in.mode == 3u) {
        return float4(0.0, 0.0, 0.0, a * 0.42);
    }
    if ((in.flags & 16u) != 0u) {
        // Paper thickness: the same silhouette, ink dark, drawn just under.
        return float4(0.0, 0.0, 0.0, a * p.relief.w);
    }

    // Relief: a normal map cut from the silhouette gives every piece a
    // rounded edge and a little body, lit by the same light as the water.
    float4 nm = relief.sample(smp, in.uv);
    float3 n = normalize(nm.xyz * 2.0 - 1.0);
    float2 rn = float2(n.x * in.rot.x - n.y * in.rot.y, n.x * in.rot.y + n.y * in.rot.x);
    n = normalize(float3(rn, n.z));
    float3 L = normalize(p.light.xyz);
    float3 H = normalize(L + float3(0.0, 0.0, 1.0));
    float diff = max(0.0, dot(n, L));
    float spec = pow(max(0.0, dot(n, H)), 28.0);
    float body = smoothstep(0.10, 0.70, nm.a);
    float shade = (1.0 - p.relief.x * 0.55) + p.relief.x * diff;
    shade *= mix(1.0 - p.relief.z, 1.0, body);
    shade *= 1.0 + in.roll * 0.35;
    rgb = rgb * shade + float3(1.0, 0.98, 0.92) * spec * p.relief.y * a;
    if (in.mode == 2u) {
        // The water swallows deep things into its own colour: they go hazy
        // and cool long before they go faint, and only vanish right at the
        // bottom of the dive.
        float d = in.depth;
        float3 hazed = mix(rgb, p.haze.rgb * a, smoothstep(0.0, 1.0, d) * 0.85);
        float keep = 1.0 - smoothstep(0.78, 1.0, d);
        return float4(hazed * keep, a * keep);
    }
    if (in.mode == 1u) {
        // Where the water rides over it, the piece goes darker and cooler.
        float3 wetted = rgb * float3(0.55, 0.72, 0.80);
        rgb = mix(rgb, wetted, in.wet * 0.85);
    }
    return float4(rgb, a);
}

// ---------------------------------------------------------------------------
// Water. Photographic by default. In woodblock style the same surface is
// drawn as a print: flat colour, shading cut into bands, an ink line along
// every crest, foam flecks, paper grain.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// The fractured sheet, baked once per break into a distance field.
//
// The sheet is a Voronoi diagram of the strike seeds: every cell is a shard,
// every cell edge is a crack. For a point p the nearest seed a is found first,
// then the distance to the nearest crack is the smallest distance to any
// bisector between a and another seed b -- exactly the Voronoi edge -- so the
// line the shader draws IS the shard outline, sub-pixel crisp at any zoom.
// Only VISIBLE edges count: an edge shows with strength max(sa, sb) (so an
// edge between two rim seeds, both strength 0, is the open sheet and invisible)
// and only inside ring x reach of the strike that owns the longer-reaching
// seed, so runner cracks carry on past the hole and the rest stop short.
//
//   r = distance to that crack / 12pt, clamped
//   g = its strength, tapered out over the last 15% of its reach
//   b = radial fraction of 2.8 rings from the strike centre (the outward race)
//   a = strike index / 255, so the fragment can read the strike's time
//
// Texels with no strike within ring x 3 write (1, 0, 0, 0) and cost nothing.
// ---------------------------------------------------------------------------

kernel void ice_bake(texture2d<float, access::write> outTex  [[texture(0)]],
                     constant IceSeed   *seeds               [[buffer(0)]],
                     constant IceStrike *strikes             [[buffer(1)]],
                     constant uint2     *ranges              [[buffer(2)]],
                     constant IceBakeParams &p               [[buffer(3)]],
                     uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.tex.x || gid.y >= p.tex.y) return;
    const float4 clear = float4(1.0, 0.0, 0.0, 0.0);
    if (p.strikeCount == 0) { outTex.write(clear, gid); return; }

    float2 pt = (float2(gid) + 0.5) / float2(p.tex) * p.world;

    // Pass one: the nearest seed, over the strikes whose reach covers p.
    int   best  = -1;
    float bestD = 1e30;
    for (uint s = 0; s < p.strikeCount; ++s) {
        IceStrike st = strikes[s];
        float far = st.ring * 3.0;
        if (distance_squared(pt, st.centre) > far * far) continue;
        uint2 r = ranges[s];
        uint end = r.x + r.y;
        for (uint i = r.x; i < end; ++i) {
            float d = distance_squared(pt, seeds[i].pos);
            if (d < bestD) { bestD = d; best = int(i); }
        }
    }
    if (best < 0) { outTex.write(clear, gid); return; }

    IceSeed   a  = seeds[best];
    IceStrike sa = strikes[uint(a.strike)];

    // Pass two: the nearest visible bisector between a and any other seed.
    // The bisector of a and b is never nearer than (|pb| - |pa|) / 2, so a
    // seed farther than |pa| + 2 x the best distance so far cannot win: that
    // prunes almost the whole list once the first edge is found.
    float minD  = 1e30;
    float minG  = 0.0;
    float pa    = sqrt(bestD);
    for (uint s = 0; s < p.strikeCount; ++s) {
        IceStrike st = strikes[s];
        float far = st.ring * 3.0;
        if (distance_squared(pt, st.centre) > far * far) continue;
        uint2 r = ranges[s];
        uint end = r.x + r.y;
        for (uint i = r.x; i < end; ++i) {
            if (int(i) == best) continue;
            IceSeed b = seeds[i];
            float strength = max(a.strength, b.strength);
            if (strength <= 0.001) continue;         // sheet against sheet: no crack
            float cut = pa + 2.0 * min(minD, 1.0e6);
            if (distance_squared(pt, b.pos) > cut * cut) continue;
            float2 ab = b.pos - a.pos;
            float len = length(ab);
            if (len < 1e-4) continue;
            float d = dot(0.5 * (a.pos + b.pos) - pt, ab / len);
            if (d >= minD) continue;
            // Visible only within ring x reach of the strike behind the
            // longer-reaching of the two seeds.
            IceStrike host = (b.reach > a.reach) ? strikes[uint(b.strike)] : sa;
            float lim = host.ring * max(a.reach, b.reach);
            float rad = distance(pt, host.centre);
            if (rad >= lim) continue;
            minD = max(d, 0.0);
            minG = strength * (1.0 - smoothstep(0.85, 1.0, rad / max(lim, 1e-3)));
        }
    }
    if (minD > 1e29) { outTex.write(clear, gid); return; }

    float radial = saturate(distance(pt, sa.centre) / max(sa.ring * 2.8, 1e-3));
    outTex.write(float4(saturate(minD / 12.0), saturate(minG), radial, a.strike / 255.0), gid);
}

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

/// A menu is open in the pond: the water darkens like a cloud passing,
/// except inside the soft ellipse around the menu itself.
static inline float3 menuShade(float3 col, float2 wuv, constant RenderParams &p)
{
    if (p.menuDim < 0.001) { return col; }
    float2 d = (wuv - p.menuRect.xy) / max(p.menuRect.zw, float2(0.001));
    float e = length(d);
    float inside = 1.0 - smoothstep(0.75, 1.25, e);
    float amount = mix(0.82, 0.5, inside) * p.menuDim;
    return col * (1.0 - amount);
}

fragment float4 water_fragment(VertexOut in                              [[stage_in]],
                               texture2d<float, access::sample> field     [[texture(0)]],
                               texture2d<float, access::sample> floorTex  [[texture(1)]],
                               texture2d<float, access::sample> depthTex  [[texture(2)]],
                               texture2d<float, access::sample> iceTex    [[texture(3)]],
                               texture2d<float, access::sample> iceLook   [[texture(4)]],
                               texture2d<float, access::sample> crackTex  [[texture(5)]],
                               texture2d<float, access::sample> wetTex    [[texture(6)]],
                               constant RenderParams &p                   [[buffer(0)]],
                               constant CameraParams &cam                 [[buffer(1)]],
                               constant IceStrike *iceStrikes             [[buffer(2)]])
{
    constexpr sampler smp(filter::linear, address::clamp_to_edge);

    // Trace this pixel's line of sight to the surface: that is the point of
    // water we are looking at.
    float2 screenPt = in.uv * cam.focal.zw;
    float2 worldPt = surfaceUnderPixel(screenPt, cam);
    float2 wuv = worldPt / cam.world.xy;
    if (any(wuv < 0.0) || any(wuv > 1.0)) {
        // Beyond the water the shelf keeps rising as the bank: the same
        // pebbles and sand, dry, mirrored back so the texture continues.
        float2 m = abs(wuv);
        m = 1.0 - abs(1.0 - m);
        float2 bankUV = clamp(m, 0.0, 1.0);
        float3 dry = floorTex.sample(smp, bankUV).rgb;
        float lum = dot(dry, float3(0.3, 0.59, 0.11));
        dry = mix(float3(lum), dry, 0.6) * float3(1.05, 1.0, 0.9) * 0.9;
        float paper = fbm(in.uv * p.viewport / 6.0, 2);
        dry *= 0.92 + 0.14 * paper;
        return float4(menuShade(dry, wuv, p), 1.0);
    }

    float2 texel = 1.0 / float2(p.size);

    float hL = field.sample(smp, wuv - float2(texel.x, 0)).r;
    float hR = field.sample(smp, wuv + float2(texel.x, 0)).r;
    float hD = field.sample(smp, wuv - float2(0, texel.y)).r;
    float hU = field.sample(smp, wuv + float2(0, texel.y)).r;
    float hC = field.sample(smp, wuv).r;

    float2 grad = float2(hR - hL, hU - hD) * 0.5;
    float  lap  = (hL + hR + hD + hU - 4.0 * hC);

    bool woodblock = p.style.x > 0.5;

    float activity = saturate(abs(hC) * 5.0 + abs(lap) * 26.0);
    float2 dp = float2(0.004, 0.0);
    float2 sc = wuv * 34.0 + float2(p.time * 0.55, -p.time * 0.42);
    float  n0 = valueNoise(sc);
    float2 fineGrad = float2(valueNoise(sc + dp.xy) - n0,
                             valueNoise(sc + dp.yx) - n0);
    float detail = woodblock ? p.detailGain * 0.25 : p.detailGain;
    float3 N = normalize(float3(-(grad * 46.0 + fineGrad * detail * activity), 1.0));

    float2 offset = grad * p.refraction * (woodblock ? 0.6 : 1.0);
    float  spread = woodblock ? 0.0 : p.dispersion;
    // Focus sits on the surface. The deeper the bed below this point, the
    // softer it is drawn: a small cross blur that grows with the depth.
    float dHere = depthTex.sample(smp, wuv).r;
    // Bank: above the waterline there is no water to draw, just the ground.
    // The waterline is not fixed. The surface here rides up and down with the
    // wave, so a crest arriving at the shore runs up the bank and covers
    // ground that was dry, and the trough behind it draws the water back.
    float lift = clamp(hC * 14.0, -0.05, 0.16);
    float dry = 1.0 - smoothstep(0.05 - lift, 0.11 - lift, dHere);
    // The bank stands a hand above the water. Its top is seen where the
    // ray meets the raised plane over ground; where only the water-level
    // point is ground, the ray has hit the bank's face at the waterline.
    float bankH = 0.07 * cam.focal.y;
    float2 groundPt = planeUnderPixel(screenPt, bankH, cam);
    float2 guv = groundPt / cam.world.xy;
    float dGround = (any(guv < 0.0) || any(guv > 1.0)) ? 0.05 : depthTex.sample(smp, guv).r;
    float bankTop = 1.0 - smoothstep(0.05 - lift, 0.11 - lift, dGround);
    // Only the deep bed goes soft; anything over the shelves, and the fish,
    // stay crisp.
    float blur = smoothstep(0.7, 1.0, dHere) * 1.1 / float(p.size.y);
    float2 c0 = wuv + offset;
    float3 col = floorTex.sample(smp, c0).rgb * 0.4;
    col += floorTex.sample(smp, c0 + float2(blur, 0)).rgb * 0.15;
    col += floorTex.sample(smp, c0 - float2(blur, 0)).rgb * 0.15;
    col += floorTex.sample(smp, c0 + float2(0, blur)).rgb * 0.15;
    col += floorTex.sample(smp, c0 - float2(0, blur)).rgb * 0.15;
    if (!woodblock) {
        col.r = mix(col.r, floorTex.sample(smp, wuv + offset * (1.0 + spread)).r, 0.6);
        col.b = mix(col.b, floorTex.sample(smp, wuv + offset * (1.0 - spread)).b, 0.6);
    }

    col = mix(col, col * p.waterTint.rgb, p.waterTint.a);

    float depth = saturate(-hC * 1.6 + length(offset) * 5.0);
    col *= mix(1.0, 0.80, depth);
    col = mix(col, col * float3(0.72, 0.96, 1.06), depth * 0.65);

    float caustic = clamp(-lap * p.causticGain, -0.6, 2.2);
    float crest = smoothstep(0.055, 0.20, hC);

    float3 L = normalize(float3(-0.40, 0.56, 0.72));
    float3 V = float3(0.0, 0.0, 1.0);
    float3 H = normalize(L + V);
    float tight = pow(max(dot(N, H), 0.0), 220.0);
    float broad = pow(max(dot(N, H), 0.0), 26.0);
    float f = 0.02 + 0.98 * pow(1.0 - saturate(N.z), 5.0);
    float3 R = reflect(-V, N);

    if (!woodblock) {
        col += float3(0.40, 0.74, 0.80) * max(caustic, 0.0) * 0.50;
        col *= 1.0 + min(caustic, 0.0) * 0.34;
        col += float3(0.62, 0.86, 0.92) * crest * p.crestGain;
        col += float3(0.85, 0.94, 1.00) * (tight * 1.5 + broad * 0.16) * p.specGain;
        col = mix(col, skyLook(R, L), saturate(f * 1.5));

        float cell  = hash21(floor(in.uv * p.viewport / 3.0) + floor(p.time * 18.0));
        float glint = step(0.9955, cell) * smoothstep(0.35, 1.3, caustic + crest);
        col += float3(1.0, 0.99, 0.95) * glint * p.sparkleGain;

        float2 vc = in.uv - 0.5;
        col *= 1.0 - dot(vc, vc) * 0.40;
        col += (hash21(in.uv * p.viewport + p.time) - 0.5) * (1.5 / 255.0);
        return float4(menuShade(col, wuv, p), 1.0);
    }

    // --- woodblock ------------------------------------------------------------
    // Shading in three flat steps rather than a gradient.
    float shade = saturate(broad * 0.9 + f * 1.2 + max(caustic, 0.0) * 0.12);
    float band = floor(shade * 3.0 + 0.5) / 3.0;
    float3 lightCol = float3(0.78, 0.86, 0.84);
    col = mix(col, lightCol, band * 0.45);
    col *= 1.0 + min(caustic, 0.0) * 0.18;

    // Ink along the crests: where the surface is steep and rising.
    float slope = length(grad) * 38.0;
    float ink = smoothstep(0.35, 0.75, slope) * smoothstep(-0.02, 0.06, hC);
    col = mix(col, p.inkColour.rgb, ink * 0.88);

    // Foam flecks on the tallest crests, printed cream.
    float fleck = step(0.62, hash21(floor(in.uv * p.viewport / 4.0))) * smoothstep(0.5, 1.0, crest);
    col = mix(col, float3(0.96, 0.94, 0.86), fleck * 0.9);

    // Paper grain over everything.
    float paper = fbm(in.uv * p.viewport / 6.0, 2);
    col *= 0.92 + 0.14 * paper;

    if (dry > 0.001 || bankTop > 0.001) {
        // The face: damp dark earth between the water and the bank's top.
        float wetHere = wetTex.sample(smp, wuv).r;
        float3 face = floorTex.sample(smp, wuv).rgb * float3(0.42, 0.40, 0.38) * (1.0 - 0.3 * wetHere);
        col = mix(col, face, dry);
        // The top, lit in relief from its own texture: a little bump from
        // the luminance so grass and pebbles catch the light.
        float2 tx = 1.0 / float2(floorTex.get_width(), floorTex.get_height()) * 1.5;
        float3 g0 = floorTex.sample(smp, clamp(guv, 0.0, 1.0)).rgb;
        float lL = dot(floorTex.sample(smp, clamp(guv - float2(tx.x, 0), 0.0, 1.0)).rgb, float3(0.3, 0.59, 0.11));
        float lR = dot(floorTex.sample(smp, clamp(guv + float2(tx.x, 0), 0.0, 1.0)).rgb, float3(0.3, 0.59, 0.11));
        float lD = dot(floorTex.sample(smp, clamp(guv - float2(0, tx.y), 0.0, 1.0)).rgb, float3(0.3, 0.59, 0.11));
        float lU = dot(floorTex.sample(smp, clamp(guv + float2(0, tx.y), 0.0, 1.0)).rgb, float3(0.3, 0.59, 0.11));
        float3 bn = normalize(float3(-(lR - lL) * 6.0, -(lU - lD) * 6.0, 1.0));
        float lit = 0.72 + 0.45 * max(0.0, dot(bn, L));
        // Bank's own shadow line where the top drops to the water. It moves
        // with the waterline, so the lip follows the wave up and back.
        float lip = smoothstep(0.03 - lift, 0.06 - lift, dGround) * (1.0 - smoothstep(0.06 - lift, 0.11 - lift, dGround));
        // The strip the water has just left is still wet: dark at the line,
        // drying out the further up the bank it is.
        float damp = 0.25 * smoothstep(0.16, 0.08, dGround + lift);
        // Ground the water has reached is darker, and dries over half a minute.
        float wetTop = wetTex.sample(smp, clamp(guv, 0.0, 1.0)).r;
        float3 top = g0 * lit * (1.0 - 0.35 * lip) * (1.0 - damp) * (1.0 - 0.5 * wetTop);
        col = mix(col, top, bankTop);
        // A thread of foam where a wave meets the shore, broken up by the
        // water's own fine grain so it never reads as a drawn line.
        float atLine = 1.0 - smoothstep(0.0, 0.035, abs(dHere - (0.11 - lift)));
        float active = smoothstep(0.008, 0.04, abs(hC));
        float grain = fbm(wuv * float2(cam.world.x / cam.world.y, 1.0) * 90.0 + p.time * 0.3, 2);
        float foam = atLine * active * smoothstep(0.35, 0.7, grain);
        col = mix(col, float3(0.93, 0.95, 0.94), foam * 0.9);
    }

    // The frozen sheet. Where the mask says ice, the water is under a slab:
    // frosted white, the dark water only ghosting through, feathered frost
    // and a few trapped bubbles; at a hole's edge the sheet thins to a pale
    // rim with the black water showing beneath it.
    float2 iceSample = iceTex.sample(smp, wuv).rg;
    float frozen = iceSample.r;
    // The crack field and its screen footprint, read before the ice branch:
    // `fwidth` wants the whole quad on the same path, and `p.world.z` is a
    // constant for the draw, so this branch never splits one.
    float4 crackF = float4(1.0, 0.0, 0.0, 0.0);
    float crackDist = 12.0;                            // world points
    float crackAA = 0.35;
    float2 crackUV = wuv;
    if (p.world.z > 0.5) {
        // Real cracks are nearly straight, never ruled: the field is read
        // through a small slow warp, about a point either way.
        float2 q0 = wuv * float2(cam.world.x / cam.world.y, 1.0);
        float2 warp = float2(fbm(q0 * 55.0 + 2.0, 2), fbm(q0 * 55.0 + 9.0, 2)) - 0.5;
        crackUV = wuv + warp * (2.2 / cam.world.xy);
        crackF = crackTex.sample(smp, crackUV);
        crackDist = crackF.r * 12.0;
        crackAA = max(fwidth(crackDist), 0.35);
    }
    if (frozen > 0.02) {
        // The sheet proper reads 1; a shard that has given way starts just
        // under a half and slides to nothing as it goes under.
        float solid = smoothstep(0.55, 0.65, frozen);
        float sinkT = 1.0 - saturate((frozen - 0.02) / 0.47);
        float2 iceTexel = 1.0 / float2(iceTex.get_width(), iceTex.get_height());
        float fL = iceTex.sample(smp, wuv - float2(iceTexel.x, 0)).r, fR = iceTex.sample(smp, wuv + float2(iceTexel.x, 0)).r;
        float fD = iceTex.sample(smp, wuv - float2(0, iceTexel.y)).r, fU = iceTex.sample(smp, wuv + float2(0, iceTexel.y)).r;
        float edge = length(float2(fR - fL, fU - fD)) * 1.4;
        float2 q = wuv * float2(cam.world.x / cam.world.y, 1.0);

        // Black ice: the dark water shows through a glassy sheet. Frost lies
        // on it in patches, fine crystals from a tiled painting, sitting where
        // a slow large-scale field says frost formed; snow dust on top.
        constexpr sampler mir(filter::linear, address::mirrored_repeat);
        float aspectW = cam.world.x / cam.world.y;
        float2 tileUV = float2(wuv.x * aspectW, wuv.y) * 5.5;
        float3 crystals = iceLook.sample(mir, tileUV).rgb;
        float crystalBright = dot(crystals, float3(0.3, 0.59, 0.11));
        float patch = smoothstep(0.42, 0.68, fbm(q * 3.2 + 7.0, 4));
        float wisp = smoothstep(0.55, 0.85, fbm(q * 11.0 + 3.0, 3));
        // A finger dragged over the sheet wipes the frost and the snow dust
        // off it and leaves a glassier streak behind.
        float scuff = iceSample.g;
        float frostHere = max(patch, wisp * 0.6) * (1.0 - 0.85 * scuff);
        float3 clearIce = col * 0.62 + float3(0.05, 0.08, 0.11);
        float3 frosted = mix(clearIce, crystals * float3(0.96, 0.98, 1.0), smoothstep(0.2, 0.7, crystalBright));
        float3 slab = mix(clearIce, frosted, frostHere);
        float dust = smoothstep(0.66, 0.9, fbm(q * 40.0 + 9.0, 3)) * patch * (1.0 - scuff);
        slab = mix(slab, float3(0.95, 0.97, 1.0), dust * 0.5);
        // A glassy sheet reflects the winter sky: a pale, even lift, a little
        // stronger where the frost has been wiped away.
        slab = mix(slab, float3(0.58, 0.66, 0.74), 0.30 + 0.08 * scuff);

        // The fractures: exact Voronoi shard edges out of the baked field.
        // A crack races out from the blow in a fifth of a second, then creeps
        // on for another six; it is a dark wet line with the water showing
        // through, a pale frost halo, a thin bright line of air just outside
        // the wet core, and a glint where the wet edge catches the light.
        if (p.world.z > 0.5 && crackF.g > 0.004 && crackF.r < 0.999) {
            // The strike index must not be interpolated: a blend of strikes
            // 3 and 5 would read strike 4's clock. Take the nearest texel.
            constexpr sampler nearestSmp(filter::nearest, address::clamp_to_edge);
            float which = crackTex.sample(nearestSmp, crackUV).a;
            uint strikeCount = uint(max(p.world.w, 1.0));
            uint si = min(uint(which * 255.0 + 0.5), strikeCount - 1);
            float age = p.time - iceStrikes[si].time;
            float grown = smoothstep(0.0, 0.22, age) * 0.78 + smoothstep(0.3, 6.0, age) * 0.22;
            float radial = crackF.b;
            float live = 1.0 - smoothstep(max(grown - 0.06, 0.0), max(grown, 1e-3), radial);
            float alpha = crackF.g * live;
            if (alpha > 0.002) {
                // 3.2pt at the blow tapering to 1.1pt at the tip, in world
                // points: the zoom is screen points per world point.
                // 2.6pt at the blow tapering to 1.0pt at the tip, in world
                // points, swelling and pinching a little along its length.
                float w = mix(2.6, 1.0, saturate(radial)) * (0.8 + 0.5 * fbm(q * 28.0 + 4.0, 2))
                          / max(p.view.x, 0.05);
                float core = 1.0 - smoothstep(w * 0.5 - crackAA, w * 0.5 + crackAA, crackDist);
                float halo = 1.0 - smoothstep(w * 0.6, w * 2.4, crackDist);
                float air  = smoothstep(w * 0.5, w * 0.75, crackDist)
                             * (1.0 - smoothstep(w * 0.75, w * 1.15, crackDist));
                // Cracks inside a shard that is going under flood with it.
                alpha *= solid;
                float3 wet = col * 0.40 + float3(0.01, 0.03, 0.06);
                slab = mix(slab, float3(0.90, 0.94, 0.99), halo * 0.22 * alpha);
                slab = mix(slab, wet, core * alpha);
                slab = mix(slab, float3(0.96, 0.98, 1.00), air * 0.28 * alpha);
                // The wall of the crack tilts away from it: the gradient of
                // the distance field is its normal.
                float2 ctexel = 1.0 / float2(crackTex.get_width(), crackTex.get_height());
                float2 crackGrad = float2(crackTex.sample(smp, crackUV + float2(ctexel.x, 0)).r
                                          - crackTex.sample(smp, crackUV - float2(ctexel.x, 0)).r,
                                          crackTex.sample(smp, crackUV + float2(0, ctexel.y)).r
                                          - crackTex.sample(smp, crackUV - float2(0, ctexel.y)).r);
                float3 cn = normalize(float3(-crackGrad * 90.0, 0.55));
                float glint = pow(saturate(dot(cn, L)), 22.0) * max(air, core * 0.4);
                slab += float3(1.00, 0.99, 0.95) * glint * 0.35 * alpha;
            }
        }

        // The broken edge: a pale lip of thickness over black water.
        float rim = smoothstep(0.10, 0.5, edge);
        slab = mix(slab, float3(0.06, 0.09, 0.12), rim * 0.55 * (1.0 - smoothstep(0.75, 1.0, frozen)));
        slab = mix(slab, float3(0.96, 0.97, 0.99), smoothstep(0.5, 0.95, frozen) * rim * 0.6);
        // A shard going under: it darkens as the water floods over it, the
        // water's own light and ripples showing through more each moment,
        // until only the water is left.
        float3 sunk = mix(slab * float3(0.68, 0.74, 0.84), col, smoothstep(0.0, 1.0, sinkT) * 0.92);
        float3 sheet = mix(sunk, slab, solid);
        float presence = max(solid, (1.0 - solid) * (1.0 - sinkT * sinkT));
        col = mix(col, sheet, presence);
    }
    return float4(menuShade(col, wuv, p), 1.0);
}

// ---------------------------------------------------------------------------
// Solids. A few things on the pond are bodies, not paper: a can has to spin
// about its own axis and stay rigid while the water tips it, and a stone
// drawn flat reads as a disc pasted on the water. They are real meshes,
// toon shaded in three bands with an ink rim, so they read as the same print
// as everything else on the pond.
//
// The mesh is normalised: x runs -0.5 to 0.5 along the long axis and y, z sit
// on the unit circle. The vertex shader scales it by the instance's length
// and radius, and divides the normal by that same scale, which is what turns
// a normalised normal into the normal of the real body.
// ---------------------------------------------------------------------------

struct SolidInstance {
    float2 position;       // world points on the water plane
    float  lift;           // points above the plane the axis sits
    float  yaw;            // heading of the long axis on the plane
    float  roll;           // rotation about the long axis, or a stone's lump seed
    float2 tilt;           // surface slope under it
    float  length;         // points
    float  radius;         // points
    uint   shape;          // 0 can, 1 bottle, 2 stone, 3 log
    float  alpha;
    float4 colourA;        // main body colour
    float4 colourB;        // band / cap / moss / cut wood colour
};

struct SolidParams {
    float4 light;          // xyz direction toward the light, sprite screen frame
    float4 ink;            // rgb woodblock line colour
    float4 gains;          // x slope to bank, y far plane in points, z specular, w rim width
};

struct SolidVertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float  v        [[attribute(2)]];
    float  ang      [[attribute(3)]];
    float  part     [[attribute(4)]];
    float  rad      [[attribute(5)]];
    float  bump     [[attribute(6)]];
};

struct SolidOut {
    float4 position [[position]];
    float3 normal;         // world space
    float3 view;           // world space, toward the camera
    float3 light;          // world space, toward the light
    float3 lp;             // position on the normalised body, for speckle
    float4 colourA;
    float4 colourB;
    float  v;              // 0 to 1 along the axis
    float  ang;            // around the axis
    float  part;
    float  rad;
    float  bump;           // how far out of the smooth shape, -1 to 1
    float  alpha;
    float  wz;             // height above the water plane, in radii
    uint   shape;
};

// Hash noise for the bodies that are not smooth. A stone's lumps are worked
// out here rather than baked into the mesh, because every stone wants its
// own and they all share the one buffer.
static float hash31(float3 p)
{
    p = fract(p * 0.3183099 + float3(0.71, 0.113, 0.419));
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

static float valueNoise3(float3 p)
{
    float3 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float n000 = hash31(i + float3(0, 0, 0)), n100 = hash31(i + float3(1, 0, 0));
    float n010 = hash31(i + float3(0, 1, 0)), n110 = hash31(i + float3(1, 1, 0));
    float n001 = hash31(i + float3(0, 0, 1)), n101 = hash31(i + float3(1, 0, 1));
    float n011 = hash31(i + float3(0, 1, 1)), n111 = hash31(i + float3(1, 1, 1));
    float x00 = mix(n000, n100, f.x), x10 = mix(n010, n110, f.x);
    float x01 = mix(n001, n101, f.x), x11 = mix(n011, n111, f.x);
    return mix(mix(x00, x10, f.y), mix(x01, x11, f.y), f.z);
}

/// Where a stone's surface stands relative to a smooth one, -1 to 1. Three
/// octaves: the shape of the stone, its corners, and a little grit.
static float stoneBump(float3 u, float seed)
{
    float3 o = float3(seed * 1.7, seed * 0.9 + 4.2, seed * 2.3 + 11.5);
    float n = valueNoise3(u * 1.7 + o) * 0.60
            + valueNoise3(u * 3.9 + o.yzx) * 0.28
            + valueNoise3(u * 8.1 + o.zxy) * 0.12;
    return n * 2.0 - 1.0;
}

/// The direction on the unit sphere a stone vertex came from. Rebuilt from
/// the ring and the angle so the seam lands on exactly the same point.
static float3 stoneDir(float v, float ang)
{
    float phi = v * M_PI_F;
    float ring = sin(phi);
    return float3(-cos(phi), cos(ang) * ring, sin(ang) * ring);
}

/// That direction pushed out by its lumps and squashed into the stone's
/// ellipsoid: x half as long, the up axis flattened.
static float3 stonePoint(float3 u, float bump)
{
    return float3(0.5, 1.0, 0.65) * u * (1.0 + 0.12 * bump);
}

vertex SolidOut solid_vertex(SolidVertexIn vin                  [[stage_in]],
                             constant SolidInstance *instances  [[buffer(1)]],
                             constant SolidParams &p            [[buffer(2)]],
                             constant CameraParams &cam         [[buffer(4)]],
                             uint iid                           [[instance_id]])
{
    SolidInstance s = instances[iid];

    // The body sits on the water, so its up is the surface normal under it.
    // A floater sprite shifts sideways by the same slope; here the slope
    // becomes a bank instead, so a passing crest rolls the can over.
    float2 sl = s.tilt * p.gains.x;
    float3 up = normalize(float3(-sl.x, -sl.y, 1.0));
    float3 heading = float3(cos(s.yaw), sin(s.yaw), 0.0);
    float3 ax = heading - up * dot(heading, up);
    ax = (length(ax) < 1e-4) ? float3(1.0, 0.0, 0.0) : normalize(ax);
    float3 side = normalize(cross(up, ax));

    // Roll turns the cross-section about the long axis. A stone does not
    // roll: it sits where it fell, and its roll slot is the seed of its lumps.
    bool isStone = (s.shape == 2u);
    float cr = isStone ? 1.0 : cos(s.roll);
    float sr = isStone ? 0.0 : sin(s.roll);
    float3 bY =  side * cr + up * sr;
    float3 bZ = -side * sr + up * cr;

    float3 mesh = vin.position;
    float3 normal = vin.normal;
    float bump = vin.bump;
    if (isStone) {
        // Push the vertex out along the sphere's own normal, then take the
        // normal of what that made. A face average is not on offer a vertex
        // at a time, so it comes off two steps across the same field, which
        // is the surface normal of the lumpy body itself.
        float3 u = stoneDir(vin.v, vin.ang);
        bump = stoneBump(u, s.roll);
        mesh = stonePoint(u, bump);
        float3 ref = abs(u.x) < 0.8 ? float3(1, 0, 0) : float3(0, 1, 0);
        float3 t1 = normalize(cross(u, ref));
        float3 t2 = cross(u, t1);
        const float e = 0.035;
        float3 ua = normalize(u + t1 * e), ub = normalize(u + t2 * e);
        float3 pa = stonePoint(ua, stoneBump(ua, s.roll));
        float3 pb = stonePoint(ub, stoneBump(ub, s.roll));
        normal = normalize(cross(pa - mesh, pb - mesh));
        if (dot(normal, mesh) < 0.0) normal = -normal;
    }

    float3 local = float3(mesh.x * s.length, mesh.y * s.radius, mesh.z * s.radius);
    float3 P = float3(s.position, s.lift) + ax * local.x + bY * local.y + bZ * local.z;

    float3 nm = normalize(float3(normal.x / max(s.length, 1e-3),
                                 normal.y / max(s.radius, 1e-3),
                                 normal.z / max(s.radius, 1e-3)));
    float3 N = ax * nm.x + bY * nm.y + bZ * nm.z;

    float2 clip = projectToScreen(P, cam) / cam.focal.zw;
    float depth = dot(P - cam.position.xyz, cam.forward.xyz);

    SolidOut out;
    out.position = float4(clip.x * 2.0 - 1.0, 1.0 - clip.y * 2.0,
                          clamp(depth / p.gains.y, 0.0, 0.999), 1.0);
    out.normal = N;
    out.view = normalize(cam.position.xyz - P);
    // The sprites give their light in the screen frame. The same vector, put
    // back through the camera basis, is the world direction it means.
    out.light = normalize(p.light.x * cam.right.xyz + p.light.y * cam.down.xyz - p.light.z * cam.forward.xyz);
    out.colourA = s.colourA;
    out.colourB = s.colourB;
    out.v = vin.v;
    out.ang = vin.ang;
    out.part = vin.part;
    out.rad = vin.rad;
    out.lp = mesh;
    out.bump = bump;
    out.alpha = s.alpha;
    out.wz = P.z / max(s.radius, 1e-3);
    out.shape = s.shape;
    return out;
}

fragment float4 solid_fragment(SolidOut in [[stage_in]],
                               constant SolidParams &p [[buffer(0)]])
{
    float3 N = normalize(in.normal);
    float3 V = normalize(in.view);
    float3 L = normalize(in.light);
    float alpha = in.alpha;

    float3 base;
    float spec = 0.0;
    if (in.shape == 0u) {
        // A can: a printed body between two silver lids.
        if (in.part > 0.5) {
            base = float3(0.78, 0.80, 0.84);
            // The lid is a disc with a darker ring pressed round its edge.
            base *= mix(1.0, 0.62, smoothstep(0.80, 0.97, in.rad));
            spec = 1.0;
        } else {
            float labelBand = smoothstep(0.17, 0.19, in.v) * (1.0 - smoothstep(0.81, 0.83, in.v));
            // The printed label is the body colour; the bare metal shows at the ends.
            base = mix(in.colourB.rgb * float3(0.86, 0.87, 0.9), in.colourA.rgb, labelBand);
            // A thin pale stripe round the middle of the label.
            base = mix(base, float3(0.97, 0.96, 0.92), (1.0 - smoothstep(0.010, 0.020, abs(in.v - 0.5))) * labelBand);
            spec = 0.55;
        }
    } else if (in.shape == 2u) {
        // A stone: grey with a fine speckle in it, and moss on whatever side
        // of it faces the sky. A bare stone is handed the same colour twice,
        // so the moss lands on it and changes nothing.
        float speck = hash31(in.lp * 210.0);
        base = in.colourA.rgb * (0.93 + 0.14 * speck);
        // A little dirt down in the hollows of the lumps.
        base *= 1.0 + in.bump * 0.09;
        float mossy = saturate(length(in.colourB.rgb - in.colourA.rgb) * 3.0);
        // The moss takes the upper side, feathered, and follows the lumps.
        float moss = smoothstep(0.28, 0.55, N.z + in.bump * 0.16) * mossy;
        base = mix(base, in.colourB.rgb, moss);
        // Where the moss runs out the print puts a darker edge on it.
        float edge = moss * (1.0 - moss) * 4.0;
        base = mix(base, in.colourB.rgb * 0.60, edge * 0.5);
        spec = 0.12;
    } else if (in.shape == 3u) {
        // A log: bark down the length of it, the grain showing on the cuts.
        if (in.part > 0.5) {
            float rings = 0.5 + 0.5 * sin(in.rad * 44.0 + 1.7);
            base = mix(in.colourB.rgb, in.colourB.rgb * 0.72, rings * 0.55);
            // Heartwood a shade warmer, and the bark closes the rim.
            base = mix(base * float3(1.02, 0.98, 0.94), in.colourA.rgb, smoothstep(0.86, 1.0, in.rad));
            spec = 0.15;
        } else {
            // The ridges catch the light, the crevices between them hold shade.
            base = in.colourA.rgb * (0.80 + 0.32 * saturate(in.bump * 0.5 + 0.5));
            spec = 0.08;
        }
    } else {
        // A bottle: glass you can half see through, with a solid cap.
        if (in.part > 2.5) {
            base = in.colourB.rgb;
            spec = 0.6;
        } else if (in.part > 1.5) {
            base = mix(in.colourA.rgb, float3(0.94, 0.97, 0.98), 0.6);
            alpha *= 0.40;
            spec = 0.8;
        } else {
            base = in.colourA.rgb;
            // Glass is only really there at a glancing angle.
            float fres = 1.0 - abs(dot(N, V));
            alpha *= 0.55 * mix(0.75, 1.9, fres * fres);
            spec = 0.9;
        }
    }

    // Toon shading: three flat steps, the way the print cuts a curve.
    float d = max(0.0, dot(N, L));
    float band = d < 0.30 ? 0.55 : (d < 0.66 ? 0.80 : 1.0);
    float3 col = base * band;

    float3 H = normalize(L + V);
    col += float3(1.0, 0.98, 0.92) * pow(max(0.0, dot(N, H)), 34.0) * spec * p.gains.z;

    // The waterline: the body goes dark and wet where it dips into the pond.
    float wet = 1.0 - smoothstep(0.02, 0.10, in.wz);
    col *= mix(1.0, 0.75, wet);
    // Below the surface the water takes it: it does not sit on top of the pond.
    float under = smoothstep(0.0, -0.45, in.wz);
    col = mix(col, col * float3(0.42, 0.58, 0.66), under);
    alpha *= 1.0 - under * 0.85;

    // The ink rim. Where the surface turns away from the eye the print puts a
    // line, and that line is what makes it a drawn object rather than a model.
    float rim = 1.0 - smoothstep(p.gains.w * 0.6, p.gains.w, abs(dot(N, V)));
    col = mix(col, p.ink.rgb, rim);
    alpha = mix(alpha, max(alpha, in.alpha * (1.0 - under * 0.85)), rim);

    return float4(col * alpha, alpha);
}
