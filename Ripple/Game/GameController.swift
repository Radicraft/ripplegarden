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
    private var viewSize = CGSize.zero
    private var art: ArtSet

    private(set) var debris: [Debris] = []
    private var probeOrder: [(debris: Debris, probes: Int)] = []
    private var current = SIMD2<Float>(0, 0)
    private(set) var cleaned: Float = 0
    private var rocks: [(centre: CGPoint, radius: CGFloat)] = []

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

    // MARK: - Wiring

    func attach(renderer: WaterRenderer) {
        self.renderer = renderer
        renderer.style = style
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
        garden.configure(art: art, size: viewSize, bloomStage: progress.bloomStage(for: season.id))
        rocks = level.rocks.map { (CGPoint(x: $0.centre.x * viewSize.width, y: $0.centre.y * viewSize.height),
                                   $0.radius * viewSize.height) }
        debris = level.debris.enumerated().map { i, p in
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
    }

    // MARK: - Per frame

    private func frame(dt: Float) {
        guard let renderer else { return }
        elapsed += dt
        let now = CACurrentMediaTime()

        if viewSize == .zero, let size = renderer.viewSizePoints, size.width > 0 {
            viewSize = size
            place()
        }
        guard viewSize != .zero else { return }

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

        if phase == .playing {
            for d in debris where !d.cleared {
                DebrisPhysics.integrate(d, sample: byID[d.id], current: current, dt: dt)
                keepOffRocks(d)
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
        if phase == .playing, cleaned >= 0.955 { finish() }

        // Feed the renderer.
        feedRenderer(renderer)

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
                NSLog("[garden] silt=%.3f cleaned=%.3f debris=%d heavy@tile=%d heavyLift=%.3f heavyPos=(%.0f,%.0f)",
                      renderer.siltRemaining, cleaned, probeOrder.count, heavyOverTile().count, diagHeavyLift,
                      heavy?.position.x ?? 0, heavy?.position.y ?? 0)
                diagHeavyLift = 0
            }
        }
    }

    private func feedRenderer(_ renderer: WaterRenderer) {
        let w = Float(viewSize.width), h = Float(viewSize.height)

        // Walls: rocks are in the static depth map; heavy floaters move.
        renderer.walls = debris.filter { !$0.cleared && $0.cls == .heavy }.map { ($0.position, $0.radius * 0.8) }

        // Silt covers: anything sitting over the tile shades it.
        renderer.siltCovers = debris.filter { !$0.cleared }.map {
            SIMD4(Float($0.position.x) / w, Float($0.position.y) / h, Float($0.radius) / h * ($0.cls == .heavy ? 0.95 : 0.8), 0)
        }

        // Sprites. Under the water: koi, plus every floater's shadow on the floor.
        var under = garden.submergedSprites()
        for d in debris where !d.cleared {
            let s = spriteSize(d)
            under.append(Sprite(d.sprite, at: CGPoint(x: d.position.x + 7, y: d.position.y + 10), size: s,
                                rotation: Float(d.angle), mode: .shadow, alpha: d.cls == .heavy ? 0.9 : 0.6))
        }
        for r in rocks {
            let side = r.radius * 2.3
            under.append(Sprite(art.rock, at: CGPoint(x: r.centre.x + 6, y: r.centre.y + 9),
                                size: CGSize(width: side, height: side * rockAspect), mode: .shadow, alpha: 1))
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
        for r in rocks {
            let side = r.radius * 2.3
            paper(Sprite(art.rock, at: r.centre, size: CGSize(width: side, height: side * rockAspect)))
        }
        for d in debris where !d.cleared {
            paper(Sprite(d.sprite, at: d.position, size: spriteSize(d), rotation: Float(d.angle),
                         mode: .floater, alpha: d.fade))
        }
        for s in garden.petalSprites() { paper(s) }
        for s in garden.floraSprites() { paper(s, cast: s.texture == art.bank ? 0 : 18) }
        renderer.surfaceSprites = over
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

    private func isOnEdge(_ p: CGPoint, in size: CGSize) -> Bool {
        let b = GameTuning.edgeBand
        return p.x < b || p.y < b || p.x > size.width - b || p.y > size.height - b
    }

    func touchBegan(id: Int, at point: CGPoint, in size: CGSize, weight: Float) {
        viewSize = size
        touchedYet = true
        dismissHint()
        guard phase == .playing || phase == .celebrating else { return }

        if isOnEdge(point, in: size) {
            edgeStrokes[id] = EdgeStroke(last: point)
            return
        }
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

    func touchMoved(id: Int, to point: CGPoint, in size: CGSize) {
        if var stroke = edgeStrokes[id] {
            let dx = point.x - stroke.last.x, dy = point.y - stroke.last.y
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
            stroke.last = point
            edgeStrokes[id] = stroke
            return
        }
        renderer?.touchMoved(id: id, to: point, in: size)
    }

    func touchEnded(id: Int, at point: CGPoint, in size: CGSize) {
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
        let following = Library.level(after: level) ?? level
        load(level: following)
    }
}

enum HintMemory {
    static func seen(_ h: Hint) -> Bool { UserDefaults.standard.bool(forKey: "hint.seen.\(h.rawValue)") }
    static func markSeen(_ h: Hint) { UserDefaults.standard.set(true, forKey: "hint.seen.\(h.rawValue)") }
}

/// Turns a level's rocks and shallows into the depth map the wave kernel
/// samples. 1 is deep open water, 0 is a wall.
enum DepthPainter {
    static func paint(level: LevelSpec, width: Int, height: Int) -> [Float] {
        var map = [Float](repeating: 1, count: width * height)
        guard !level.rocks.isEmpty || !level.shallows.isEmpty else { return map }
        let fw = Float(width), fh = Float(height)
        let aspect = fw / fh
        for y in 0..<height {
            for x in 0..<width {
                let px = Float(x) / fw, py = Float(y) / fh
                var d: Float = 1
                for s in level.shallows {
                    let r = Float(s.radius)
                    let dx = (px - Float(s.centre.x)) * aspect, dy = py - Float(s.centre.y)
                    let dist = (dx * dx + dy * dy).squareRoot() / r
                    if dist < 1 { d = min(d, 0.25 + 0.75 * dist * dist) }
                }
                for o in level.rocks {
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
