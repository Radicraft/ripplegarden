# Winter ice, version 7: Voronoi shards, a tangible sheet

Why: every previous version drew cracks as lines (raster walks, then painted
Recraft sprites) that did not agree exactly with the holes they made, and the
owner rejected them all ("shitty lines", "pixelled", "unnatural"). The
standard technique in games (Godot impact-glass shader, VoronoiShatter,
Houdini/C4D fracture) is a VORONOI diagram seeded radially about the impact:
each cell is a shard, each cell edge is a crack, and the edge is drawn in the
shader as an exact distance field, so it is sub-pixel crisp at any zoom and
the crack lines ARE the shard outlines. Real glass/ice breaks radial +
concentric, which the seed layout reproduces. Real pond ice: cracks are dark
WET lines (water in them) with a pale frost/air halo, nearly straight, running
past the hole; the sheet is black ice with frost patches and snow dust.

The sheet must also be a SURFACE the finger feels: a slide across it gives
haptic texture and wipes the frost/snow (a scuff), and does not break it; a
tap breaks it.

Three agents build this in parallel on the same checkout, disjoint files.
Shared types already exist in `Ripple/Game/IceTypes.swift` (do not change):

```swift
struct IceSeedGPU { pos: SIMD2<Float>; strength; reach; strike; broken; pad }   // 32 B
struct IceStrikeGPU { centre: SIMD2<Float>; ring; time }                          // 16 B
```
`WaterRenderer.clock` (seconds since renderer start) is the time base.
`WaterRenderer.setIceCracks(seeds:strikes:)` and `setIce(cells, scuff:, width:, height:)`
exist as stubs/signatures.

## Geometry (Agent A owns `IceField.swift`, `GameController.swift`, `DemoScript.swift`, `Library.swift` hint text)

World is `viewSize` points; the CPU masks stay at 1 cell per world point:
`cells` (1 ice, 0 water) and NEW `scuff` (0..1, frost wiped by a finger).
Delete the raster `cracks`, `crackLines`, `fracture()`, `straightFracture`,
`breakPolygon`, `breakThrough` flood fill, `strikes/scars` tuples, and the
Recraft `fracture_N` sprites (`crackSprites`, `rebuildCrackSprites`).

`strike(at p, ring)`: appends an `IceStrikeGPU(centre, ring, time: clock)` and
its seeds:
- centre seed at p (jitter 3pt), strength 1, reach 1.3
- spokes: n = 5...8 at even angles + jitter ±0.35 rad; along each spoke seeds
  at radii ring × {0.28, 0.58, 0.9} × (1 ± 0.2), each nudged off the spoke
  ±0.12 rad; strength 1 (inner shards), reach 1.3
- rim seeds: on each spoke and midway between spokes at ring × 1.35 (±0.15),
  strength 0, reach 1.3. Rim cells are the surrounding sheet: never break;
  an edge between two rim seeds is invisible. So the breakable region is the
  polygon bounded by inner/rim edges: ANGULAR, never a circle.
- runners: 2-3 spokes chosen at random get a pair of seeds straddling the
  spoke at ring × 1.9 and × 2.5 (offset ±0.14 rad either side), strength
  0.55, reach 2.8. Their mutual edges continue the spoke crack far past the
  hole and taper out, like the reference photos.
Ring: 110-190pt for a tap on fresh ice; an edge bite (tap on ice within 46pt
of open water, or a wave from open water within 220pt) is a strike with ring
50-90 that breaks at once.

Nearest seed of a point (CPU and GPU must agree): loop strikes whose
`|p - centre| < ring × 3.0`; loop their seeds; nearest by distance. Distance
to the nearest crack: with a = nearest seed, over every other seed b in
reach: `d = dot(0.5*(a+b) - p, normalize(b - a))`; the crack there is
visible with strength `max(sa, sb)` and only if `|p - centre_of_strike(b)|
< ring × reach` (use the strike of whichever seed has the larger reach).
Take the min d among VISIBLE edges. Provide `func crack(at p) -> (dist: Float,
strength: Float)` and `func nearestSeed(at p) -> Int?` on IceField.

