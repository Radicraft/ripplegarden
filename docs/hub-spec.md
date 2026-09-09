# The hub as water (owner, 2026-09-09)

"The level selection map should all be water, with plant life, different
types of fish (lots of small ones in groups), and other pond life. You sort
of splash into the levels as you progress DOWNWARDS not upwards through the
map. A natural watery path. All the menus a bit dynamic, watery."

## Shape
- One tall stream, four times the screen, running DOWN: winter at the top
  (the source, snow on the banks), spring, summer, autumn below. The player
  scrolls down as the year goes. The stream is the water renderer itself
  (`WaterRenderer` with `worldScale` tall instead of 1.4), so it ripples,
  reflects and lenses like a level, with the pitched camera looking down it.
- Levels are POOLS along the stream: a widening with a stone, a lily, a
  fallen branch marking it. A finished pool holds what you left there (the
  bloom stage, the opened bud). The next unfinished pool glows faintly with
  motes and its fish gather. Tapping a pool makes a splash and the camera
  drops INTO it: the water fills the screen and the level loads under the
  same surface (no cut; the level's sprites fade in under the ripples).
- Between seasons the stream narrows over a lip: a small fall with foam.
  Seasons to come lie below autumn under mist; the Seasons pass card sits
  on a rock there.

## Life (this is what makes it feel alive)
- SHOALS: 30-60 small fish (minnows, sticklebacks; new nihonga sprites,
  side/top view) in a boids flock: cohesion, alignment, separation, a
  wander target, and they scatter from a tap and from the koi. Two or three
  species with their own colour and size, each shoal its own.
- The koi from the levels drift through; newts, tadpoles and skaters; a
  dragonfly; reeds and irises on the banks; weeds in the shallows; clouds.
- Season dressing changes down the stream (branches, reed sets, palette).

## Menus, watery
- Cards (level complete, settings, store) float on the water: a paper card
  that tilts on the surface normal under it (the sprite relief path already
  does this), with a soft shadow, ripples passing under. Buttons are stones.
- Transitions are splashes: opening a card drops it in; dismissing lifts it
  out with drips. No standard sheets.

## Build order
1. `HubScene`: a second `GameController`-like driver (`HubController`) on the
   same renderer, world = 4 screens tall, pools as depth-map shallows,
   season palette blending down the stream, scroll = camera pan (touch drag
   vertical), taps ripple; pool hit test → splash → `onPlay`.
2. Shoals (`Shoal` in Garden, boids), new fish sprites (agent).
3. Pool markers + progress state on the pools; the fall between seasons.
4. Floating paper cards for the level-complete card first, then settings.
