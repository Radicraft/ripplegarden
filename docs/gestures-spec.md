# Water gestures and effects (owner, 2026-09-09 evening)

"Make sure lots of cool water gestures and effects are possible." Every
gesture must be driven by the real sim (a splat or a field of splats), never
a painted effect, and every one has a sound and a haptic.

Existing: tap (ring), hold (charged swell), two fingers together (swell
between them), drag along the bank (current), pinch (zoom), slide on ice
(haptic texture, scuff), tap on ice (crack / break).

## Add
1. FLICK / WAKE: a finger that moves on open water faster than 90 pt/s lays
   a wake: small splats every 6pt along the stroke (radius 5, amplitude
   -0.05 scaled by speed), which the sim turns into a travelling bow wave that
   shoves pieces along the stroke's direction. Currently a moving pond touch
   only moves a hold; a stroke faster than the threshold becomes a wake
   instead (the hold is cancelled). Sound: `sound.currentBegin/Level/End`
   style rushing water scaled by speed; haptic: `haptics.slide(speed:grain:travel:)`
   with grain 0.1 (glassy water).
2. STIR: a finger travelling in a circle (track the signed turning of the
   stroke; when the accumulated angle passes 1.5π within 1.5s) starts a
   WHIRLPOOL at the circle's centre: pieces within radius r (the circle's
   radius × 1.6) get a tangential velocity ω·r' (ω 1.2 rad/s at the rim,
   stronger inside) and a gentle inward pull, decaying with a 4s half-life
   after the finger lifts; the water shows it as a ring of small splats
   orbiting the centre each frame (8 per frame, radius 4, amplitude -0.03)
   so the sim draws the spiral. `Debris` integration gets a `vortex`
   term next to `current`. Sound: `amb_stream` looped at low gain and rate
   0.9 while it lasts; haptic: continuous slide at grain 0.2.
3. STONE DROP: a double tap (two taps within 0.3s and 30pt) is a stone
   dropped in: a big splat (radius 24, amplitude -0.5), a burst of 10-16
   DROPLETS (new `Droplet` particles in `Garden`: a `mote`-like sprite
   `drop.png` or the existing `mote` at 4-7pt, launched up 60-140 pt/s
   with gravity 400, that land 0.3-0.6s later as tiny splats), a deep
   `sound.holdRelease(charge: 1)` and `haptics.holdRelease(charge: 1)`.
4. DROPLETS everywhere a splash is big: `holdRelease` with charge > 0.5,
   the ice break, the hub dive, the frog: the same `Droplet` burst scaled.
5. BUBBLES under a hold: while a hold charges, small bubble sprites
   (`mote` tinted pale, 3-6pt) rise from the bed under the finger (2 per
   frame at charge > 0.3), popping at the surface with a tiny splat.
6. GUST: a quick two-finger swipe in the same direction (both fingers
   moving > 200 pt/s within 20° of each other) is a gust: a broad shallow
   wake across the pond in that direction (splats in a line across the
   whole width perpendicular to the direction, marching along it over 0.5s),
   petals in the air (Garden's petal emitter) blown that way, sound
   `fx_reeds` + `amb_autumn` swell, haptic `swell()`.

## Where
`GameController` touch handling (`touchBegan/Moved/Ended`, the `pondTouches`
and `edgeStrokes` state), `Debris.swift` (vortex term), `Garden.swift`
(`Droplet`, bubbles), `Haptics`/`SoundDirector` already have what is needed.
Keep the existing gestures exactly as they behave now; the new ones must not
steal a plain tap or a hold (thresholds above). Add each to the `-taps`
scripting so it can be checked headless: `-gestures "flick:0.3,0.5>0.7,0.5@4;stir:0.5,0.5@8;drop:0.5,0.6@12;gust:>@16"`.
