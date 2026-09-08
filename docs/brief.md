# Ripple Garden — Game Design Brief

## One-line pitch
A calm, gesture-driven puzzle game for iPhone: the whole screen is a pond. Clear away drifting debris with the right kind of ripple, and watch the garden bloom from winter into spring, summer, and autumn, one level at a time.

## Recommended build sequence
Don't one-shot the whole app immediately — build in three stages:
1. **Art direction mockups first.** Validate the ukiyo-e style, per-season palette, and bloom-state progression (see Art direction) before writing any game code. Get this signed off before it's baked into 24 levels' worth of assets.
2. **One complete, fully playable level.** Recommend Spring level 1 (simplest difficulty tier). Build it end-to-end: gestures, physics, sound, haptics, the mosaic reveal, and the full bloom transformation. This proves the feel is right before it's replicated 24 times.
3. **Once both are approved, one-shot the rest** — remaining levels, seasons, hub, and full app — using the validated art and level 1 as the template.

## Competitive landscape
The closest existing App Store titles — Zen Pond, Koi Pond, and Zen Koi — are either passive relaxation toys (drag your finger, watch koi swim, no objectives) or idle collection/breeding games. None combine ripple interaction with an actual level-based puzzle structure. "Ripple-based puzzle game" is currently an open lane worth leaning into for positioning and store copy.

## Platform & tech
- iPhone, native SwiftUI + SpriteKit
- SpriteKit physics fields (radial gravity/vortex/turbulence) drive ripple-object interaction
- Fully touch-based input — no motion sensor (Core Motion) dependency
- Art pipeline: Recraft-generated modular seasonal asset sets (see Art Direction)
- Save system: SwiftData with CloudKit sync — progress carries across a player's devices, no custom backend (same no-server approach as the SORTS and Inkline apps)

## Core mechanic: the water
The full screen is a body of water. It already responds to a basic tap-to-ripple. This brief extends that into a small, distinct gesture vocabulary — each gesture should *feel* different, not just be another way to make the same ripple:

| Gesture | Ripple type | Best for |
|---|---|---|
| Tap | Sharp, precise ripple | Small/light debris (petals, leaves) |
| Hold press | Slow-building, wide ripple | Heavy debris (stones, driftwood) needing sustained force |
| Multi-finger touch | Directional swell | Sweeping a whole cluster of debris at once |
| Edge-drag (on-screen) | Gentle ambient current | Slowly drifting loose objects toward or away from things over time |

All four gestures are touch-only — no device-tilt or motion-sensor requirement — and available from the start, with no gated tutorial unlocking. Players discover the vocabulary naturally through level design (see Onboarding).

## Debris vocabulary
Two weight classes, consistent across all seasons (only the visual skin changes per season):

| Class | Cleared by | Season-specific dressing |
|---|---|---|
| **Light** | A single tap, or a multi-finger sweep for a whole cluster at once | Petals/blossom (spring), fallen leaves (autumn), duckweed (summer), light snow (winter) |
| **Heavy** | A sustained hold-press; some pieces also need nudging into a specific spot via the edge-drag current first | Stones, driftwood, moss clumps (year-round); ice fragments that need melting via hold (winter) |

Later levels combine classes and introduce ordering (e.g. drag a heavy stone clear of a channel before a light cluster can be swept through it).

## Puzzle structure
- **Level-based**, not endless — bite-sized, curated levels
- **No move limit.** The puzzle is about finding the right technique (gesture, force, order, positioning), not managing a budget of moves
- **No fail state at all.** You can't lose — only keep experimenting with ripples until the level resolves. Retrying is always free and immediate; there's no "game over," no lost lives, no ad-gated retries. ("Soft fail" really just means *no* fail condition exists.)
- **Difficulty escalates via a mix of:**
  - Technique combos — some debris needs a specific gesture, or gesture sequence, to shift
  - Ambient current-drift (from the edge-drag gesture) interacting with the puzzle — solutions may need to account for slow drift, not just the immediate ripple
  - Spatial precision — some ripples need to land in a specific spot to work
  - These combine and escalate gradually across a chapter and across the game

## Win condition & the reveal
Clearing a level's debris feeds into a **bigger reveal**, working on two layers:
1. **Per-level micro-reveal:** clearing debris uncovers a piece of an ornamental mosaic/mandala pattern etched into the pond floor beneath — the small, tactile payoff every level
2. **Every-level bloom:** on completion, the garden itself transforms — visibly blossoming from its current seasonal state further into bloom (see Seasons below). This is a full transformation every level, not just at chapter milestones.

