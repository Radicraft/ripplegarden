import SwiftUI
import simd

/// One level in play. Owns the debris, decides what each touch means, feeds
/// the renderer its sprites, walls and silt covers every frame, and runs the
/// bloom when the tile is clean.
@MainActor
final class GameController: ObservableObject, TouchInput {

    enum Phase {
        case playing, celebrating, complete
    }

    @Published private(set) var phase: Phase = .playing
    @Published private(set) var hint: Hint?
    @Published private(set) var showTitle = false
    @Published private(set) var level: LevelSpec
    @Published private(set) var season: Season

    let style: WaterStyle
    let sound = SoundDirector()
    let haptics = Haptics()
    private let progress = ProgressStore.shared
    private var garden: Garden

    private weak var renderer: WaterRenderer?
    /// The world (the whole pond) in points. Bigger than the screen.
    private var viewSize = CGSize.zero
    private var screenSize = CGSize.zero
    // The view: zoom and centre, eased toward their targets so it flows.
    private var zoomTarget: Float = 0.9
    private var centreTarget = SIMD2<Float>(0, 0)
    private struct Pinch {
        var ids: [Int]
        var startDistance: CGFloat
        var startZoom: Float
        var anchorWorld: SIMD2<Float>
        var active = false
    }
    private var pinch: Pinch?
    private var screenTouches: [Int: CGPoint] = [:]
    private var art: ArtSet

    private(set) var debris: [Debris] = []
    /// The frozen sheet on winter levels, nil elsewhere.
    private(set) var iceField: IceField?

    /// A finger that came down on the sheet. It is neither a pond hold nor a
    /// splat: held still it does nothing, dragged it scuffs the frost and the
    /// hand feels the surface, lifted quickly it is a tap that breaks ice.
    private struct IceTouch {
        var began: TimeInterval
        var last: CGPoint          // screen
        var lastMoveAt: TimeInterval
        var travelled: CGFloat = 0
        var sinceStamp: CGFloat = 0
        var isSlide = false
        var speed: Float = 0
        var lastCrackDist: Float = 1e9
    }
    private var iceTouches: [Int: IceTouch] = [:]

    private var probeOrder: [(debris: Debris, probes: Int)] = []
    private var lastDebrisProbeCount = 0
    private var current = SIMD2<Float>(0, 0)
    private(set) var cleaned: Float = 0
    private var rocks: [(centre: CGPoint, radius: CGFloat)] = []
    /// Lily pads in world points: ripples stop at them, taps on them do nothing.
    private var pads: [(centre: CGPoint, radius: CGFloat, sprite: String)] = []
    /// Things a crest wakes.
    private var targets: [Target] = []
    private var targetProbeStart = 0

    private let diagnostics = ProcessInfo.processInfo.arguments.contains("-diag")
    private var diagFrames = 0
    private var diagHeavyLift: Float = 0
    private var elapsed: Float = 0
    private var touchedYet = false
    private var hintsShown: Set<Hint> = []
    private var lastProgressAt: Float = 0
    private var lastCleaned: Float = 0

    private struct EdgeStroke {
        var last: CGPoint
        var travelled: CGFloat = 0
        var isStroke = false
        var sinceHaptic: CGFloat = 0
    }
    private var edgeStrokes: [Int: EdgeStroke] = [:]
    private var pondTouches: [Int: Float] = [:]
    private var holdSounding: Set<Int> = []

    init(level: LevelSpec, style: WaterStyle) {
        self.level = level
        self.style = style
        let season = Library.season(for: level)
        self.season = season
        art = season.art(for: style)
        garden = Garden(art: art)
    }

    var siltRemaining: Float { renderer?.siltRemaining ?? 1 }
    var worldSize: CGSize? { viewSize == .zero ? nil : viewSize }

    // MARK: - Wiring

    /// Called from the path before the level screen appears.
    func prepare(level: LevelSpec) {
        self.level = level
        season = Library.season(for: level)
        art = season.art(for: style)
        phase = .playing
        if renderer != nil { load(level: level) }
    }

    func attach(renderer: WaterRenderer) {
        self.renderer = renderer
        renderer.style = style
        garden.textureSize = { [weak renderer] name in renderer?.textures.size(name) ?? CGSize(width: 1, height: 1) }
        renderer.onFrame = { [weak self] dt in self?.frame(dt: dt) }
        renderer.onChargedRelease = { [weak self] charge in
            guard let self else { return }
            self.sound.holdRelease(charge: charge)
            self.haptics.holdRelease(charge: charge)
        }
        renderer.onSwellStart = { [weak self] in
            self?.sound.swell()
            self?.haptics.swell()
        }
        load(level: level)
    }