`breakOut(strikeIndex)`: mark every inner seed (strength 1, not broken) of
the strike broken; rasterise: for cells in the strike's bbox (ring × 1.4)
whose nearest seed is a broken seed, set cells = 0. Return the broken seeds
with their cell areas (count texels per seed while rasterising) so the
controller can spawn ONE chunk per shard at the seed position, radius
`clamp(sqrt(area/π) × 0.8, 12, 34)`, using `art.iceFragments`, velocity
10-30pt/s away from the tap, `meltsIn` 22-36s. A tap inside an existing
strike's ring (any inner cell) breaks the whole strike out (the owner: it
must not take ages). A tap on the sheet elsewhere is a new strike. Strikes
whose ring overlaps an existing one are fine: Voronoi merges them; when a
new strike's inner seeds land inside an already-open hole, skip those seeds.
After a break, upload `setIce(cells, scuff:)` and `setIceCracks`.

Touch model (controller): when a touch BEGINS on ice (`ice(at:) > 0.5`) it
becomes an `IceTouch` (not a pond hold, not in `pondTouches`, no splat):
- MOVED: once screen travel > 10pt OR age > 0.28s it is a SLIDE:
  `haptics.slideBegin()`, then per move `haptics.slide(speed:, grain:)` with
  speed in screen pt/s (smoothed) and grain = 0.25 + 0.75 × local scuff-free
  frost estimate (use `scuff` at the point: grain = 1 - scuff × 0.8, i.e.
  already-wiped ice feels glassier). Paint scuff along the path: a soft disc
  radius 13pt, add 0.35 per pass, cap 1 (stamp every 4pt of travel). Crossing
  a crack: track `crack(at:).dist`; when it goes from > 3pt to ≤ 3pt call
  `haptics.slideCrack(strength:)`. If the finger reaches open water the
  slide ends (`haptics.slideEnd()`), nothing else happens. Upload scuff at
  most once per frame (mark dirty; the frame loop uploads).
- ENDED: if it never became a slide and age < 0.3s it is a TAP: strike or
  break as above (`haptics.iceStrike()` on a strike, `haptics.iceBreak(size:)`
  on a break; small `addSplat` amplitude -0.04 for a strike, -0.45 for a
  break). A still hold longer than 0.3s does nothing. Ended slides call
  `haptics.slideEnd()`.
- Pinch logic is unchanged; an ice touch that joins a pinch is dropped.
- The demo (`DemoScript.tap`) ends the touch 50ms later with no move: it is a
  tap. `lastIceTap` logic stays: second tap on a struck spot, then new spot.
Hint text: "Tap the ice to crack it. Tap again to break through. Slide to feel it."

Frame loop: `if let f = iceField, f.dirty { renderer.setIce(f.cells, scuff: f.scuff, ...); renderer.setIceCracks(seeds: f.seeds, strikes: f.strikes); f.markClean() }`.
Keep `garden.iceCover`, the finish rule (ice < 6% and debris clear), `Koi.iceOver`.

## Look (Agent B owns `Shaders.metal`, `WaterRenderer.swift`, `Sprites.swift`)

New compute kernel `ice_bake` writes `crackTex` (rgba8Unorm, 2 texels per
world point, i.e. width = 2 × world width) whenever seeds/strikes change:
- r = distance to the nearest VISIBLE crack / 12pt, clamped (see the exact
  bisector formula above; loop strikes within ring × 3 of the texel, then
  their seeds; two passes: nearest seed, then min bisector distance among
  visible edges)
- g = strength of that nearest edge × taper, taper = 1 - smoothstep(0.85, 1.0,
  |p - centre| / (ring × reach)) using the reach/strike of the seed pair
- b = |p - strike centre| / (ring × 2.8) clamped (radial fraction, for the
  outward race and width taper)
- a = strike index / 255 of the nearest seed
Texels with no strike in reach write (1, 0, 0, 0). Mirror the Swift structs
as `IceSeed`/`IceStrike` in Metal (same layout). Seeds in a shared buffer
(cap 4096) and strikes (cap 255) with counts in a small params struct.
Bind `crackTex` at texture(5) in `water_fragment` and pass the strike buffer
(buffer 2) so the fragment can read `strike.time`.