## Theme, setting, and structure: a year in the garden
- **Setting:** a zen garden pond — koi, lily pads, stones
- **Chapters = seasons.** Four chapters (winter → spring → summer → autumn), 6 levels each, for a total launch scope of **24 levels**
- Each season has its own shared, modular art/flower/tree asset library (generated in Recraft) — e.g. winter (snowdrops, melting ice), spring (cherry blossom, fresh green), summer (lotus, full lily pads), autumn (maple, golden light)
- Each level's bloom recombines elements from its season's shared library rather than needing fully bespoke art per level — keeps "every level blooms" achievable without 20–30 unique animations
- The full game arc is a year moving through the garden, restored season by season — giving a natural finale (full year complete, garden restored) rather than just "final level, the end"

## Fish
Koi (and other small pond life) surface during play. Tapping an emerged fish sends it back into hiding.
- **Ambient charm only** — no scoring, no fail-state tied to fish, purely a satisfying, optional interaction layered on top of the debris puzzle

## Onboarding
No explicit tutorial screens or instructional text as the primary teaching method. Instead:
- **Level design teaches technique** — e.g. an early level includes debris a simple tap can't budge, nudging the player toward holding; a later level needs two fingers to clear a wide cluster in time
- **Plus a subtle first-time hint/tooltip** — a light, dismissible nudge the first time a new technique would help, not a forced walkthrough

## Art direction
**Style: ukiyo-e / Japanese woodblock–inspired.** Bold flat colour fields, clean linework, stylised waves — think Hokusai's tranquillity rather than his drama. Deliberately distinct from the generic soft-painterly look common to calm/meditation apps, while still fitting Recraft's illustration generation well. Unifying ink-black linework (~#1B1B1B) across all seasons ties the style together.

- Art assets produced as modular pieces per season (ground, water, flora, fauna, debris types) rather than one-off bespoke scenes per level
- Bloom transformations are built from discrete art states (bare/frozen → budding → half-open → full bloom) cross-faded and scaled in SpriteKit, with light particle polish (drifting petals, pollen sparkle) — not hand-drawn frame animation

**Per-season palette & mosaic motif** (indicative, refine in Recraft):
| Season | Palette | Mosaic motif |
|---|---|---|
| Winter | Deep indigo, frost white | Wave-crest lines (Hokusai-style) |
| Spring | Soft blossom pink, moss green | Cherry-blossom roundel (mon) |
| Summer | Teal, warm gold | Koi/ripple mandala |
| Autumn | Amber, rust | Maple-leaf mon |

## Sound & haptics
Layered ambient nature audio as the bed (wind through reeds, distant birdsong), with the water itself as the main "instrument." Each gesture carries its own gentle tone — e.g. a soft plink for tap, a swelling chime for a held ripple — so the soundscape doubles as puzzle feedback. No combat stingers, no failure buzzers.

Each gesture also gets distinct haptic feedback (Core Haptics / UIFeedbackGenerator) matched to its tone — a light tap for the tap gesture, a building rumble for hold, a broader pulse for the multi-finger swell — reinforcing that each gesture *feels* different, not just sounds different.

## Level-select / hub, completion, and settings
- **Hub:** a garden path/map the player walks season by season — a literal path through the year's garden rather than a numbered grid. Tap a level node to open it; completed nodes show a small preview of their settled mosaic. Seasons beyond what's unlocked appear visibly further down the path but faded/dormant, consistent with the ongoing-content roadmap.
- **Level completion:** the mosaic tile settles into place, the bloom transformation plays out, a gentle chime sounds, then a simple "Next" button. No stars, no score, no ranking — consistent with the no-fail, no-move-limit philosophy.
- **Settings:** sound toggle, haptics toggle, restore purchases, about/credits. Deliberately minimal — nothing that interrupts the calm tone.

## Monetisation
Free to download. The full launch content — all 24 levels across the four founding seasons (winter/spring/summer/autumn) — is entirely free, no paywall on the base game.

**Subscription: monthly + annual.** Monthly at £2.49 for low-friction trial; annual at £19.99, framed as "save ~33% vs monthly" to do the actual retention work. Both unlock ongoing new content: additional seasons released over time, each bringing new levels, plus cosmetic extras (alternate art skins, ambient soundscapes). This gives the game a built-in content roadmap rather than a one-and-done release — architect level/season data so new seasons can be added post-launch without hardcoding a fixed count of four.

## Scope for v1 launch
24 levels: 6 per season × 4 founding seasons. Within each season, level 1 introduces that season's debris dressing at its simplest (single debris class, single gesture), ramping to level 6 combining both weight classes, multiple gestures, and ordering. Quality over quantity.

---

## Open items still to resolve
- App icon design
- Final Recraft-generated art (palette/motifs above are indicative starting points)

---

## Decisions taken during the build (2026-09-08)
- Art direction approved from the Recraft mockups in `Art/mockups/`. The whole screen is always water, with flora reaching in from the edges (the "Summer B" framing).
- No sounds at all for now (owner's call). The procedural synth stays in the code behind `SoundDirector.killSwitch`.
- The water stays the Metal height-field simulation from the prototype; SpriteKit is the transparent overlay for sprites and particles. Debris reads the water through GPU probes rather than SpriteKit physics fields, because the wave simulation already is the physics.