    func load(level newLevel: LevelSpec) {
        level = newLevel
        season = Library.season(for: newLevel)
        art = season.art(for: style)
        phase = .playing
        elapsed = 0
        touchedYet = false
        hintsShown = []
        hint = nil
        current = .zero
        cleaned = 0
        lastCleaned = 0
        lastProgressAt = 0
        edgeStrokes.removeAll()
        pondTouches.removeAll()
        iceTouches.removeAll()
        holdSounding.removeAll()
        debris = []
        probeOrder = []

        var look = art.floor
        look.mosaicCentre = SIMD2(Float(newLevel.mosaicCentre.x), Float(newLevel.mosaicCentre.y))
        look.mosaicRadius = Float(newLevel.mosaicRadius)
        renderer?.floorLook = look
        renderer?.depthPainter = { [level = newLevel] w, h in DepthPainter.paint(level: level, width: w, height: h) }
        renderer?.rebuildDepth()
        renderer?.cancelAll()
        renderer?.reset()

        if viewSize != .zero { place() }

        showTitle = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            self?.showTitle = false
        }
        sound.startAmbience(root: season.rootNote)
    }

    private func place() {
        let spec = level
        let size = viewSize
        garden.depthAt = { p in
            DepthPainter.depth(at: CGPoint(x: p.x / size.width, y: p.y / size.height), level: spec, aspect: Float(size.width / size.height))
        }
        garden.configure(art: art, size: viewSize, bloomStage: progress.bloomStage(for: season.id))
        rocks = level.rocks.map { (CGPoint(x: $0.centre.x * viewSize.width, y: $0.centre.y * viewSize.height),
                                   $0.radius * viewSize.height) }
        garden.rocks = rocks
        pads = level.pads.enumerated().map { i, p in
            (CGPoint(x: p.centre.x * viewSize.width, y: p.centre.y * viewSize.height), p.radius * viewSize.height,
             ["lilypad_1", "lilypad_2", "lilypad_3"][i % 3])
        }
        targets = level.targets.map { Target(spec: $0, position: CGPoint(x: $0.at.x * viewSize.width, y: $0.at.y * viewSize.height)) }
        debris = level.debris.enumerated().map { i, p in
            if let rubbish = p.kind.sprite {
                let d = Debris(id: i, cls: p.cls, sprite: rubbish,
                               position: CGPoint(x: p.at.x * viewSize.width, y: p.at.y * viewSize.height),
                               radius: p.kind.radius * p.scale, scale: p.scale, kind: p.kind)
                d.angle = CGFloat(p.rotation)
                return d
            }
            let name: String
            let radius: CGFloat
            switch p.cls {
            case .light:
                name = art.light[p.variant % art.light.count]
                radius = 15 * p.scale
            case .heavy:
                name = art.heavy[p.variant % art.heavy.count]
                radius = 40 * p.scale
            }
            let d = Debris(id: i, cls: p.cls, sprite: name,
                           position: CGPoint(x: p.at.x * viewSize.width, y: p.at.y * viewSize.height),
                           radius: radius, scale: p.scale)
            if p.cls == .heavy { d.angle = CGFloat(p.rotation) }
            return d
        }
        iceField = level.frozen ? IceField(world: viewSize) : nil
        garden.iceCover = level.frozen ? 1 : 0
        if let f = iceField {
            renderer?.setIce(f.cells, scuff: f.scuff, width: f.width, height: f.height)
            renderer?.setIceCracks(seeds: f.seeds, strikes: f.strikes)
            f.markCracksClean()
            f.markClean()
        } else {
            renderer?.setIce(nil, width: 0, height: 0)
            renderer?.setIceCracks(seeds: [], strikes: [])
        }
    }

    /// A tap on the sheet. Fresh ice takes the blow as a ring of shards, the
    /// cracks racing out from the point. A second tap anywhere inside that
    /// ring takes the whole of it out at once. Ice within a finger's width of
    /// open water is already weak: it gives way on the first tap, in a small
    /// bite. Returns true if the tap was on ice.
    @discardableResult
    private func tapIce(at point: CGPoint) -> Bool {
        guard let field = iceField, field.ice(at: point) > 0.5 else { return false }
        let now = renderer?.clock ?? 0
        if let index = field.strikeIndex(containing: point) {
            afterBreak(at: point, shards: field.breakOut(index, time: now))
        } else if let area = field.sinkIsland(at: point, maxArea: 30000, time: now) {
            // A scrap already cut off from the sheet goes under whole.
            afterBreak(at: point, shards: [(point, area)])
        } else if field.isEdge(at: point, within: 46) {
            let index = field.strike(at: point, ring: CGFloat.random(in: 90...150), time: now)
            afterBreak(at: point, shards: field.breakOut(index, time: now))
        } else {
            field.strike(at: point, ring: CGFloat.random(in: 110...190), time: now)
            haptics.iceStrike()
            renderer?.addSplat(at: point, in: viewSize, radius: 6, amplitude: -0.04)
        }
        return true
    }

    /// The splash, the chunks and the bookkeeping after a piece of the sheet
    /// gives way: one floating chunk per shard, sized to the shard it was.
    private func afterBreak(at point: CGPoint, shards: [(centre: CGPoint, area: CGFloat)]) {
        guard let field = iceField, !shards.isEmpty else { return }
        let total = shards.reduce(CGFloat(0)) { $0 + $1.area }
        haptics.iceBreak(size: Float(min(1, total / 60000)))
        renderer?.addSplat(at: point, in: viewSize, radius: 22, amplitude: -0.45)
        // The shards themselves tip under the water; what floats afterwards
        // is a few pieces broken off the biggest of them, no two alike: a
        // different cut-out each, turned any way, from a sliver to a slab.
        let big = shards.filter { $0.area > 2500 }.sorted { $0.area > $1.area }.prefix(5)
        var used: [String] = []
        for shard in big {
            let dx = shard.centre.x - point.x, dy = shard.centre.y - point.y
            let len = max(1, hypot(dx, dy))
            let fresh = art.iceFragments.filter { !used.contains($0) }
            let name = (fresh.isEmpty ? art.iceFragments : fresh).randomElement() ?? "ice_1"
            used.append(name)
            let radius = min(30, max(8, sqrt(shard.area / .pi) * CGFloat.random(in: 0.2...0.5)))
            let d = Debris(id: 3000 + Int.random(in: 0...99999), cls: .light,
                           sprite: name, position: shard.centre, radius: radius, scale: 1)
            d.angle = CGFloat.random(in: 0...(2 * .pi))
            d.spin = CGFloat.random(in: -0.3...0.3)
            d.velocity = SIMD2(Float(dx / len), Float(dy / len)) * Float.random(in: 4...12)
            let life = Float.random(in: 22...36)
            d.meltsIn = life
            d.meltTotal = life
            debris.append(d)
        }
        garden.iceCover = field.fraction
    }

    /// A tap in open water near the sheet: the wave reaches the edge and
    /// bites a small piece off it.
    private func waveBitesIce(from point: CGPoint) {
        guard let field = iceField, let edge = field.nearestIce(to: point, range: 220) else { return }
        let dx = edge.x - point.x, dy = edge.y - point.y
        let len = max(1, hypot(dx, dy))
        let inward = CGPoint(x: edge.x + dx / len * 12, y: edge.y + dy / len * 12)
        guard field.ice(at: inward) > 0.5 else { return }
        let index = field.strike(at: inward, ring: CGFloat.random(in: 50...90), time: renderer?.clock ?? 0)
        afterBreak(at: point, shards: field.breakOut(index, time: renderer?.clock ?? 0))
    }

    // MARK: - Per frame

    private func frame(dt: Float) {
        guard let renderer else { return }
        elapsed += dt
        let now = CACurrentMediaTime()

        if viewSize == .zero, let world = renderer.worldSizePoints, let screen = renderer.viewSizePoints, world.width > 0 {
            viewSize = world
            screenSize = screen
            centreTarget = SIMD2(Float(world.width) / 2, Float(world.height) / 2)
            renderer.viewCentre = centreTarget
            place()
        }
        guard viewSize != .zero else { return }

        // Ease the view toward where the fingers want it, and keep it on the pond.
        renderer.zoom += (zoomTarget - renderer.zoom) * min(1, dt * 8)
        let halfW = Float(screenSize.width) / renderer.zoom / 2, halfH = Float(screenSize.height) / renderer.zoom / 2
        centreTarget.x = max(halfW, min(Float(viewSize.width) - halfW, centreTarget.x))
        centreTarget.y = max(halfH, min(Float(viewSize.height) - halfH, centreTarget.y))
        renderer.viewCentre += (centreTarget - renderer.viewCentre) * min(1, dt * 8)

        if simd_length(current) > 0.01 {
            current *= exp(-dt * log(2) / GameTuning.currentHalfLife)
        }

        // A light piece reads the water at one point. A heavy one reads three
        // along its length and averages: a tap's short ring lifts one end and
        // cancels out, a held swell's long wave lifts the whole log.
        let samples = renderer.latestSamples()
        var byID: [Int: FieldSample] = [:]
        var cursor = 0
        for entry in probeOrder {
            let n = entry.probes
            guard cursor + n <= samples.count else { break }
            var h: Float = 0, v: Float = 0, slope = SIMD2<Float>(0, 0)
            for k in 0..<n {
                h += samples[cursor + k].height
                v += samples[cursor + k].velocity
                slope += samples[cursor + k].slope
            }
            byID[entry.debris.id] = FieldSample(height: h / Float(n), slope: slope / Float(n), velocity: v / Float(n))
            cursor += n
        }

        iceField?.settle(clock: renderer.clock)
        if let f = iceField, f.dirty {
            renderer.setIce(f.cells, scuff: f.scuff, width: f.width, height: f.height)
            // A scuffed streak of frost does not move a crack: the field is
            // only re-baked when the diagram itself has changed.
            if f.cracksDirty {
                renderer.setIceCracks(seeds: f.seeds, strikes: f.strikes)
                f.markCracksClean()
            }
            f.markClean()
        }
        if phase == .playing {
            for d in debris where !d.cleared {
                DebrisPhysics.integrate(d, sample: byID[d.id], current: current, dt: dt)
                keepOffRocks(d)
                if let m = d.meltsIn {
                    d.meltsIn = m - dt
                    d.fade = min(1, max(0, m / max(1, d.meltTotal)) * 1.6)
                    if m <= 0 { d.cleared = true }
                }
            }
            DebrisPhysics.separate(debris, dt: dt)
            for d in debris where !d.cleared && DebrisPhysics.hasReachedShore(d, in: viewSize) {
                clear(d)
            }
        }

        // The garden lives regardless of the puzzle.
        garden.update(dt: dt, now: now)
        for s in garden.splashes { renderer.addSplat(at: s.at, in: viewSize, radius: s.radius, amplitude: s.amplitude) }
        garden.splashes.removeAll()

        // Silt progress.
        cleaned = 1 - renderer.siltRemaining
        if cleaned > lastCleaned + 0.005 {
            lastCleaned = cleaned
            lastProgressAt = elapsed
        }
        // Done when the pond is tidy: nothing left floating on it, no ice.
        // (Levels with a roundel also want it washed and clear of heavy pieces.)
        if phase == .playing {
            let tidy = debris.allSatisfy(\.cleared) && (iceField.map { $0.fraction < 0.06 } ?? true)
                && targets.allSatisfy(\.woke)
            if level.mosaicRadius <= 0 ? tidy : (cleaned >= 0.94 && heavyOverTile().isEmpty) { finish() }
        }

        // Feed the renderer.
        feedRenderer(renderer)

        // Weed tips read the water too; their samples ride at the end of the
        // probe list, after the debris.
        for (i, t) in targets.enumerated() where targetProbeStart + i < samples.count {
            let h = samples[targetProbeStart + i].height
            t.peak = max(t.peak, h)
            if !t.woke, h > t.spec.threshold {
                t.woke = true
                t.wokeAt = elapsed
                haptics.plop()
                renderer.addSplat(at: t.position, in: viewSize, radius: 14, amplitude: -0.08)
                if diagnostics { NSLog("[target] woke at h=%.3f (threshold %.3f)", h, t.spec.threshold) }
            }
            if diagnostics, diagFrames % 120 == 0 { NSLog("[target] peak so far %.3f", t.peak) }
            t.opening = t.woke ? min(1, (elapsed - t.wokeAt) / 2.2) : 0
        }

        let weedTips = garden.weedTips()
        let debrisProbeCount = lastDebrisProbeCount
        var weedSamples: [Int: FieldSample] = [:]
        for (i, _) in weedTips.enumerated() where debrisProbeCount + i < samples.count {
            weedSamples[i] = samples[debrisProbeCount + i]
        }
        garden.weedSamples = weedSamples

        probeOrder = debris.filter { !$0.cleared }.map { ($0, $0.cls == .heavy ? 3 : 1) }
        var cells: [SIMD2<Float>] = []
        for entry in probeOrder {
            let d = entry.debris
            if entry.probes == 1 {
                if let c = renderer.cell(for: d.position, in: viewSize) { cells.append(c) }
            } else {
                let along = CGVector(dx: cos(d.angle) * d.radius * 0.7, dy: sin(d.angle) * d.radius * 0.7)
                for t: CGFloat in [-1, 0, 1] {
                    let p = CGPoint(x: d.position.x + along.dx * t, y: d.position.y + along.dy * t)
                    if let c = renderer.cell(for: p, in: viewSize) { cells.append(c) }
                }
            }
        }
        targetProbeStart = cells.count
        for t in targets {
            if let c = renderer.cell(for: t.position, in: viewSize) { cells.append(c) }
        }
        lastDebrisProbeCount = cells.count
        for tip in weedTips {
            if let c = renderer.cell(for: tip, in: viewSize) { cells.append(c) }
        }
        renderer.setProbes(cells)

        for (id, held) in pondTouches {
            pondTouches[id] = held + dt
            let charge = renderer.charge(of: id)
            if charge > 0.12, held + dt > GameTuning.holdSoundAfter, !holdSounding.contains(id) {
                holdSounding.insert(id)
                sound.holdBegin(id: id)
                haptics.holdBegin()
            }
            if holdSounding.contains(id) { sound.holdLevel(id: id, charge: charge) }
        }

        updateHints()

        if diagnostics {
            diagFrames += 1
            for d in debris where d.cls == .heavy {
                if let s = byID[d.id] { diagHeavyLift = max(diagHeavyLift, abs(s.height)) }
            }
            if diagFrames % 60 == 0 {
                let heavy = debris.first { $0.cls == .heavy }
                NSLog("[garden] ice=%.3f targets=%d/%d debris=%d heavyLift=%.3f heavyPos=(%.0f,%.0f) phase=%@",
                      iceField?.fraction ?? 0, targets.filter(\.woke).count, targets.count, probeOrder.count, diagHeavyLift,
                      heavy?.position.x ?? 0, heavy?.position.y ?? 0, String(describing: phase))
                diagHeavyLift = 0
            }
        }
    }

    private func feedRenderer(_ renderer: WaterRenderer) {
        let w = Float(viewSize.width), h = Float(viewSize.height)

        // Walls: rocks are in the static depth map; heavy floaters move; ice
        // plates damp the water under them and turn ripples at their edges.
        renderer.walls = debris.filter { !$0.cleared && $0.cls == .heavy }.map { ($0.position, $0.radius * 0.8) }

        // Silt covers: anything sitting over the tile shades it.
        renderer.siltCovers = debris.filter { !$0.cleared }.map {
            SIMD4(Float($0.position.x) / w, Float($0.position.y) / h, Float($0.radius) / h * ($0.cls == .heavy ? 0.95 : 0.8), 0)
        }

        renderer.camera = garden.camera

        // Sprites. Under the water: weeds, cloud shadows, tadpoles, koi, plus
        // every floater's shadow on the floor.
        let submerged = garden.submergedSprites()
        renderer.spines = submerged.spines
        var under = submerged.sprites
        under += garden.reflectionSprites()
        for d in debris where !d.cleared {
            let s = spriteSize(d)
            under.append(Sprite(d.sprite, at: CGPoint(x: d.position.x + 7, y: d.position.y + 10), size: s,
                                rotation: Float(d.angle), mode: .shadow, alpha: d.cls == .heavy ? 0.9 : 0.6, z: -1.0))
        }
        for r in rocks {
            let side = r.radius * 2.3
            under.append(Sprite(art.rock, at: CGPoint(x: r.centre.x + 6, y: r.centre.y + 9),
                                size: CGSize(width: side, height: side * rockAspect), mode: .shadow, alpha: 0.55, z: -1.0))
        }
        renderer.submergedSprites = under

        // On the water: rocks, debris, blossom, then the flora frame on top.
        // Every piece is cut paper: a dark thickness edge sits just under it,
        // and things held above the water throw a soft shadow down onto it.
        var over: [Sprite] = []
        func paper(_ s: Sprite, cast: CGFloat = 0) {
            if cast > 0 {
                var sh = s
                sh.gpu.center += SIMD2(Float(cast * 0.7), Float(cast))
                sh.gpu.mode = SpriteInstance.Mode.shadow.rawValue | (s.gpu.mode & SpriteInstance.flipX)
                sh.gpu.alpha = s.gpu.alpha * 0.8
                over.append(sh)
            }
            var edge = s
            edge.gpu.center += SIMD2(2.2, 3.0)
            edge.gpu.mode = s.gpu.mode | SpriteInstance.ink
            over.append(edge)
            over.append(s)
        }
        // Rubbish and stone that is a body is not cut paper: it goes through
        // the solids pass, and only its shadows are sprites.
        var shadows: [Sprite] = []
        var solids: [SolidInstance] = []
        // A stone in the bed is a body, sat low in the water. Nothing of it
        // is drawn flat any more; only its shadow on the floor stays.
        for r in rocks {
            solids.append(stone(at: r.centre, radius: r.radius, sprite: art.rock, tilt: .zero, alpha: 1))
        }
        for p in pads {
            let side = p.radius * 2.2
            over.append(Sprite(p.sprite, at: CGPoint(x: p.centre.x + 3, y: p.centre.y + 4),
                               size: CGSize(width: side * 1.06, height: side * 1.06), mode: .shadow, alpha: 0.3, z: 0))
            paper(Sprite(p.sprite, at: p.centre, size: CGSize(width: side, height: side), rotation: Float(p.centre.x * 0.01), mode: .floater, alpha: 1))
        }
        for t in targets {
            let side: CGFloat = 92
            switch t.spec.kind {
            case .bud:
                if t.opening < 1 { paper(Sprite("bud_closed", at: t.position, size: CGSize(width: side, height: side), mode: .floater, alpha: 1 - t.opening)) }
                if t.opening > 0 { paper(Sprite("bud_open", at: t.position, size: CGSize(width: side, height: side), mode: .floater, alpha: t.opening)) }
            case .bell:
                let since = Double(elapsed - t.wokeAt)
                let swing = t.woke ? CGFloat(sin(since * 14) * exp(-since * 1.5)) * 0.25 : 0
                paper(Sprite("bell_float", at: t.position, size: CGSize(width: side, height: side), rotation: Float(swing), mode: .floater, alpha: 1))
            }
        }
        for d in debris where !d.cleared {
            let s = spriteSize(d)
            let melt = d.meltsIn.map { CGFloat(max(0.35, $0 / max(1, d.meltTotal))) } ?? 1
            guard let body = d.solid else {
                paper(Sprite(d.sprite, at: d.position, size: CGSize(width: s.width * melt, height: s.height * melt),
                             rotation: Float(d.angle), mode: .floater, alpha: d.fade))
                continue
            }
            if body.shape == 2 {
                // A drifting stone, seeded off the piece so its lumps stay
                // its own as it moves.
                solids.append(stone(at: d.position, radius: d.radius, sprite: d.sprite,
                                    tilt: d.slope, alpha: d.fade, seed: Float(d.id) * 7.3 + 1.9, yaw: Float(d.angle)))
                continue
            }
            // A soft ring where the body meets the water. Rubbish only: a log
            // and a stone already have their shadow on the floor, and a
            // second dark patch is what made them read as pasted cut-outs.
            if d.kind.isRubbish {
                shadows.append(Sprite(d.sprite, at: CGPoint(x: d.position.x + 3, y: d.position.y + 5),
                                      size: CGSize(width: s.width * 1.1, height: s.height * 1.1),
                                      rotation: Float(d.angle), mode: .shadow, alpha: 0.34 * d.fade, z: 0))
            }
            let radius = Float(d.radius * body.radius)
            let natural = d.kind.isRubbish ? nil : solidColours(d.sprite)
            solids.append(SolidInstance(position: SIMD2(Float(d.position.x), Float(d.position.y)),
                                        lift: radius * Float(body.lift),
                                        yaw: Float(d.angle),
                                        roll: d.roll,
                                        tilt: d.slope,
                                        length: Float(d.radius * body.length),
                                        radius: radius,
                                        shape: body.shape,
                                        alpha: d.fade,
                                        colourA: natural?.a ?? (d.kind == .can ? [0.86, 0.16, 0.14, 1] : [0.72, 0.86, 0.92, 1]),
                                        colourB: natural?.b ?? (d.kind == .can ? [0.93, 0.93, 0.95, 1] : [0.18, 0.42, 0.72, 1])))
        }
        renderer.contactShadows = shadows
        renderer.solids = solids
        for s in garden.skaterSprites() { paper(s) }
        for s in garden.petalSprites() { paper(s) }
        for s in garden.floraSprites() { paper(s, cast: s.texture == art.bank ? 0 : 18) }
        over += garden.skySprites()
        renderer.surfaceSprites = over
    }

    /// A stone body in place of a cut-out. One in the bed lays out the same
    /// every run: the point it sits at decides which way it lies and which
    /// lumps it has. A drifting one keeps its own lumps and turns as it goes.
    private func stone(at p: CGPoint, radius: CGFloat, sprite: String, tilt: SIMD2<Float>,
                       alpha: Float, seed: Float? = nil, yaw: Float? = nil) -> SolidInstance {
        let body = NaturalSolid.stone.body
        let r = Float(radius * body.radius)
        let colours = solidColours(sprite)
        return SolidInstance(position: SIMD2(Float(p.x), Float(p.y)),
                             lift: r * Float(body.lift),
                             yaw: yaw ?? placementHash(p, salt: 1) * 2 * .pi,
                             roll: seed ?? placementHash(p, salt: 2) * 64,
                             tilt: tilt,
                             length: Float(radius * body.length),
                             radius: r,
                             shape: body.shape,
                             alpha: alpha,
                             colourA: colours.a,
                             colourB: colours.b)
    }

    /// What a natural body is coloured. Winter's stones are a colder grey and
    /// wear no moss; a bare stone takes the same grey twice, so the moss the
    /// shader lays on the upper side of it changes nothing.
    private func solidColours(_ sprite: String) -> (a: SIMD4<Float>, b: SIMD4<Float>) {
        let kind = NaturalSolid.forSprite(sprite)
        if kind == .log { return ([0.42, 0.30, 0.20, 1], [0.78, 0.66, 0.48, 1]) }
        if season.id == "winter" {
            let grey: SIMD4<Float> = [0.62, 0.66, 0.72, 1]
            return (grey, grey)
        }
        if kind == .mossyStone { return ([0.50, 0.53, 0.52, 1], [0.36, 0.55, 0.30, 1]) }
        let grey: SIMD4<Float> = [0.56, 0.58, 0.60, 1]
        return (grey, grey)
    }

    /// A steady number from a point, so what it decides does not change from
    /// one run to the next.
    private func placementHash(_ p: CGPoint, salt: UInt32) -> Float {
        var x = UInt32(truncatingIfNeeded: Int(p.x * 8)) &* 73856093
        x ^= UInt32(truncatingIfNeeded: Int(p.y * 8)) &* 19349663
        x ^= salt &* 83492791
        x = (x ^ (x >> 13)) &* 1274126177
        return Float((x ^ (x >> 16)) & 0xFFFF) / 65535
    }

    private var rockAspect: CGFloat {
        let s = renderer?.textures.size(art.rock) ?? CGSize(width: 1, height: 1)
        return s.height / max(1, s.width)
    }

    private func spriteSize(_ d: Debris) -> CGSize {
        let s = renderer?.textures.size(d.sprite) ?? CGSize(width: 1, height: 1)
        let long = max(s.width, s.height)
        let side = d.radius * 2
        return CGSize(width: side * s.width / long, height: side * s.height / long)
    }

    /// Floaters cannot pass through a rock.
    private func keepOffRocks(_ d: Debris) {
        for r in rocks {
            let dx = Float(d.position.x - r.centre.x), dy = Float(d.position.y - r.centre.y)
            let dist = max(0.001, (dx * dx + dy * dy).squareRoot())
            let minDist = Float(r.radius * 0.95 + d.radius * 0.6)
            guard dist < minDist else { continue }
            let n = SIMD2(dx, dy) / dist
            d.position.x = r.centre.x + CGFloat(n.x * minDist)
            d.position.y = r.centre.y + CGFloat(n.y * minDist)
            let into = simd_dot(d.velocity, n)
            if into < 0 { d.velocity -= n * into * 1.4 }
        }
    }

    private func heavyOverTile() -> [Debris] {
        let c = CGPoint(x: level.mosaicCentre.x * viewSize.width, y: level.mosaicCentre.y * viewSize.height)
        let r = level.mosaicRadius * viewSize.height
        return debris.filter { !$0.cleared && $0.cls == .heavy && hypot($0.position.x - c.x, $0.position.y - c.y) < r + $0.radius * 0.5 }
    }

    // MARK: - Hints

    private func show(_ h: Hint) {
        guard !hintsShown.contains(h), !HintMemory.seen(h), hint == nil else { return }
        hintsShown.insert(h)
        withAnimation(.spring(duration: 0.6)) { hint = h }
    }

    private func updateHints() {
        guard phase == .playing else { return }
        if let h = level.hint, !touchedYet, elapsed > 4.0 { show(h) }
        if level.hint == .ice, touchedYet, let f = iceField, f.fraction > 0.97, elapsed > 12 { show(.ice) }
        // The tile is mostly clean but a heavy piece still shades it, and the
        // player has stalled: they need the hold.
        if cleaned > 0.45, !heavyOverTile().isEmpty, elapsed - lastProgressAt > 7 { show(.hold) }
    }

    private func dismissHint() {
        if let h = hint {
            HintMemory.markSeen(h)
            withAnimation(.easeOut(duration: 0.35)) { hint = nil }
        }
    }

    // MARK: - Touches

    /// Screen point to world point through the current view.
    /// Pull back until the whole pond is on screen (the demo uses it on
    /// frozen levels, where the sheet runs beyond the default view).
    func showWholePond() {
        let scale = renderer?.worldScale ?? CGSize(width: 1.4, height: 1.4)
        zoomTarget = Float(1 / max(scale.width, scale.height))
    }

    func worldPoint(_ p: CGPoint) -> CGPoint {
        renderer?.worldPoint(screen: p) ?? p
    }

    /// World point to screen point.
    func screenPoint(_ w: CGPoint) -> CGPoint {
        renderer?.screenPoint(world: w) ?? w
    }

    var currentZoom: Float { renderer?.zoom ?? 1 }

    private func isOnEdge(_ p: CGPoint, in size: CGSize) -> Bool {
        let b = GameTuning.edgeBand
        return p.x < b || p.y < b || p.x > size.width - b || p.y > size.height - b
    }

    /// Two fingers: a swell if they move together, a pinch if they spread or
    /// close. Once a pinch is decided the water stops hearing those fingers.
    private func updatePinch(moved id: Int) {
        guard var p = pinch, p.ids.contains(id),
              let a = screenTouches[p.ids[0]], let b = screenTouches[p.ids[1]], let r = renderer else { return }
        let dist = hypot(a.x - b.x, a.y - b.y)
        if !p.active {
            guard abs(dist - p.startDistance) > 18 else { return }
            p.active = true
            r.cancelAll()
            for pid in p.ids { pondTouches.removeValue(forKey: pid); if holdSounding.remove(pid) != nil { sound.holdEnd(id: pid) } }
        }
        let z = max(0.8, min(1.8, p.startZoom * Float(dist / max(1, p.startDistance))))
        zoomTarget = z
        // Keep the world point that was under the fingers under them.
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        centreTarget = p.anchorWorld - SIMD2(Float(mid.x - screenSize.width / 2), Float(mid.y - screenSize.height / 2)) / z
        pinch = p
    }

    func touchBegan(id: Int, at screen: CGPoint, in screenBounds: CGSize, weight: Float) {
        screenSize = screenBounds
        touchedYet = true
        dismissHint()
        guard phase == .playing || phase == .celebrating, viewSize != .zero else { return }
        screenTouches[id] = screen
        let point = worldPoint(screen)
        let size = viewSize

        if isOnEdge(screen, in: screenBounds) {
            edgeStrokes[id] = EdgeStroke(last: screen)
            return
        }
        // A second finger on the pond or on the sheet may be a pinch.
        let pondIDs = (Array(pondTouches.keys) + Array(iceTouches.keys)).filter { screenTouches[$0] != nil && $0 != id }
        if pinch == nil, let other = pondIDs.first, let op = screenTouches[other], let r = renderer {
            let mid = CGPoint(x: (op.x + screen.x) / 2, y: (op.y + screen.y) / 2)
            let anchor = worldPoint(mid)
            pinch = Pinch(ids: [other, id], startDistance: hypot(op.x - screen.x, op.y - screen.y),
                          startZoom: r.zoom, anchorWorld: SIMD2(Float(anchor.x), Float(anchor.y)))
        }
        // A finger that lands on the sheet belongs to the ice: no ring, no
        // hold, no splat. What it means is decided when it moves or lifts.
        if let field = iceField, field.ice(at: point) > 0.5 {
            let now = CACurrentMediaTime()
            iceTouches[id] = IceTouch(began: now, last: screen, lastMoveAt: now)
            return
        }
        // A finger on a lily pad presses a leaf, not the water; a finger on
        // a log or a can lands on the thing itself, and the water under it
        // is not where the ring starts. Otherwise a tap on a heavy piece
        // would lift it from beneath, which no ripple ever could.
        if pads.contains(where: { hypot($0.centre.x - point.x, $0.centre.y - point.y) < $0.radius * 1.05 }) {
            haptics.tap(weight: 0.2)
            return
        }
        if debris.contains(where: { !$0.cleared && $0.cls == .heavy && hypot($0.position.x - point.x, $0.position.y - point.y) < $0.radius * 0.9 }) {
            haptics.plop()
            return
        }
        waveBitesIce(from: point)
        garden.startle(at: point, in: size)
        if let k = garden.koiHit(at: point) {
            garden.dive(k)
            sound.plop()
            haptics.plop()
        }
        renderer?.touchDown(id: id, at: point, in: size, weight: weight)
        pondTouches[id] = 0
        sound.tap(x: Float(point.x / size.width), weight: weight)
        haptics.tap(weight: weight)
    }

    func touchMoved(id: Int, to screen: CGPoint, in screenBounds: CGSize) {
        screenTouches[id] = screen
        if pinch != nil {
            updatePinch(moved: id)
            // A finger that turned out to be half a pinch is no longer on the ice.
            if pinch?.active == true {
                if let t = iceTouches.removeValue(forKey: id), t.isSlide { haptics.slideEnd() }
                return
            }
        }
        let point = worldPoint(screen)
        let size = viewSize
        if iceTouches[id] != nil { slideIce(id: id, to: screen, world: point); return }
        if var stroke = edgeStrokes[id] {
            let dx = screen.x - stroke.last.x, dy = screen.y - stroke.last.y
            let dist = hypot(dx, dy)
            stroke.travelled += dist
            stroke.sinceHaptic += dist
            if !stroke.isStroke, stroke.travelled > GameTuning.edgeStrokeMinTravel {
                stroke.isStroke = true
                sound.currentBegin(id: id)
            }
            if stroke.isStroke, dist > 0 {
                let gain = GameTuning.currentGainPerPoint * Float(dist)
                current += SIMD2(Float(dx), Float(dy)) / Float(dist) * gain
                let mag = simd_length(current)
                if mag > GameTuning.currentMax { current *= GameTuning.currentMax / mag }
                sound.currentLevel(id: id, strength: mag / GameTuning.currentMax)
                renderer?.addSplat(at: point, in: size, radius: 9, amplitude: -0.07)
                if stroke.sinceHaptic > 36 {
                    stroke.sinceHaptic = 0
                    haptics.currentTick()
                }
            }
            stroke.last = screen
            edgeStrokes[id] = stroke
            return
        }
        renderer?.touchMoved(id: id, to: point, in: size)
    }

    /// A finger dragged over the sheet. Past ten points of travel, or a third
    /// of a second, it is a slide: the surface answers under the hand, the
    /// frost wipes off where it passes, and every crack it crosses clicks.
    /// A slide never breaks the ice.
    private func slideIce(id: Int, to screen: CGPoint, world point: CGPoint) {
        guard var t = iceTouches[id], let field = iceField else { iceTouches.removeValue(forKey: id); return }
        let now = CACurrentMediaTime()
        let step = hypot(screen.x - t.last.x, screen.y - t.last.y)
        t.travelled += step
        if !t.isSlide, t.travelled > 10 || now - t.began > 0.28 {
            t.isSlide = true
            haptics.slideBegin()
            t.lastCrackDist = field.crack(at: point).dist
        }
        if t.isSlide {
            let dt = max(1.0 / 240, now - t.lastMoveAt)
            let instant = Float(step / CGFloat(dt))
            t.speed += (instant - t.speed) * 0.35
            // Ice already wiped feels glassy; frost is grainy.
            let grain = max(0, 1 - field.scuffValue(at: point) * 0.8)
            haptics.slide(speed: t.speed, grain: grain, travel: Float(step))
            t.sinceStamp += step
            if t.sinceStamp >= 4 {
                t.sinceStamp = 0
                field.paintScuff(at: point, radius: 13, amount: 0.35)
            }
            let crossed = field.crack(at: point)
            if t.lastCrackDist > 3, crossed.dist <= 3 { haptics.slideCrack(strength: crossed.strength) }
            t.lastCrackDist = crossed.dist
            // Off the edge of the sheet: the slide is spent, and nothing broke.
            if field.ice(at: point) < 0.5 {
                haptics.slideEnd()
                iceTouches.removeValue(forKey: id)
                return
            }
        }
        t.last = screen
        t.lastMoveAt = now
        iceTouches[id] = t
    }

    func touchEnded(id: Int, at screen: CGPoint, in screenBounds: CGSize) {
        screenTouches.removeValue(forKey: id)
        if let p = pinch, p.ids.contains(id) {
            pinch = nil
            if p.active { renderer?.touchUp(id: id); pondTouches.removeValue(forKey: id); return }
        }
        let point = worldPoint(screen)
        let size = viewSize
        // The sheet: a quick lift with no travel is a tap that breaks ice, a
        // slide just ends, and a still finger held there does nothing at all.
        if let t = iceTouches.removeValue(forKey: id) {
            if t.isSlide {
                haptics.slideEnd()
            } else if CACurrentMediaTime() - t.began < 0.3 {
                tapIce(at: point)
            }
            return
        }
        if let stroke = edgeStrokes.removeValue(forKey: id) {
            if stroke.isStroke {
                sound.currentEnd(id: id)
            } else {
                renderer?.touchDown(id: id, at: point, in: size, weight: 0.3)
                renderer?.touchUp(id: id)
                sound.tap(x: Float(point.x / size.width), weight: 0.3)
                haptics.tap(weight: 0.3)
            }
            return
        }
        pondTouches.removeValue(forKey: id)
        if holdSounding.remove(id) != nil { sound.holdEnd(id: id) }
        renderer?.touchUp(id: id)
    }

    // MARK: - Clearing and finishing

    private func clear(_ d: Debris) {
        d.cleared = true
        haptics.clear()
        sound.clearNote(index: debris.filter(\.cleared).count, of: debris.count)
    }

    private func finish() {
        phase = .celebrating
        iceField?.sinkAll(time: renderer?.clock ?? 0)
        let target = level.bloomTarget
        progress.markComplete(levelID: level.id, seasonID: season.id, bloomStage: target)
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(0.8))
            self.sound.complete()
            self.haptics.complete()
            self.garden.bloom(to: target, duration: 5.0)
            try? await Task.sleep(for: .seconds(5.2))
            withAnimation(.easeOut(duration: 0.8)) { self.phase = .complete }
        }
    }

    func next() {
        guard let following = Library.level(after: level) else { return }
        load(level: following)
    }
}

