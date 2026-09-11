# Gameplay reinvention: a dormant pond you bring to life

Why: the owner hand-tested the 24 "tidy the pond" levels (`f0588b7`) and said
the gameplay is "not engaging and a bit boring... flicking crisp packets
around". The water is the star and the goals ignored it. The one thing that
landed was ice v7, because it is a MATERIAL you touch with a direct, tangible
answer. So: every level's goal now lives in the water and its life, not in
rubbish herded to a bank.

Standing rules still apply: no ripple budget, no par, no timers, no fail
([[ripple-gameplay-direction]]); natural, tactile, satisfying
([[ripple-guiding-principles]]); nothing painted that the sim does not drive.

## The frame

Every pool on the stream starts DORMANT: still, murky, quiet, mist on it, no
fish showing. Playing a level wakes it, and what you woke STAYS: the hub pool
keeps the koi you called up, the shoal you led, the bud you opened, the moon
you found. The map is a garden you grew.

Rubbish is gone as a mechanic. (The can/bottle kinds and solids stay in the
code; no level places one.)

## Verb families

1. **COAX** the life. Living things answer ripples.
   - Koi rise to a HELD finger (`callUp`): a charged hold within 260 pt draws
     the nearest koi up; it comes under the finger and hovers at the surface
     mouthing; it stays up 3 s after release then cruises off.
   - Koi are CURIOUS about a single tap when the pond is calm (they turn
     toward a ring's source from far away); they SCATTER at a slap (two-tap
     stone drop, big splash) and hide under a log/pads.
   - A SHY koi lives under a shape (pads or a log). It only comes out when the
     water over its hiding place has been calm for 3 s and a finger is held
     150-300 pt away; it edges out toward the finger; churning the water over
     its home sends it back.
   - The SHOAL follows a WAKE: a fast stroke lays splats; the shoal's wander
     point becomes the stroke's far end for 5 s and the fish stream along the
     path (leader = nearest fish to the stroke start).
   - Koi sleeping under ice wake when the sheet over them opens: they rest on
     the bed until `iceOver < 0.5`, then rise slowly.
   Goals: "Call the koi up" (koi surfaced within r of a point for 1.5 s),
   "Call the koi up beneath the bud" (a surfaced koi under the bud opens it),
   "Lead the shoal through the gap" (shoal centroid crosses a gate segment),
   "Tempt the shy koi out" (it leaves its home shape entirely).

2. **TEND** the growing things. Ripples carry seeds, light and pollen.
   - SEEDS are light debris (`DebrisKind.seed`) that do not clear at a bank;
     they ROOT when they rest 1.5 s inside a shallows shape (`rootIn`), then
     a sprout grows there over 6 s (`sprout_1..3`).
   - The BUD opens when a crest above its threshold passes (existing target)
     OR a surfaced koi nudges it (coax). Near misses TREMBLE it (h > 0.6·thr)
     with a soft tick.
   - DUCKWEED (summer material) covers the pond as a film; wakes and swells
     part it and it drifts to the banks where it stays. Light reaches the
     bed where it is parted; goal = cover < 12 %.
   - SILT (spring material) clouds the bed; every ripple scours it; the goal
     is to clear the whole pond (existing `silt_erode`, region = whole pond).
   - LEAVES (autumn material) keep falling for a while; gusts sweep them;
     they cluster and clog; goal = the ones that fell are all on the banks
     (the fall stops after N have landed).

3. **MOVE THE WATER**.
   - SLOSH-FILL: a dry pool sits on the bank beyond a lip. Rocking the pond in
     rhythm (slosh gesture, holds, swells) builds a standing wave; every crest
     over the lip above `lipHeight` spills and adds to the pool's fill. When
     full, the pool joins the pond (depth repainted, water appears, foam at
     the lip) and the shoal swims in.
   - SHISHI-ODOSHI: a bamboo rocker at the bank. Crests over its spout fill
     it; when full it tips, knocks on its stone (sound + haptic + a splash
     where it empties) and resets. Goal = N knocks.
   - SUIKINKUTSU: 4-5 stones in the shallows; a crest over a stone sounds a
     water-chime note. The pond hums the phrase at the start (and again after
     a wrong note). Ripple the stones in that order; each right note glows
     its stone; the finished phrase wakes the pond.

