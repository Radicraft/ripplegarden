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
    @Published private(set) var level: LevelSpec
    @Published private(set) var season: Season

    let style: WaterStyle
    /// Back to the garden, set by the view: the menus use it too.
    var onExit: (() -> Void)?
    /// The menu in the water, when one is open.
    private(set) var menu: WaterMenu?
    /// Ink under the surface: what this level is for, what is left, a hint.
    private var words: [WaterWords] = []
    private var openingWords: WaterWords?
    private var statusWords: WaterWords?
    private var hintWords: WaterWords?
    private var statusText = ""
    private var statusKey = SIMD4<Int>(-1, -1, -1, -1)
    /// `-showMenu settings|store|complete|hint`, shown once the pond is laid
    /// out so the owner can see a menu without a finger.
    private var pendingMenu: String? = ProcessInfo.processInfo.arguments.firstIndex(of: "-showMenu").flatMap {
        $0 + 1 < ProcessInfo.processInfo.arguments.count ? ProcessInfo.processInfo.arguments[$0 + 1] : nil
    }
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
    private(set) var pads: [(centre: CGPoint, radius: CGFloat, sprite: String)] = []
    /// Things a crest wakes.
    private(set) var targets: [Target] = []
    private var targetProbeStart = 0

    private let diagnostics = ProcessInfo.processInfo.arguments.contains("-diag")
    private var diagFrames = 0
    private var diagHeavyLift: Float = 0
    private var diagIceUploads = 0
    private var diagIceCells = 0
    private var diagIceLast = (w: 0, h: 0)
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
    /// The wait that runs after the pond is clear. It is dropped when the
    /// level changes, or a stale one would finish over the next level.
    private var celebration: Task<Void, Never>?
    private var edgeStrokes: [Int: EdgeStroke] = [:]

    /// A finger on open water. Held still it charges a swell, which the
    /// renderer owns; drawn across it lays a wake; drawn round it stirs a
    /// whirl; two of them thrown the same way are a gust.
    private struct PondTouch {
        var held: Float = 0
        var last: CGPoint          // world
        var lastAt: TimeInterval
        var speed: Float = 0
        var isWake = false
        var sinceSplat: CGFloat = 0
        var heading: SIMD2<Float>?
        /// The last stretch of the stroke: where it went and how far it
        /// turned at each step, for reading a circle out of it.
        var path: [(at: TimeInterval, point: CGPoint, turn: Float)] = []
        var stirring = false
        /// A finger spent on a gust: it lays no more wake behind it.
        var spent = false
    }
    private var pondTouches: [Int: PondTouch] = [:]
    private var holdSounding: Set<Int> = []
    private var wakeSounding: Set<Int> = []

    /// A whirl stirred into the pond, turning on after the hand has gone.
    private struct Whirl {
        var centre: CGPoint
        var radius: CGFloat
        var omega: Float
        var strength: Float
        /// The finger still stirring it, if there is one.
        var stirring: Int?
        var phase: Float
    }
    private var whirl: Whirl?
    /// The whirl's own voice. Negative, so it never meets a touch id.
    private let whirlSoundID = -7

    /// A gust of wind crossing the pond: a shallow line of water marching
    /// along the direction the two fingers threw.
    private struct Gust {
        var direction: SIMD2<Float>
        var origin: CGPoint
        var length: CGFloat
        var age: Float = 0
    }
    private var gust: Gust?
    private var lastGustAt: TimeInterval = 0
    /// The last plain tap, for reading a double tap out of two of them.
    private var lastTap: (point: CGPoint, at: TimeInterval)?
    /// Splats the gestures may lay this frame. Reset every frame so a wake,
    /// a whirl or a gust never crowds out the rain and the garden.
    private var stirBudget = 0
    private var gustBudget = 0
    private var bubbleAccumulator: Float = 0

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

    /// Two pieces knock: the harder or hollower one sounds, once in a while.
    private func knock(_ a: Debris, _ b: Debris, _ speed: Float) {
        var loud: Debris? = nil
        for d in [a, b] where d.kind == .can { loud = d }
        if loud == nil { for d in [a, b] where d.kind == .bottle { loud = d } }
        if loud == nil { for d in [a, b] where d.cls == .heavy { loud = d } }
        guard let d = loud, elapsed - d.lastKnockAt > 0.7 else { return }
        d.lastKnockAt = elapsed
        let x = Float(d.position.x / viewSize.width)
        switch d.kind {
        case .can: sound.can(x: x); haptics.tap(weight: 0.4)
        case .bottle: sound.bottle(x: x); haptics.tap(weight: 0.3)
        default: sound.wood(x: x); haptics.tap(weight: 0.5)
        }
    }

    /// The player has gone back to the map: the pond's air fades, held
    /// fingers are let go.
    func leave() {
        celebration?.cancel()
        menu = nil
        words = []
        openingWords = nil
        statusWords = nil
        hintWords = nil
        sound.stopAmbience()
        for id in Array(holdSounding) { sound.holdEnd(id: id) }
        holdSounding.removeAll()
        hushGestures()
        renderer?.cancelAll()
    }

    /// Called from the path before the level screen appears.
    func prepare(level: LevelSpec) {
        self.level = level
        season = Library.season(for: level)
        art = season.art(for: style)
        phase = .playing
        if renderer != nil { load(level: level) }
    }

    func attach(renderer: WaterRenderer) {
        // The view being replaced must stop driving the level.
        self.renderer?.onFrame = nil
        self.renderer = renderer
        renderer.style = style
        garden.textureSize = { [weak renderer] name in renderer?.textures.size(name) ?? CGSize(width: 1, height: 1) }
        renderer.onFrame = { [weak self] dt in self?.frame(dt: dt) }
        renderer.onChargedRelease = { [weak self] charge, at in
            guard let self else { return }
            self.sound.holdRelease(charge: charge)
            self.haptics.holdRelease(charge: charge)
            // A swell big enough throws water into the air.
            if charge > 0.5 { self.garden.burstDroplets(at: at, power: charge) }
        }
        renderer.onSwellStart = { [weak self] in
            self?.sound.swell()
            self?.haptics.swell()
        }
        DebrisPhysics.onKnock = { [weak self] a, b, speed in self?.knock(a, b, speed) }
        load(level: level)
    }

    func load(level newLevel: LevelSpec) {
        celebration?.cancel()
        menu = nil
        words = []
        openingWords = nil
        statusWords = nil
        hintWords = nil
        statusText = ""
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
        hushGestures()
        lastTap = nil
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

        if viewSize != .zero {
            place()
            openWords()
        }
        sound.startAmbience(named: newLevel.rain ? "amb_rain_light" : "amb_\(season.id)")
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
                // A season with nothing painted for this class falls back to
                // the piece every season has, rather than dividing by zero.
                name = art.light.isEmpty ? "leaf_1" : art.light[p.variant % art.light.count]
                radius = 15 * p.scale
            case .heavy:
                name = art.heavy.isEmpty ? "driftwood_1" : art.heavy[p.variant % art.heavy.count]
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
            sound.iceCrack(x: Float(point.x / viewSize.width))
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
        sound.iceBreak(x: Float(point.x / viewSize.width), size: Float(min(1, total / 60000)))
        renderer?.addSplat(at: point, in: viewSize, radius: 22, amplitude: -0.45)
        garden.burstDroplets(at: point, power: 0.4 + 0.6 * Float(min(1, total / 60000)))
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
            openWords()
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
        // The gestures get their ration of splats back each frame.
        stirBudget = GameTuning.stirBudgetPerFrame
        gustBudget = GameTuning.gustSplatsPerFrame
        let vortex = updateWhirl(dt: dt)
        updateGust(dt: dt)

        // Rain: drops land all over the water, small rings by the dozen and
        // now and then a fatter one, so the surface never rests.
        if level.rain, phase == .playing || phase == .celebrating {
            let w = viewSize.width, h = viewSize.height
            for _ in 0..<4 {
                let p = CGPoint(x: CGFloat.random(in: 0...w), y: CGFloat.random(in: 0...h))
                renderer.addSplat(at: p, in: viewSize, radius: Float.random(in: 2.2...3.6), amplitude: Float.random(in: -0.028 ... -0.012))
            }
            if Int.random(in: 0..<24) == 0 {
                let p = CGPoint(x: CGFloat.random(in: 0...w), y: CGFloat.random(in: 0...h))
                renderer.addSplat(at: p, in: viewSize, radius: 6, amplitude: -0.05)
            }
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
        if let f = iceField, let rect = f.dirtyRect {
            // Only the patch that changed goes up, not the whole sheet.
            renderer.setIce(f.cells, scuff: f.scuff, width: f.width, height: f.height, rect: rect)
            if diagnostics, let r = renderer.lastIceUploadRect {
                diagIceUploads += 1
                diagIceCells += r.w * r.h
                diagIceLast = (r.w, r.h)
            }
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
                DebrisPhysics.integrate(d, sample: byID[d.id], current: current, vortex: vortex, dt: dt)
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
                switch t.spec.kind {
                case .bud: sound.bud(x: Float(t.position.x / viewSize.width))
                case .bell: sound.bell(x: Float(t.position.x / viewSize.width))
                }
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

        for (id, touch) in pondTouches {
            var t = touch
            t.held += dt
            pondTouches[id] = t
            // A finger that has become a wake is no longer pressing.
            guard !t.isWake, !t.spent else { continue }
            let charge = renderer.charge(of: id)
            if charge > 0.12, t.held > GameTuning.holdSoundAfter, !holdSounding.contains(id) {
                holdSounding.insert(id)
                sound.holdBegin(id: id)
                haptics.holdBegin()
            }
            if holdSounding.contains(id) { sound.holdLevel(id: id, charge: charge) }
            // The press pushes air out of the bed: bubbles climb under it.
            if charge > GameTuning.bubbleCharge {
                bubbleAccumulator += GameTuning.bubbleRate * charge * dt
                while bubbleAccumulator >= 1 {
                    bubbleAccumulator -= 1
                    garden.addBubble(at: t.last)
                }
            }
        }
        if pondTouches.isEmpty { bubbleAccumulator = 0 }

        updateHints()

        // The water's own interface: a menu, the line that opens the level,
        // what is left, a hint.
        menu?.update(dt: dt)
        if menu?.isGone == true { menu = nil }
        renderer.menuDim = menu?.dim ?? 0
        if let m = menu { renderer.menuRect = m.rect }
        for w in words { w.update(dt: dt) }
        words.removeAll { $0.isGone }
        if openingWords?.isGone == true { openingWords = nil }
        if hintWords?.isGone == true { hintWords = nil; hint = nil }
        updateStatus()
        if let flag = pendingMenu, elapsed > 1.0 {
            pendingMenu = nil
            show(menuFlag: flag)
        }

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
                if let f = iceField {
                    NSLog("[ice] uploads=%d last=%dx%d (%d bytes) total=%d bytes over 60 frames, sheet=%dx%d (%d bytes)",
                          diagIceUploads, diagIceLast.w, diagIceLast.h, diagIceLast.w * diagIceLast.h * 2,
                          diagIceCells * 2, f.width, f.height, f.width * f.height * 2)
                }
                diagIceUploads = 0
                diagIceCells = 0
            }
        }
    }

    private func feedRenderer(_ renderer: WaterRenderer) {
        let w = Float(viewSize.width), h = Float(viewSize.height)
        let menuArt = menu?.sprites(textures: renderer.textures)

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
        under += menuArt?.submerged ?? []
        for line in words { under += line.sprites(textures: renderer.textures) }
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
            // Under unbroken ice a piece is a shape in the dark, not a thing
            // on the water: its floor shadow stays, the rest waits for the
            // sheet to open over it.
            if let f = iceField, f.ice(at: d.position) > 0.5 { continue }
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
        renderer.solids = solids + (menuArt?.solids ?? [])
        for s in garden.skaterSprites() { paper(s) }
        for s in garden.petalSprites() { paper(s) }
        // Drops in the air are water, not paper: no cut edge under them.
        over += garden.dropletSprites()
        for s in garden.floraSprites() { paper(s, cast: s.texture == art.bank ? 0 : 18) }
        over += garden.skySprites()
        // While a menu is up the pond's own things fade back so the ink reads.
        if let m = menu, m.dim > 0.01 {
            let keep = 1 - 0.75 * m.dim
            for i in over.indices { over[i].gpu.alpha *= keep }
        }
        over += menuArt?.surface ?? []
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
            if into < 0 {
                d.velocity -= n * into * 1.4
                if into < -14, elapsed - d.lastKnockAt > 0.7 {
                    d.lastKnockAt = elapsed
                    let x = Float(d.position.x / viewSize.width)
                    switch d.kind {
                    case .can: sound.can(x: x); haptics.tap(weight: 0.5)
                    case .bottle: sound.bottle(x: x); haptics.tap(weight: 0.3)
                    case .natural where d.cls == .heavy: sound.wood(x: x); haptics.tap(weight: 0.6)
                    default: break
                    }
                }
            }
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
        hint = h
        showHintLine(h.text)
    }

    /// A hint is one line of ink low in the pond: it rises, waits, and sinks.
    private func showHintLine(_ text: String) {
        let line = WaterWords(lines: [WaterWords.Line(text: text, points: 16, wrapped: true)],
                              centre: worldAt(CGPoint(x: 0.5, y: 0.78)), hold: 6)
        hintWords = line
        words.append(line)
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
            hintWords?.sink()
            hint = nil
        }
    }

    // MARK: - Touches

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
            // Two fingers thrown the same way are a gust, and a gust must not
            // be read as a pinch just because the hand spread a little.
            if gustPair() != nil { return }
            p.active = true
            r.cancelAll()
            for pid in p.ids {
                pondTouches.removeValue(forKey: pid)
                if holdSounding.remove(pid) != nil { sound.holdEnd(id: pid) }
                if wakeSounding.remove(pid) != nil { sound.wakeEnd(id: pid); haptics.slideEnd() }
            }
        }
        let z = max(0.8, min(1.8, p.startZoom * Float(dist / max(1, p.startDistance))))
        zoomTarget = z
        // Keep the world point that was under the fingers under them.
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        centreTarget = p.anchorWorld - SIMD2(Float(mid.x - screenSize.width / 2), Float(mid.y - screenSize.height / 2)) / z
        pinch = p
    }

    // MARK: - Gestures on open water

    /// Every gesture splat goes through here, so none of them can eat the
    /// frame's whole splat budget.
    @discardableResult
    private func budgetedSplat(at p: CGPoint, radius: Float, amplitude: Float) -> Bool {
        guard stirBudget > 0, viewSize != .zero else { return false }
        stirBudget -= 1
        renderer?.addSplat(at: p, in: viewSize, radius: radius, amplitude: amplitude)
        return true
    }

    /// Stops any gesture voice still running, and forgets the whirl.
    private func hushGestures() {
        for id in Array(wakeSounding) { sound.wakeEnd(id: id) }
        wakeSounding.removeAll()
        if whirl != nil { sound.whirlEnd(id: whirlSoundID) }
        whirl = nil
        gust = nil
        haptics.slideEnd()
    }

    /// A finger travelling over open water. Slowly it is still a hold and the
    /// renderer keeps charging it; past `wakeSpeed` it cuts a wake instead,
    /// and the hold is dropped. A stroke that keeps turning stirs a whirl.
    private func strokeWater(id: Int, at point: CGPoint, in size: CGSize) {
        guard var t = pondTouches[id], let renderer else { return }
        let now = CACurrentMediaTime()
        let step = hypot(point.x - t.last.x, point.y - t.last.y)
        let dx = point.x - t.last.x, dy = point.y - t.last.y
        let elapsedSince = max(1.0 / 240, now - t.lastAt)
        let instant = Float(step / CGFloat(elapsedSince))
        t.speed += (instant - t.speed) * 0.4

        // The turning of the stroke, step by step, kept for as long as a
        // circle may take to draw.
        if step > 2 {
            let dir = SIMD2(Float(dx), Float(dy)) / Float(step)
            var turn: Float = 0
            if let last = t.heading {
                turn = atan2(last.x * dir.y - last.y * dir.x, simd_dot(last, dir))
            }
            t.heading = dir
            t.path.append((now, point, turn))
        }
        t.path.removeAll { now - $0.at > GameTuning.stirWindow }

        if !t.isWake, !t.spent, t.speed > GameTuning.wakeSpeed {
            t.isWake = true
            renderer.cancelHold(id: id)
            if holdSounding.remove(id) != nil { sound.holdEnd(id: id) }
            sound.wakeBegin(id: id)
            wakeSounding.insert(id)
            haptics.slideBegin()
        }

        if t.isWake, !t.spent {
            let strength = min(1.6, max(0.35, t.speed / GameTuning.wakeFullSpeed))
            sound.wakeLevel(id: id, speed: t.speed)
            // Water is glassy under a moving finger; a whirl drags harder.
            haptics.slide(speed: t.speed, grain: t.stirring ? 0.2 : 0.1, travel: Float(step))
            t.sinceSplat += step
            if t.sinceSplat >= GameTuning.wakeSpacing {
                let n = min(Int(t.sinceSplat / GameTuning.wakeSpacing), 6)
                t.sinceSplat -= CGFloat(n) * GameTuning.wakeSpacing
                for i in 1...n {
                    let f = CGFloat(i) / CGFloat(n)
                    budgetedSplat(at: CGPoint(x: t.last.x + dx * f, y: t.last.y + dy * f),
                                  radius: GameTuning.wakeRadius,
                                  amplitude: GameTuning.wakeAmplitude * strength)
                }
                // Once every few points, not every frame: the fish scatter
                // ahead of the hand without the camera jerking after it.
                garden.startle(at: point, in: size)
            }
        } else if !t.spent {
            // Still a slow drag: the renderer lays its own trail behind it.
            renderer.touchMoved(id: id, to: point, in: size)
        }

        // A circle: the stroke has turned a turn and a half without stopping.
        let turned = t.path.reduce(Float(0)) { $0 + $1.turn }
        if abs(turned) >= GameTuning.stirTurn, t.path.count > 6 {
            t.stirring = true
            stir(id: id, path: t.path.map(\.point), turn: turned)
        } else if t.stirring {
            t.stirring = false
            if whirl?.stirring == id { whirl?.stirring = nil }
        }

        t.last = point
        t.lastAt = now
        pondTouches[id] = t
        checkGust()
    }

    /// The stroke went round: a whirl at the middle of the circle it drew,
    /// turning the way the hand did, as wide as the circle and half again.
    private func stir(id: Int, path: [CGPoint], turn: Float) {
        guard !path.isEmpty else { return }
        var sum = CGPoint.zero
        for p in path { sum.x += p.x; sum.y += p.y }
        let centre = CGPoint(x: sum.x / CGFloat(path.count), y: sum.y / CGFloat(path.count))
        var mean: CGFloat = 0
        for p in path { mean += hypot(p.x - centre.x, p.y - centre.y) }
        let radius = max(30, mean / CGFloat(path.count)) * GameTuning.stirRadiusScale
        let omega = GameTuning.stirOmega * (turn > 0 ? 1 : -1)
        if var w = whirl, w.stirring == nil || w.stirring == id {
            // The hand carries the whirl with it rather than starting a new one.
            w.centre.x += (centre.x - w.centre.x) * 0.12
            w.centre.y += (centre.y - w.centre.y) * 0.12
            w.radius += (radius - w.radius) * 0.12
            w.omega += (omega - w.omega) * 0.12
            w.strength = 1
            w.stirring = id
            whirl = w
            return
        }
        guard whirl == nil else { return }
        whirl = Whirl(centre: centre, radius: radius, omega: omega, strength: 1, stirring: id,
                      phase: Float.random(in: 0...(2 * .pi)))
        sound.whirlBegin(id: whirlSoundID)
    }

    /// The whirl draws itself into the water as a spiral of small splats going
    /// round, so what the pond shows is the sim's own answer to it. Returns
    /// the term the floaters are integrated with.
    private func updateWhirl(dt: Float) -> Vortex? {
        guard var w = whirl else { return nil }
        // The finger that was stirring it may have gone without a word (it
        // became half a pinch); the whirl must still be let go.
        if let id = w.stirring, pondTouches[id] == nil { w.stirring = nil }
        if w.stirring == nil {
            w.strength *= exp(-dt * log(2) / GameTuning.stirHalfLife)
        }
        guard w.strength > 0.03 else {
            whirl = nil
            sound.whirlEnd(id: whirlSoundID)
            return nil
        }
        w.phase += w.omega * dt
        let n = min(GameTuning.stirSplatsPerFrame, stirBudget)
        if n > 1 {
            for i in 0..<n {
                // Spread across the whirl, the inner ones running ahead, so
                // the ring of splats reads as a spiral being wound in.
                let frac = 0.32 + 0.62 * Float(i) / Float(n - 1)
                let angle = w.phase * (1 + 0.6 * (1 - frac)) + Float(i) * 2 * .pi / Float(n)
                let r = w.radius * CGFloat(frac)
                budgetedSplat(at: CGPoint(x: w.centre.x + cos(CGFloat(angle)) * r,
                                          y: w.centre.y + sin(CGFloat(angle)) * r),
                              radius: GameTuning.stirSplatRadius,
                              amplitude: GameTuning.stirSplatAmplitude * w.strength)
            }
        }
        sound.whirlLevel(id: whirlSoundID, strength: w.strength)
        whirl = w
        return Vortex(centre: SIMD2(Float(w.centre.x), Float(w.centre.y)),
                      radius: Float(w.radius), omega: w.omega, strength: w.strength)
    }

    /// Two fingers thrown across the pond the same way are wind, not two
    /// wakes and not a pinch: they must both be moving now, both quick, and
    /// both pointing much the same way.
    private func gustPair() -> (ids: [Int], direction: SIMD2<Float>)? {
        let now = CACurrentMediaTime()
        let fast = pondTouches.filter {
            $0.value.speed > GameTuning.gustSpeed && $0.value.heading != nil && !$0.value.spent
                && now - $0.value.lastAt < 0.12
        }
        guard fast.count >= 2 else { return nil }
        let list = Array(fast)
        for i in 0..<list.count {
            for j in (i + 1)..<list.count {
                guard let a = list[i].value.heading, let b = list[j].value.heading else { continue }
                guard acos(max(-1, min(1, simd_dot(a, b)))) <= GameTuning.gustAngle else { continue }
                return ([list[i].key, list[j].key], simd_normalize(a + b))
            }
        }
        return nil
    }

    private func checkGust() {
        guard gust == nil, pinch?.active != true,
              CACurrentMediaTime() - lastGustAt > GameTuning.gustCooldown,
              let pair = gustPair() else { return }
        startGust(direction: pair.direction, ids: pair.ids)
    }

    /// The wind crosses the whole pond: a shallow line of water marching from
    /// the upwind bank to the far one, and everything in the air goes with it.
    private func startGust(direction: SIMD2<Float>, ids: [Int]) {
        guard viewSize != .zero else { return }
        lastGustAt = CACurrentMediaTime()
        for id in ids {
            if var t = pondTouches[id] {
                t.spent = true
                t.isWake = false
                pondTouches[id] = t
            }
            renderer?.cancelHold(id: id)
            if holdSounding.remove(id) != nil { sound.holdEnd(id: id) }
            if wakeSounding.remove(id) != nil { sound.wakeEnd(id: id) }
        }
        haptics.slideEnd()
        let w = Float(viewSize.width), h = Float(viewSize.height)
        let centre = SIMD2(w / 2, h / 2)
        let span = abs(direction.x) * w + abs(direction.y) * h
        let start = centre - direction * (span / 2 + 40)
        gust = Gust(direction: direction, origin: CGPoint(x: CGFloat(start.x), y: CGFloat(start.y)),
                    length: CGFloat(span + 80))
        // The two fingers spent themselves on the wind: they are not a pinch
        // on the way, and the view must not jump after them.
        pinch = nil
        garden.blow(direction: direction, strength: 90)
        sound.gust(x: 0.5)
        haptics.swell()
    }

    private func updateGust(dt: Float) {
        guard var g = gust, let renderer, viewSize != .zero else { return }
        g.age += dt
        let t = min(1, g.age / GameTuning.gustSeconds)
        let along = g.length * CGFloat(t)
        let mid = CGPoint(x: g.origin.x + CGFloat(g.direction.x) * along,
                          y: g.origin.y + CGFloat(g.direction.y) * along)
        let perp = SIMD2(-g.direction.y, g.direction.x)
        let across = abs(perp.x) * Float(viewSize.width) + abs(perp.y) * Float(viewSize.height)
        let n = GameTuning.gustSplatsPerFrame
        // Softest at the two ends of the sweep, fullest in the middle of it.
        let body = sin(Float.pi * t)
        for i in 0..<n {
            guard gustBudget > 0 else { break }
            gustBudget -= 1
            let f = (Float(i) / Float(n - 1) - 0.5) * across
            renderer.addSplat(at: CGPoint(x: mid.x + CGFloat(perp.x * f), y: mid.y + CGFloat(perp.y * f)),
                              in: viewSize, radius: GameTuning.gustRadius,
                              amplitude: GameTuning.gustAmplitude * (0.55 + 0.45 * body))
        }
        gust = g.age >= GameTuning.gustSeconds ? nil : g
    }

    /// Two taps in one spot: a stone goes in. A deep splat, water thrown up,
    /// and everything nearby feels it land.
    private func dropStone(at point: CGPoint) {
        guard viewSize != .zero else { return }
        renderer?.addSplat(at: point, in: viewSize, radius: GameTuning.stoneRadius,
                           amplitude: GameTuning.stoneAmplitude)
        garden.burstDroplets(at: point, power: 1)
        garden.startle(at: point, in: viewSize)
        waveBitesIce(from: point)
        sound.holdRelease(charge: 1)
        haptics.holdRelease(charge: 1)
    }

    func touchBegan(id: Int, at screen: CGPoint, in screenBounds: CGSize, weight: Float) {
        screenSize = screenBounds
        // A menu is in the way: nothing reaches the water through it.
        if menu?.isOpen == true { return }
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
        pondTouches[id] = PondTouch(last: point, lastAt: CACurrentMediaTime())
        sound.tap(x: Float(point.x / size.width), weight: weight)
        haptics.tap(weight: weight)
    }

    func touchMoved(id: Int, to screen: CGPoint, in screenBounds: CGSize) {
        if menu?.isOpen == true { return }
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
        if pondTouches[id] != nil {
            strokeWater(id: id, at: point, in: size)
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
            if t.lastCrackDist > 3, crossed.dist <= 3 {
                haptics.slideCrack(strength: crossed.strength)
                sound.iceCrack(x: Float(point.x / viewSize.width))
            }
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
        if let m = menu, m.isOpen {
            m.hit(worldPoint(screen))
            return
        }
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
        if let t = pondTouches.removeValue(forKey: id) {
            if wakeSounding.remove(id) != nil {
                sound.wakeEnd(id: id)
                haptics.slideEnd()
            }
            // The whirl keeps turning on its own once the hand has gone.
            if whirl?.stirring == id { whirl?.stirring = nil }
            if holdSounding.remove(id) != nil { sound.holdEnd(id: id) }
            renderer?.touchUp(id: id)
            // A plain tap, and one just landed beside it: a stone drops in.
            let plain = !t.isWake && !t.spent && t.held < Float(GameTuning.doubleTapSeconds)
            let now = CACurrentMediaTime()
            if plain, let last = lastTap, now - last.at < GameTuning.doubleTapSeconds,
               hypot(last.point.x - point.x, last.point.y - point.y) < GameTuning.doubleTapDistance {
                lastTap = nil
                dropStone(at: CGPoint(x: (last.point.x + point.x) / 2, y: (last.point.y + point.y) / 2))
            } else {
                lastTap = plain ? (point, now) : nil
            }
            return
        }
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
        celebration = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(0.8))
            if Task.isCancelled { return }
            self.sound.complete()
            self.haptics.complete()
            self.garden.bloom(to: target, duration: 5.0)
            try? await Task.sleep(for: .seconds(5.2))
            if Task.isCancelled { return }
            self.phase = .complete
            self.showCompletion()
        }
    }

    func next() {
        guard let following = Library.level(after: level) else { return }
        load(level: following)
    }

    // MARK: - Menus in the water

    /// A point in the pond at this fraction of the screen, kept inside the
    /// water so nothing is laid out on the bank.
    private func worldAt(_ f: CGPoint) -> CGPoint {
        guard viewSize != .zero else { return .zero }
        guard screenSize != .zero else { return CGPoint(x: viewSize.width * f.x, y: viewSize.height * f.y) }
        let p = worldPoint(CGPoint(x: screenSize.width * f.x, y: screenSize.height * f.y))
        return CGPoint(x: min(max(p.x, 50), viewSize.width - 50),
                       y: min(max(p.y, 50), viewSize.height - 50))
    }

    /// The level opens: its name and what it is for rise under the surface,
    /// and the line that says what is left sits above them for good.
    private func openWords() {
        guard viewSize != .zero else { return }
        let opening = WaterWords(lines: [WaterWords.Line(text: level.title, points: 26),
                                         WaterWords.Line(text: level.goal, points: 16, wrapped: true)],
                                 centre: worldAt(CGPoint(x: 0.5, y: 0.34)), hold: 5)
        let status = WaterWords(lines: [], centre: worldAt(CGPoint(x: 0.5, y: 0.13)), hold: nil)
        status.width = 340
        openingWords = opening
        statusWords = status
        words = [opening, status]
        statusText = ""
        statusKey = SIMD4<Int>(-1, -1, -1, -1)
        updateStatus()
    }

    /// What is left, kept in the water. The texture is only drawn again when
    /// the line itself changes.
    private func updateStatus() {
        guard let status = statusWords else { return }
        // The line is only written again when what is left has actually
        // changed. The sheet is read to the nearest twentieth, or a melting
        // shard would rewrite the words every frame.
        let alive = debris.filter { !$0.cleared }
        let ice = ((iceField?.fraction ?? 0) * 20).rounded() / 20
        let key = SIMD4<Int>(alive.count, alive.filter { $0.kind.isRubbish }.count,
                             targets.filter { !$0.woke }.count, Int(ice * 20))
        guard key != statusKey else { return }
        statusKey = key
        let text = LevelSpec.status(remaining: alive.map(\.kind),
                                    targetsAsleep: targets.filter { !$0.woke }.count,
                                    ice: ice)
        guard text != statusText else { return }
        statusText = text
        status.replace(lines: [WaterWords.Line(text: text, points: 16)])
    }

    private func present(_ m: WaterMenu) {
        m.splat = { [weak self] point, radius, amplitude in
            guard let self, self.viewSize != .zero else { return }
            self.renderer?.addSplat(at: point, in: self.viewSize, radius: radius, amplitude: amplitude)
        }
        menu = m
        m.open(at: worldAt(CGPoint(x: 0.5, y: 0.6)), world: viewSize)
    }

    func openSettings() { present(WaterMenus.settings(sound: sound, haptics: haptics)) }

    func openStore() { present(WaterMenus.store(sound: sound, haptics: haptics)) }

    /// The pond is clear: the words rise, and two stones sit under them.
    func showCompletion() {
        var buttons = [WaterMenuButton(label: "Garden", action: { [weak self] in self?.onExit?() })]
        if Library.level(after: level) != nil {
            buttons.append(WaterMenuButton(label: "Next", dark: true, action: { [weak self] in self?.next() }))
        }
        let m = WaterMenu(rows: [.title("The pond is clear."), .buttons(buttons)], sound: sound, haptics: haptics)
        m.closesOnOutsideTap = false
        present(m)
    }

    /// `-showMenu settings|store|complete|hint`.
    private func show(menuFlag: String) {
        switch menuFlag {
        case "settings": openSettings()
        case "store": openStore()
        case "complete": showCompletion()
        case "hint":
            let h = level.hint ?? .tap
            hintsShown.insert(h)
            hint = h
            showHintLine(h.text)
        default: break
        }
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