/// Something on the water waiting for a big enough crest.
final class Target {
    let spec: TargetSpec
    let position: CGPoint
    var woke = false
    var wokeAt: Float = 0
    /// 0 closed, 1 fully open, for the crossfade.
    var opening: Float = 0
    /// The highest water seen here, for tuning.
    var peak: Float = 0
    init(spec: TargetSpec, position: CGPoint) {
        self.spec = spec
        self.position = position
    }
}

enum HintMemory {
    static func seen(_ h: Hint) -> Bool { UserDefaults.standard.bool(forKey: "hint.seen.\(h.rawValue)") }
    static func markSeen(_ h: Hint) { UserDefaults.standard.set(true, forKey: "hint.seen.\(h.rawValue)") }
}

/// Turns a level's rocks and shallows into the depth map the wave kernel
/// samples. 1 is deep open water, 0 is a wall.
enum DepthPainter {
    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// Depth at a unit point: the bowl, then the level's shallows and rocks.
    static func depth(at p: CGPoint, level: LevelSpec, aspect: Float) -> Float {
        let px = Float(p.x), py = Float(p.y)
        let bx = (px - 0.5) * aspect, by = py - 0.5
        let rim = max(abs(bx) / (0.5 * aspect), abs(by) / 0.5)
        var d: Float = 1 - 0.62 * smoothstep(0.55, 1.0, rim)
        for s in level.shallows {
            let r = Float(s.radius)
            let dx = (px - Float(s.centre.x)) * aspect, dy = py - Float(s.centre.y)
            let dist = (dx * dx + dy * dy).squareRoot() / r
            if dist < 1 { d = min(d, 0.25 + 0.75 * dist * dist) }
        }
        for o in level.rocks + level.pads {
            let r = Float(o.radius) * 0.9
            let dx = (px - Float(o.centre.x)) * aspect, dy = py - Float(o.centre.y)
            let dist = (dx * dx + dy * dy).squareRoot() / r
            if dist < 1 { d = 0 } else if dist < 1.3 { d = min(d, (dist - 1) / 0.3) }
        }
        return d
    }