4. **STILLNESS**: let the pond go glassy. `calm` = no touch for 2 s and the
   mean |velocity| over 16 fixed probe cells below `calmThreshold`. Held for
   `seconds` (6-8) it completes the goal: the moon appears in the water
   (`moon.png` surface sprite fading in, `dayPhase` eased toward dusk), the
   dragonfly lands on a reed. Any touch resets the timer (softly: the moon
   fades over 1.5 s, no penalty).

5. **FEEDBACK DENSITY**: every tap gets an immediate rich answer: shoal
   scatters, koi veer or turn curious, reeds sway, weeds bend, a near-miss
   trembles the target with a tick, the frog jumps, drips fall.

## Contract: `Ripple/Game/GoalTypes.swift` (written first; do not change)

```swift
enum GoalKind {
    case clearDebris                      // every non-seed piece beached
    case breakIce                         // ice fraction < 0.06
    case clearSilt(clean: Float)          // renderer silt cleaned >= clean (whole pond)
    case partDuckweed(cover: Float)       // renderer film cover <= cover
    case rootSeeds(shallows: Shape, count: Int)
    case callKoi(at: CGPoint, radius: CGFloat)
    case koiOpensBud(bud: CGPoint)
    case leadShoal(gate: (CGPoint, CGPoint))
    case temptShyKoi(home: Shape)
    case wakeTarget(TargetKind, at: CGPoint, threshold: Float)
    case shishiOdoshi(at: CGPoint, knocks: Int)
    case suikinkutsu(stones: [CGPoint], order: [Int])
    case fillPool(lip: CGPoint, pool: Shape, lipHeight: Float)
    case stillness(seconds: Float)
}
struct GoalSpec { kind, text (the goal line), done }
struct GoalContext { ... everything a goal reads each frame ... }
protocol LifeCoax   (Garden adopts; defaults are stubs)
protocol Materials  (WaterRenderer adopts; defaults are stubs)
```
See the file for the exact signatures. Positions in `GoalSpec` are WORLD
FRACTIONS in `Library` (like debris) and are converted to world points by
`GameController` when the level is placed (`GoalSpec.placed(in:)`).

## Ownership (wave 1, parallel, disjoint files)

- **A Life & coax** owns `Ripple/Game/Garden.swift`: implement `LifeCoax` on
  Garden (override the stubs): `callKoi(at:charge:dt)`, `releaseCall()`,
  `koiSurfacedNear(_:radius:)`, `shoalCentroids()`, `followWake(path:)`,
  `setShyHome(_:)`, `shyKoiOut`, `sleepKoiUnderIce(_:)`, `curious(tap:)`,
  `stillness(_:)` (moon + dragonfly landing), `trembleTarget` is not yours.
  Koi behaviours above. Shoal follow. Sleeping koi. Moon sprite
  (`moon.png`, agent D makes it; use a soft white disc if missing) as a
  surface floater at alpha ≤ 0.55 that rides the water.
- **B Materials** owns `Ripple/Shaders.metal`, `Ripple/WaterRenderer.swift`,
  new `Ripple/Game/Materials.swift`: implement `Materials` on WaterRenderer:
  `setFilm(on:)` + `filmCover` (duckweed: r16 texture at silt size,
  `film_advect` compute each sim step: semi-Lagrangian along
  `-slope * filmGain * dt` + a little diffusion, density clamped 0-1; cells
  with depth < 0.15 ABSORB film into a `shore` channel (g) that draws as a
  weed rim and never returns; readback of the water-cell mean every 12
  frames like silt); render in `water_fragment`: film density → duckweed
  carpet from a FINE seamless tile (`duckweed_tile.png`, agent D; fallback a
  procedural dot pattern) that breaks into single leaves below 0.35 density,
  with a soft shadow on the bed; `setSilt(wholePond:)` (silt region = every
  water cell, no mosaic image, `siltRemaining` = mean over water cells;
  the murky look must read as SILT haze not a mosaic film); `repaintDepth()`
  (calls the depthPainter again and re-uploads, keeping the field); `calm
  probes` need nothing from you (GameController uses `setProbes`).