In `water_fragment`, inside the `frozen > 0.02` branch (keep the black-ice /
frost-patch / dust / sky-lift look, it was approved), draw the cracks from
the field instead of sprites:
- race: `age = p.time - strike.time`; `grown = smoothstep(0, 0.22, age) × 0.78
  + smoothstep(0.3, 6.0, age) × 0.22` (fast to 78% of reach, then creeping to
  full over six seconds); an edge shows only where `b × 2.8 / reach_est <
  grown`; use b directly: show if `b < grown × 0.36 + 0.64 × grown × (g>0.9?1:0.5)`.
  Simpler acceptable rule: show if `b < grown` where b is radial fraction of
  2.8 rings. Fade the leading 6% so tips taper.
- width: `w = mix(3.2, 1.1, b)` pt in world space, converted with the zoom;
  anti-alias with fwidth of the distance (distance in pt = r × 12).
- wet core: `core = 1 - smoothstep(w×0.5 - aa, w×0.5 + aa, dist)`, colour =
  water colour under the sheet × 0.45 + (0.02, 0.04, 0.07) (dark, wet, water
  showing through), alpha = g.
- frost halo: `halo = 1 - smoothstep(w×0.6, w×2.6, dist)`, colour (0.93,
  0.96, 1.0), alpha 0.45 × g, and a thin bright "air" line just outside the
  core: `air = smoothstep(w×0.5, w×0.75, dist) × (1 - smoothstep(w×0.75, w×1.15, dist))` alpha 0.5 × g.
- glint: crack edge normal = normalize(gradient of r) (two extra samples);
  specular from the scene light direction (use the existing light vector in
  the fragment) along the edge, alpha 0.35 × g: a wet crack catches light.
- scuff: `scuff = iceTex.g`; `frostHere *= 1 - 0.85 × scuff; dust *= 1 - scuff`;
  scuffed black ice gets a little more sky reflection (sky lift + 0.08 ×
  scuff) so a wiped streak reads glassy.
- Under a broken cell the mask is 0 so nothing is drawn; the existing rim
  shading (pale lip, black water) stays. The mask edge should look crisp,
  not blurry: sample the r8 mask with a sharpening step
  (`smoothstep(0.42, 0.58, frozen)` for the slab mix).
Remove the Recraft fracture-sprite path in `sprite_fragment` only if it
gets in the way (the `maskIce` bit can stay). `wave_step` keeps sampling
`iceTex.r`. Put `crackTex` sample behind `if (p.iceHas > 0)` or bind a blank
texture when there is no ice level (the existing `blankIce` pattern).
Bake on the render thread before the frame when dirty; the bake at
2 × 600 × 2 × 1300 texels over ≤ 1000 seeds must stay under ~8ms (early-out
when no strike is in reach).

## Feel (Agent C owns `Haptics.swift` only)

Add to `Haptics` (Core Haptics path + UIKit fallback, honouring `enabled`):
- `iceStrike()`: a sharp crack: transient (0.85, 0.95) then crackle racing
  out: transients at 35ms (0.5, 0.85), 80ms (0.35, 0.8), 150ms (0.22, 0.7),
  260ms (0.12, 0.6). Fallback: rigid impact.
- `iceBreak(size: Float)` (0..1 by area): a low thud (0.6 + 0.4 size, 0.15) +
  a 140ms continuous rumble (0.35, 0.1) that decays + a splash tick at 120ms
  (0.3, 0.5). Stops any slide player first.
- `slideBegin()`: starts a continuous player (duration 30s, restart if it
  outlives that) at intensity 0, sharpness 0.3.
- `slide(speed: Float, grain: Float)`: sends dynamic parameters:
  intensity = clamp(speed / 700, 0, 1) × (0.18 + 0.42 × grain) (glassy ice
  is faint and smooth; frost is grainy), sharpness = mix(0.12, 0.6, grain).
  Also, when grain > 0.4, tiny transients every ~22pt of travel (caller
  passes distance travelled since last call: add `travel: Float` argument)
  at intensity 0.1-0.2, sharpness 0.5: the crunch of frost. Rate-limit to
  one per 16ms.
- `slideCrack(strength: Float)`: a click as the finger crosses a crack:
  transient (0.3 + 0.45 strength, 0.9).
- `slideEnd()`: stop the continuous player.
Fallback without an engine: `UIImpactFeedbackGenerator(.soft)` ticks per
30pt when grain > 0.4, `.rigid` for the crack click, `.heavy` for the break.