    static func paint(level: LevelSpec, width: Int, height: Int) -> [Float] {
        var map = [Float](repeating: 1, count: width * height)
        let fw = Float(width), fh = Float(height)
        let aspect = fw / fh
        for y in 0..<height {
            for x in 0..<width {
                let px = Float(x) / fw, py = Float(y) / fh
                // The pond is a bowl: deep in the middle, shelving to the banks,
                // so waves slow near the edge and the bed shows there.
                let bx = (px - 0.5) * aspect, by = py - 0.5
                let rim = max(abs(bx) / (0.5 * aspect), abs(by) / 0.5)
                var d: Float = 1 - 0.62 * smoothstep(0.55, 1.0, rim)
                for s in level.shallows {
                    let r = Float(s.radius)
                    let dx = (px - Float(s.centre.x)) * aspect, dy = py - Float(s.centre.y)
                    let dist = (dx * dx + dy * dy).squareRoot() / r
                    if dist < 1 { d = min(d, 0.25 + 0.75 * dist * dist) }
                }
                for o in level.rocks + level.pads {
                    let r = Float(o.radius) * 0.9
                    let dx = (px - Float(o.centre.x)) * aspect, dy = py - Float(o.centre.y)
                    let dist = (dx * dx + dy * dy).squareRoot() / r
                    if dist < 1 { d = 0 } else if dist < 1.3 { d = min(d, (dist - 1) / 0.3) }
                }
                map[y * width + x] = d
            }
        }
        return map
    }
}
