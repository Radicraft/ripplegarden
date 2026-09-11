# Your own pond: the reward of playing

Owner, 2026-09-11: "the rewards of playing the game... the ability to build
your own pond... plant around the edge, put aquatic plants in... each time
you complete a level you win another item... swipe horizontally on the level
map to go to a fresh patch of the garden... You need a real reward
endorphine hit each level win, something colourful and exciting."
Rulings: rewards RANDOM with rarity, colour coded (common uncoloured, rare
BLUE, super rare GOLD), a big item pool so every pond differs; currency =
PETALS, earned only, never for real money; the garden is ALIVE and grows on
real time, produces petals to pick up, fish can be fed; the player DIGS the
pond and fills it with water (unique shapes); toys to play with on the water
(a sailing boat); a restful place.

Standing rules apply: natural, tactile, satisfying; nothing painted that the
sim does not drive; no timers, nothing to lose; no em dashes in copy.

## The reward moment (every level win)

1. The pond wakes visibly (existing: koi rise, shoal through, bud opens,
   branch blooms).
2. The burst: a deep swell from the pond's centre (`renderer.addSplat`
   radius 60, amplitude -0.5), bed light gold for 4 s (`floorLook` tint
   eased), the season's colour thrown up (petals/pollen/leaves/snow, 120
   particles from `Garden.burstDroplets`-style emitter), a chord
   (`sound.rewardChord(tier:)`), haptic `haptics.reward(tier:)`.
