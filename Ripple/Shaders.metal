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
};

struct SiltParams {
    float4 viewport;       // xy drawable size
    float4 size;           // xy silt texture size
    float4 gains;          // x |h| gain, y |lap| gain, z threshold, w rate*dt
    float4 mosaic;         // xy centre uv, z radius (fraction of height)
    uint   coverCount;
    uint   _pad0, _pad1, _pad2;
};

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
                      constant SimParams &p                 [[buffer(0)]],
                      constant Splat *splats                [[buffer(1)]],
                      constant float4 *walls                [[buffer(2)]],
                      uint2 gid                             [[thread_position_in_grid]])
{
    if (gid.x >= p.size.x || gid.y >= p.size.y) { return; }

    float d = depth.read(gid).r;
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
    v *= p.damping;

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
                                       constant FloorParams &p                  [[buffer(0)]])
{
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    // The bed lies at the bottom of the bowl. Seen through the camera it is a
    // little smaller than the surface and slides with the camera's offset.
    float H = p.camera.z;
    float sb = H / (H + p.bed.y);
    float2 centre = p.viewport.xy * 0.5;
    float2 screen = in.uv * p.viewport.xy;
    // Invert the projection: which bed point lands on this pixel?
    float2 bedPoint = centre + (screen - p.camera.xy * (1.0 - sb) * p.camera.w - centre) / sb;
    // The painting is a little larger than the screen so its edges never
    // show, whatever the camera does.
    float2 buv = 0.5 + (bedPoint / p.viewport.xy - 0.5) * 0.80;
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
    float3 abyss = p.deep.rgb * 0.8;
    col = mix(col, abyss, deepness * 0.6);
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
static float2 project(float2 pointOnSurfacePlane, float z, float4 camera, float2 viewport)
{
    float H = camera.z;
    float s = H / max(H - z, 0.1);
    float2 centre = viewport * 0.5;
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
};

vertex SpriteOut sprite_vertex(SpriteVertexIn vin                         [[stage_in]],
                               constant SpriteInstance *instances         [[buffer(1)]],
                               constant SpriteParams &p                   [[buffer(2)]],
                               constant float4 *spines                    [[buffer(3)]],
                               texture2d<float, access::sample> field     [[texture(0)]],
                               uint iid                                   [[instance_id]])
{
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    SpriteInstance s = instances[iid];
    uint mode = s.mode & 3u;
    bool flip = (s.mode & 8u) != 0;
    bool weed = (s.mode & 32u) != 0;

    float2 uv = vin.uv;
    float2 local = (uv - 0.5) * s.size;          // v grows downward in the image
    if (flip) { local.x = -local.x; }
    float tailness = 1.0 - uv.y;                 // 0 at the image bottom (root / head), 1 at the top (tip / tail)

    // Depth of this vertex. Most sprites are flat at their layer's depth; a
    // weed rises from the bed at its root to near the surface at its tip.
    float z = s._pad.y;
    if (weed) { z = mix(-0.92, -0.22, tailness); }

    float wet = 0.0;
    float rotation = s.rotation;
    float2 onSurface;                            // position as if on the surface plane, before projection

    int spine = int(s._pad.x) - 1;
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
        // A strand bends as a curve from its root: the lean (in waveAmp) and
        // the idle sway (in wave) both grow with the square of the distance
        // up the stem, which is how grass bends in moving water.
        float bend = s.waveAmp + sin(s.wave) * 0.06;
        float2 up = float2(sin(s.rotation), -cos(s.rotation));
        float2 lateral = float2(cos(s.rotation), sin(s.rotation));
        float along = tailness * s.size.y;
        float2 root = s.center - up * (0.5 * s.size.y);
        onSurface = root + up * along + lateral * (local.x + bend * along * tailness);
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

    float2 world = project(onSurface, z, p.camera, p.viewport.xy);

    SpriteOut out;
    out.position = float4(world.x / p.viewport.x * 2.0 - 1.0, 1.0 - world.y / p.viewport.y * 2.0, 0.0, 1.0);
    out.uv = uv;
    out.tint = s.tint;
    out.alpha = s.alpha;
    out.wet = wet;
    out.depth = s.depth;
    out.mode = mode;
    out.flags = s.mode;
    out.rot = float2(cos(rotation), sin(rotation)) * float2(flip ? -1.0 : 1.0, 1.0);
    return out;
}

fragment float4 sprite_fragment(SpriteOut in                             [[stage_in]],
                                texture2d<float, access::sample> tex     [[texture(0)]],
                                texture2d<float, access::sample> relief  [[texture(1)]],
                                constant SpriteParams &p                 [[buffer(0)]])
{
    constexpr sampler smp(filter::linear, address::clamp_to_edge, mip_filter::linear);
    float4 c = tex.sample(smp, in.uv);
    // Textures load premultiplied.
    float a = c.a * in.alpha;
    float3 rgb = c.rgb * in.tint.rgb * in.alpha;

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

    bool woodblock = p.style.x > 0.5;

    float activity = saturate(abs(hC) * 5.0 + abs(lap) * 26.0);
    float2 dp = float2(0.004, 0.0);
    float2 sc = in.uv * 34.0 + float2(p.time * 0.55, -p.time * 0.42);
    float  n0 = valueNoise(sc);
    float2 fineGrad = float2(valueNoise(sc + dp.xy) - n0,
                             valueNoise(sc + dp.yx) - n0);
    float detail = woodblock ? p.detailGain * 0.25 : p.detailGain;
    float3 N = normalize(float3(-(grad * 46.0 + fineGrad * detail * activity), 1.0));

    float2 offset = grad * p.refraction * (woodblock ? 0.6 : 1.0);
    float  spread = woodblock ? 0.0 : p.dispersion;
    float3 col;
    col.r = floorTex.sample(smp, in.uv + offset * (1.0 + spread)).r;
    col.g = floorTex.sample(smp, in.uv + offset).g;
    col.b = floorTex.sample(smp, in.uv + offset * (1.0 - spread)).b;

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
        return float4(col, 1.0);
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
    return float4(col, 1.0);
}
