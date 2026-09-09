# Menus are water (owner, 2026-09-09 evening)

"Menu system needs to look watery rather than paper." The washi cards are
superseded. A menu is not laid over the pond; it happens IN the pond.

## What it looks like
- The words are ink under the surface: label sprites drawn SUBMERGED
  (`Sprite(..., mode: .submerged, depth: 0.25...0.35, z: -0.3)`) so the
  water refracts them, ripples bend them and the caustics play over them.
  Pale ink (paper colour) reads best on the dark bed; use
  `LabelSprites.caption` (paper ink, soft shadow) and a new
  `LabelSprites.words(_:points:)` for body copy (multi-line, centred).
- Buttons are stones sitting in the water: `SolidInstance` shape 2 stones
  (the toon lumps that already exist), a pale stone for a quiet action, a
  dark one for the main action, with the word floating just above it as a
  small caption sprite (z 0.22). Pressing: a soft ring on the water
  (`addSplat`) and the stone dips (lift drops 6pt for 0.15s), then the action.
- Toggles are two stones side by side; the chosen one is dark. Rows: the
  setting's word to the left, under the water.
- Opening a menu: the water around darkens like a cloud passing
  (a renderer uniform `menuDim` 0...1 eased over 0.5s, applied in
  `water_fragment` as `col *= 1 - 0.45*menuDim` outside a soft ellipse
  around the menu, inside it only 0.15), every item rises from the deep
  (depth 0.95 → its rest depth over 0.6s with an ease-out, staggered 40ms
  per row) and a broad soft swell spreads from the menu's centre. Closing:
  the items sink back and the dim lifts. Tapping outside the menu closes it.
- Hints (`HintBubble`) become a single submerged line of words near the
  bottom that rises, waits, and sinks. The completion card becomes: the
  words "The pond is clear." rising under the surface, and two stones,
  "Garden" pale and "Next" dark.
- The hub's chips stay as they are (paper on water is fine for a label,
  the owner has not objected), but the settings and store on the hub use
  the same water menu.

## Where it lives
- `Ripple/Game/WaterMenu.swift`: `WaterMenu` (rows: `.title(String)`,
  `.words(String)`, `.toggle(String, get, set)`, `.buttons([(label, dark, action)])`),
  `open(at centre: CGPoint, world size)`, `close()`, `update(dt)`,
  `sprites(textures:) -> (submerged: [Sprite], surface: [Sprite], solids: [SolidInstance])`,
  `hit(_ point: CGPoint) -> Bool` (consumes the tap, runs an action or
  toggles; a tap outside closes), `isOpen`, `dim`.
- Both `GameController` and `HubController` own an optional `menu` and,
  when it is open, route `touchBegan/Ended` taps to it first, add its
  sprites/solids in their feed functions, and set `renderer.menuDim`.
- `LevelView` and `HubView` lose `PondOverlay`, `SettingsCard`, `StoreCard`,
  `CompletionCard`, `HintBubble` usage; the leaf button asks the controller
  to `openSettings()`; the store note on the hub asks `openStore()`;
  completion asks `showCompletion()`. Keep the `PaperUI.swift` code for the
  stone HUD buttons (back, leaf) only, delete the paper card views.
- Sound and haptics: opening = `sound.swell()` + `haptics.swell()`; a stone
  press = `sound.plop()` at the stone + `haptics.tap(weight: 0.5)`;
  closing = a soft `holdRelease(charge: 0.3)`.