- **C Instruments** owns new `Ripple/Game/Instruments.swift`,
  `Ripple/Solids.swift` (additions only), `Ripple/Haptics.swift`,
  `Ripple/Audio/SoundDirector.swift` (additions only): `ShishiOdoshi`,
  `Suikinkutsu`, `DryPool` models per the protocol in GoalTypes; a
  `SolidMesh.bamboo()` tube (shape 6, pivots about its rear third, `roll`
  reused as tilt angle) and `stoneBowl` (shape 2 stone) instances; sound
  hooks `bamboo(x:)`, `chime(note:x:)`, `spill(x:)`, `leaves(x:)`,
  `weedRustle(x:)`, `gulp(x:)`, `tremble(x:)` (use varispeed on existing
  files until agent E's land; NEVER schedule a buffer with a foreign format,
  see the 1b3afe9 trap) and haptics `knock()`, `chime()`, `spill()`,
  `tremble()`.
- **D Art** (Recraft, disjoint: only `Ripple/Art/` new files + a report):
  `duckweed_tile.png` (fine, seamless, top-down duckweed carpet, healed),
  `duckweed_leaf.png` (single leaf cluster, isolated), `moon.png` (soft full
  moon disc, warm white, feathered), `seed_1..3.png` (lotus seeds / pods,
  top-down, isolated), `sprout_1..3.png` (young lotus/lily sprout rising,
  side-ish, isolated), `bamboo_knock` reference not needed, `chime_glow.png`
  (soft ring). Matte with `remove_background`, never colour-key sheets with
  white interiors.
- **E Sound** (Pixabay Content License only, ledger in
  `Ripple/Audio/Sounds/LICENSES.md`, manifest entries): `fx_bamboo_knock`,
  `fx_water_chime_1..3` (suikinkutsu drip in a jar), `fx_spill` (water over
  a lip), `fx_leaves_1..2` (dry leaf rustle), `fx_weed_rustle` (wet
  vegetation), `fx_gulp` (koi at the surface), `fx_tremble` (a soft wooden
  tick), `amb_night` (crickets, still night).
- **F Hub** owns `Ripple/Game/HubController.swift`, `Ripple/UI/HubView.swift`,
  `Ripple/Progress/ProgressStore.swift`: `ProgressStore.woke(levelID) ->
  Set<WokeToken>` + `markWoke(levelID, tokens)`; dormant pools: mist, no
  fish, darker water, a still bud; woken pools: koi circling (token .koi),
  shoal (.shoal), open lotus (.bud), sprouts (.seeds), moon glint at the
  pool (.moon), bamboo rocker (.bamboo), clear bed (.clear). The tour of
  the map from a finished game should look like a living garden.

Wave 2 (after wave 1 lands, one agent): **G Integration** owns
`GameController.swift`, `Library.swift`, `DemoScript.swift`, `Debris.swift`:
`LevelSpec.goals: [GoalSpec]` replaces the derived `goal`; the 24-level
roster below; `GoalEvaluator` per frame with `GoalContext`; status line from
goals; hints; calm probes; `finish()` records woke tokens; the demo script
learns each goal kind so `batch.sh` finishes all 24.

## The 24 levels

Winter (ice + waking): 1 the sheet; 2 open the ice over the sleeping koi and
call it up; 3 open a channel and lead the shoal out of its pocket; 4 the bell
under the ice; 5 stillness after the thaw: the moon; 6 ice + koi + shoal.

Spring (silt + tending): 1 clear the silt; 2 carry three seeds to the
shallows; 3 call the koi up beneath the bud; 4 twin ripples lift the log,
then lead the shoal through; 5 the shishi-odoshi, three knocks; 6 silt +
seeds + koi.

Summer (duckweed + lens): 1 part the duckweed; 2 the bud beyond the sandbank
(lens); 3 lead the shoal through the pad gap; 4 the suikinkutsu phrase; 5
tempt the shy koi out from under the pads (duckweed too); 6 rain + duckweed
+ bud + shoal.

Autumn (leaves + moving water): 1 the leaves that fall; 2 fill the dry pool
by rocking the pond; 3 weir logs in order, then the shoal; 4 leaves + gusts +
the shy koi under the log; 5 inlet + rain + leaves; 6 the still pond at dusk:
the moon, and the year is done.