3. The reveal: `RewardReveal` (new file) draws the item as a body or sprite
   rising from the deep inside a ring of light coloured by tier (white /
   indigo #3D5A99 / gold #D9A441), turning slowly, with its name and tier in
   the serif under it. Gold rises longer with gold petals on the water. A
   tap sends it diving toward the bank on the garden's side with a trail.
4. Then the quiet and the completion words with a third choice: Your pond.

## The draw

`Catalogue` (data, ~120 items at gate 2; gate 1 ships the ten we have art
for): id, name, category, rarity, art (sprite or solid), placement
(bank / water / shallows / anywhere / sky), grows (Bool), sheds petals
(Bool), size range. Draw = uniform over items not owned in a tier; tier by
70 / 25 / 5 with pity: rare guaranteed within 6 wins, gold within 25
(`Inventory.winsSinceRare/Gold`). Replaying a finished level draws again.
Everything owned goes to `Inventory` (ProgressStore, CloudKit-safe: a
record per item with id, tier, wonAt, level).

## Petals

`Inventory.petals: Int`. Wins pay 12 (first time) / 6 (replay), rare +6,
gold +20. In the garden every flowering plant sheds a petal onto the water
every `k` real minutes (k = 20 / plant, capped at 40 floating petals);
tapping a floating petal collects it (it sinks with a chime, +1). Petals
buy: extra plots (gate 3), colourways (gate 3), fish food (gate 2).

## The plot

`PlotController` (new, a `TouchInput` on its own `WaterRenderer`, world =
one level's size). Reached from the map by a horizontal swipe (HubView
hosts both; the map scrolls vertically, a pan > 60 pt sideways pages to the
plot with the camera drifting across the bank). Saved in `Plot` (ProgressStore):
the dig mask (RLE bytes), water level, placed items (item id, position,
rotation, scale, plantedAt), fish (koi ids, fedAt, size), petals floating.

**Digging.** The plot begins as bank earth (depth map = dry everywhere,
the season's bank painting). `DigField` (new; like `IceField`: a CPU mask at
2 pt per cell, r = dug depth 0...1). Dragging a finger with the spade
selected (a stone button on the tray; or simply: drag on earth = dig, drag
on water = the water) lowers the ground along the stroke (a soft round
brush, radius 34 pt, +0.08 per pass, capped at 1), with earth grains thrown
up (`Droplet` in brown), a dig sound and a gritty continuous haptic. The
depth painter for the plot = `DigField` sampled: dry where dug < 0.12,
shallows to deep with depth. `renderer.repaintDepth()` on a dirty rect.
**Filling.** A sluice stone at the plot's stream side; tapping it opens the
water: the fill level `water` rises from 0 toward 1 over ~90 s (faster while
the finger holds the sluice), and the effective depth = dug * water, so the
hollow fills from its deepest point up; the sim reads the depth so waves
appear as soon as there is water; foam at the moving line (existing wet
pass). Water can be let out again at the sluice to reshape.

**Placing.** A wooden tray (`tray.png`, Recraft) floats in from the right
edge when the player taps the tray stone; it shows owned items as their
sprites on washi-free wood, scrollable by dragging. Drag an item out: it
hangs under the finger with a shadow on the ground/water; bank plants root
only on ground within 60 pt of the waterline (snap to the shoreline normal,
stand up with `stands`), aquatic plants only where depth > 0.2, stones and
logs anywhere (splash if on water, then rest), toys on water, fish are
released with a splash and become live `Koi`/`Shoal`. Two fingers turn a
placed thing; pinch scales within its range. Long press a placed item to
lift it again; drop it on the tray to store it. Everything placed is live:
reeds sway, pads block ripples, the bamboo knocks, the koi answer a finger.

**Growth on real time.** `plantedAt` saved; size = min(1, age / growDays)
eased (growDays 3 for flowers, 7 for lilies, 14 for trees), drawn as
sprouts (`sprout_1..3`) under 0.3 then the plant scaled. Koi `size` grows
0.02 per feeding, one feeding per 4 real hours counts, cap 1.3.

**Feeding.** A food bowl item (owned from the start); tap it: 8 pellets
scatter on the water (light floaters), the koi are called to them
(`callKoi` at each pellet in turn), a pellet vanishes when a koi's head is
within 14 pt (gulp sound); `fedAt` saved.

**Toys.** Paper boat / sailing boat / leaf boat = light `Debris` with a
sail solid (bottle mesh reused as a mast? no: a new thin triangular solid
`SolidMesh.sail()`), wind and gusts push on the sail (`Garden.lean` force
along the wind), wakes and whirlpools move them as any floater. The tea
bowl fills from crests like the bamboo and empties when tilted by a big
wave. The floating lantern (gold) lights the water at dusk (a warm point
light in `water_fragment`: one extra `SIMD4` in `RenderParams`).

**Restful.** No goals, no status line, no hints after the first visit. The
season's air with weather and dusk; petals drifting; the koi you fed
coming to your finger; the boat turning in your gust.

## Ownership (gate 1)

- H Catalogue + reward data: NEW `Ripple/Garden/Catalogue.swift`,
  `Ripple/Garden/Inventory.swift` (in-memory + ProgressStore hooks written by
  J), the draw with pity, unit-testable with a seed.
- I Reward reveal: NEW `Ripple/Garden/RewardReveal.swift` + the calls in
  `GameController.finish()` and `Menus.swift` (a third word: Your pond).
  Sounds/haptics hooks in `SoundDirector`/`Haptics` (additions).
- J Plot: NEW `Ripple/Garden/PlotController.swift`, `DigField.swift`,
  `Tray.swift`, `Plot` model in `ProgressStore.swift`; `RootView`/`HubView`
  routing for the horizontal swipe (`HubController` gets a
  `onSwipeToPlot` closure only, set by HubView, since the art director owns
  HubController until it lands).
- Art (Recraft): `tray.png`, `spade.png`, `sluice_stone.png`, `food_bowl.png`,
  `pellet.png`, `paper_boat_1..2.png`, `sail_boat.png`, `lantern_float.png`,
  `tea_bowl.png`, `ring_light.png` (soft ring for the reveal), plus gate 2's
  catalogue art in batches by category.
- Sounds (Pixabay): reward chords (three tiers, a real instrument: koto or
  shakuhachi phrase), petal pick chime, digging in wet earth, water filling
  a hollow, pellets on water, a paper boat's rustle.
