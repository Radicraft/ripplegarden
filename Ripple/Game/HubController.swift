import CoreGraphics
import Foundation
import QuartzCore
import simd

/// The hub: the year as one stream, winter at its source and autumn at its
/// mouth, four screens tall. The player drifts down it; the levels are the
/// pools along it, and a tap on a pool is the splash that drops into it.
/// The stream is the water renderer itself, with the garden's life on it.
@MainActor
final class HubController: ObservableObject, TouchInput {

    struct Pool {
        let level: LevelSpec
        let season: Season
        let centre: CGPoint      // world points
        let radius: CGFloat
    }

    /// Where each pool sits on screen right now, for the labels.
    struct Mark: Identifiable {
        let id: String
        let level: LevelSpec
        let season: Season
        let screen: CGPoint
        let radius: CGFloat
        let unlocked: Bool
        let complete: Bool
        let first: Bool          // the season's first pool carries its name
    }

    @Published private(set) var marks: [Mark] = []
    /// The level a splash is opening, once the water has closed over the tap.
    var onPlay: ((LevelSpec) -> Void)?

    static let worldScale = CGSize(width: 1.15, height: 4.0)
    static let gridLongSide = 1400

    private(set) var pools: [Pool] = []
    private var renderer: WaterRenderer?
    private var garden: Garden
    private let art: ArtSet
    private var viewSize = CGSize.zero
    private var screenSize = CGSize.zero
    private var centreTarget = SIMD2<Float>(0, 0)
    private var momentum: Float = 0
    private var scroll: (id: Int, lastY: CGFloat, lastAt: TimeInterval, moved: Bool, startY: CGFloat)?
    private var pending: [Int: (start: CGPoint, began: TimeInterval)] = [:]
    private var lastMarksAt: TimeInterval = 0
    private var opening: (level: LevelSpec, at: TimeInterval)?
    private var elapsed: Float = 0
    private let progress = ProgressStore.shared
    private var placed = false
    private var zoomTarget: Float = 0.9
    /// Things laid along each stretch so the year shows: ice at the source,
    /// petals, lotus, leaves; and the season's branches over the bank.
    private var dressing: [Sprite] = []
    private var stretchBranches: [Sprite] = []
    private var snow: [(x: CGFloat, y: CGFloat, phase: Float, size: CGFloat)] = []
    private var winterBand: ClosedRange<CGFloat> = 0...0

    init() {
        // Spring dresses the stream; the seasons show in what sits at each
        // pool. Every shoal swims here.
        var a = Library.springWoodblock
        a.shoal = ["minnow_1", "rudd_1", "stickleback_1", "minnow_2", "rudd_2", "stickleback_2"]
        a.branch = []          // each stretch hangs its own season's branches
        art = a
        garden = Garden(art: a)
    }

    // MARK: - Wiring

    func attach(renderer: WaterRenderer) {
        self.renderer = renderer
        // A fresh view: lay the stream out again on this renderer.
        viewSize = .zero
        placed = false
        opening = nil
        zoomTarget = 0.9
        momentum = 0
        renderer.style = .woodblock
        var look = art.floor
        look.mosaicRadius = 0
        renderer.floorLook = look
        renderer.depthPainter = { [weak self] w, h in self?.paintDepth(width: w, height: h) ?? Array(repeating: 1, count: w * h) }
        renderer.rebuildDepth()
        garden.textureSize = { [weak renderer] name in renderer?.textures.size(name) ?? CGSize(width: 1, height: 1) }
        renderer.onFrame = { [weak self] dt in self?.frame(dt: dt) }
        renderer.zoom = 0.9
    }

    private func place() {
        let w = viewSize.width, h = viewSize.height
        pools = []
        let seasons = Library.seasons
        let top = h * 0.085, bottom = h * 0.94
        let stretch = (bottom - top) / CGFloat(seasons.count)
        for (si, season) in seasons.enumerated() {
            let levels = Library.levels(in: season)
            for (li, level) in levels.enumerated() {
                let t = (CGFloat(li) + 0.5) / CGFloat(levels.count)
                let y = top + stretch * CGFloat(si) + stretch * t
                let side: CGFloat = (si * levels.count + li) % 2 == 0 ? -1 : 1
                let x = w * (0.5 + side * 0.13)
                pools.append(Pool(level: level, season: season, centre: CGPoint(x: x, y: y), radius: min(w * 0.22, 118)))
            }
        }
        garden.depthAt = { [weak self] p in
            guard let self else { return 1 }
            return self.depth(at: CGPoint(x: p.x / self.viewSize.width, y: p.y / self.viewSize.height))
        }
        garden.configure(art: art, size: viewSize, bloomStage: 1.5)
        garden.rocks = pools.map { (CGPoint(x: $0.centre.x + $0.radius * 0.7, y: $0.centre.y - $0.radius * 0.55), 22) }
        // Start at the source, on the first pool not yet done.
        let start = pools.first { !progress.isComplete(levelID: $0.level.id) } ?? pools[0]
        centreTarget = SIMD2(Float(viewSize.width / 2), Float(start.centre.y))
        renderer?.viewCentre = centreTarget
        dress(top: top, stretch: stretch)
        placed = true
    }

    /// The year along the stream: each season's branches over its stretch,
    /// ice around the winter pools, blossom in spring, lotus in summer,
    /// leaves in autumn, and snow in the air at the source.
    private func dress(top: CGFloat, stretch: CGFloat) {
        dressing = []
        stretchBranches = []
        var rng = SystemRandomNumberGenerator()
        let w = viewSize.width
        for (si, season) in Library.seasons.enumerated() {
            let y0 = top + stretch * CGFloat(si)
            let a = season.woodblock
            // Branches reach in from both banks at the head of the stretch.
            if a.branch.count > 2 {
                let name = a.branch[si == 0 ? 1 : 2]
                // Tucked into the banks at the head of the stretch, above the
                // season's name, reaching a little way over the water.
                let side = w * a.branchScale * 0.62
                let head = y0 - stretch * 0.085
                stretchBranches.append(Sprite(name, at: CGPoint(x: side * 0.32 - a.branchInset, y: head - side * 0.12),
                                              size: CGSize(width: side, height: side), z: 0.9))
                let small = side * 0.8
                stretchBranches.append(Sprite(name, at: CGPoint(x: w - small * 0.3 + a.branchInset, y: head + small * 0.05),
                                              size: CGSize(width: small, height: small), flipX: true, z: 0.9))
            }
            if si == 0 { winterBand = (y0 - 40)...(y0 + stretch) }
            for pool in pools where pool.season.id == season.id {
                let n = Int.random(in: 3...5, using: &rng)
                for k in 0..<n {
                    let ang = CGFloat(k) / CGFloat(n) * 2 * .pi + CGFloat.random(in: -0.4...0.4, using: &rng)
                    let r = pool.radius * CGFloat.random(in: 0.75...1.15, using: &rng)
                    let p = CGPoint(x: pool.centre.x + cos(ang) * r, y: pool.centre.y + sin(ang) * r * 0.9)
                    let turn = Float.random(in: 0...(2 * .pi), using: &rng)
                    switch season.id {
                    case "winter":
                        let ice = ["ice_1", "ice_2", "ice_3", "ice_4", "ice_5", "ice_8", "ice_9", "ice_10"].randomElement(using: &rng)!
                        let sz = CGFloat.random(in: 30...56, using: &rng)
                        dressing.append(Sprite(ice, at: p, size: CGSize(width: sz, height: sz * 0.7), rotation: turn, mode: .floater, alpha: 1, z: 0.02))
                    case "spring":
                        let petal = "petal_n_\(Int.random(in: 1...6, using: &rng))"
                        let sz = CGFloat.random(in: 22...34, using: &rng)
                        dressing.append(Sprite(petal, at: p, size: CGSize(width: sz, height: sz), rotation: turn, mode: .floater, alpha: 1))
                    case "summer":
                        let name = k == 0 ? "lotus_1" : "lilypad_\(Int.random(in: 2...3, using: &rng))"
                        let sz = k == 0 ? CGFloat(72) : CGFloat.random(in: 40...60, using: &rng)
                        dressing.append(Sprite(name, at: p, size: CGSize(width: sz, height: sz), rotation: turn, mode: .floater, alpha: 1))
                    default:
                        let leaf = "leaf_\(Int.random(in: 1...3, using: &rng))"
                        let sz = CGFloat.random(in: 30...46, using: &rng)
                        dressing.append(Sprite(leaf, at: p, size: CGSize(width: sz, height: sz), rotation: turn, mode: .floater, alpha: 1))
                    }
                }
            }
        }
        snow = (0..<60).map { _ in
            (CGFloat.random(in: 0...w, using: &rng), CGFloat.random(in: winterBand, using: &rng),
             Float.random(in: 0...(2 * .pi), using: &rng), CGFloat.random(in: 6...13, using: &rng))
        }
    }

    // MARK: - The stream's shape

    /// Unit depth: the channel is shallow and narrow, the pools deep and
    /// round, the banks nearly dry so waves die there and sand shows.
    private func depth(at p: CGPoint) -> Float {
        let w = Float(viewSize.width), h = Float(viewSize.height)
        let x = Float(p.x) * w, y = Float(p.y) * h
        var d: Float = 0.05
        // The channel meanders with the pools.
        var half: Float = w * 0.19
        var pull: Float = 0
        var poolD: Float = 0
        for pool in pools {
            let dx = x - Float(pool.centre.x), dy = y - Float(pool.centre.y)
            let r = Float(pool.radius)
            let dist = (dx * dx + dy * dy).squareRoot()
            if dist < r * 1.45 {
                // A soft bowl: the bed shelves gently up to the bank.
                let t = max(0, min(1, (r * 1.45 - dist) / (r * 0.9)))
                poolD = max(poolD, 0.3 + 0.7 * t * t * (3 - 2 * t))
            }
            // Nearby pools bend the channel toward them.
            let ady = abs(dy)
            if ady < r * 2.6 {
                let wgt = 1 - ady / (r * 2.6)
                pull += (Float(pool.centre.x) - w / 2) * wgt
            }
        }
        half = w * 0.16
        let centreX = w / 2 + pull * 0.6
        let off = abs(x - centreX)
        let channel: Float = 0.42 * (1 - smooth(half - 70, half + 50, off))
        d = max(d, max(channel, poolD))
        // Head and mouth of the stream: shallows.
        let ends = smooth(h * 0.02, h * 0.05, y) * (1 - smooth(h * 0.95, h * 0.985, y))
        return max(0.05, d * (0.3 + 0.7 * ends))
    }

    private func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    private func paintDepth(width: Int, height: Int) -> [Float] {
        var map = [Float](repeating: 1, count: width * height)
        guard viewSize.width > 0 else { return map }
        for y in 0..<height {
            for x in 0..<width {
                map[y * width + x] = depth(at: CGPoint(x: CGFloat(x) / CGFloat(width), y: CGFloat(y) / CGFloat(height)))
            }
        }
        return map
    }

    // MARK: - Per frame

    private func frame(dt: Float) {
        guard let renderer else { return }
        elapsed += dt
        let now = CACurrentMediaTime()
        if viewSize == .zero, let world = renderer.worldSizePoints, let screen = renderer.viewSizePoints, world.width > 0 {
            viewSize = world
            screenSize = screen
            place()
            renderer.rebuildDepth()
        }
        guard placed else { return }

        // Drift: momentum from the last drag, eased and kept on the stream.
        if scroll == nil, abs(momentum) > 1 {
            centreTarget.y += momentum * dt
            momentum *= exp(-dt * 2.4)
        }
        renderer.zoom += (zoomTarget - renderer.zoom) * min(1, dt * 4)
        let halfH = Float(screenSize.height) / renderer.zoom / 2
        centreTarget.y = max(halfH, min(Float(viewSize.height) - halfH, centreTarget.y))
        if opening == nil { centreTarget.x = Float(viewSize.width) / 2 }
        renderer.viewCentre += (centreTarget - renderer.viewCentre) * min(1, dt * (opening == nil ? 9 : 4))

        // Snow drifts down over the source and starts again at its head.
        for i in snow.indices {
            snow[i].phase += dt * 0.8
            snow[i].y += CGFloat(dt) * (14 + snow[i].size)
            snow[i].x += CGFloat(sin(snow[i].phase)) * 0.4
            if snow[i].y > winterBand.upperBound { snow[i].y = winterBand.lowerBound }
        }

        // Weed tips read the water.
        let samples = renderer.latestSamples()
        var weedSamples: [Int: FieldSample] = [:]
        let tips = garden.weedTips()
        for (i, _) in tips.enumerated() where i < samples.count { weedSamples[i] = samples[i] }
        garden.weedSamples = weedSamples
        var cells: [SIMD2<Float>] = []
        for tip in tips {
            if let c = renderer.cell(for: tip, in: viewSize) { cells.append(c) }
        }
        renderer.setProbes(cells)

        garden.update(dt: dt, now: now)
        for s in garden.splashes { renderer.addSplat(at: s.at, in: viewSize, radius: s.radius, amplitude: s.amplitude) }
        garden.splashes.removeAll()

        feed(renderer)

        if let o = opening, now - o.at > 0.75 {
            opening = nil
            onPlay?(o.level)
        }
        if now - lastMarksAt > 0.08 {
            lastMarksAt = now
            marks = pools.map { pool in
                let idx = Library.levels(in: pool.season).firstIndex { $0.id == pool.level.id } ?? 0
                return Mark(id: pool.level.id, level: pool.level, season: pool.season,
                            screen: renderer.screenPoint(world: pool.centre), radius: pool.radius * CGFloat(renderer.zoom),
                            unlocked: progress.isUnlocked(level: pool.level), complete: progress.isComplete(levelID: pool.level.id),
                            first: idx == 0)
            }
        }
    }

    private func feed(_ renderer: WaterRenderer) {
        renderer.walls = []
        renderer.siltCovers = []
        renderer.camera = garden.camera
        let submerged = garden.submergedSprites()
        renderer.spines = submerged.spines
        var under = submerged.sprites
        under += garden.reflectionSprites()
        for pool in pools {
            let rock = garden.rocks.first { hypot($0.centre.x - pool.centre.x, $0.centre.y - pool.centre.y) < pool.radius }
            if let r = rock {
                let side = r.radius * 2.3
                under.append(Sprite(art.rock, at: CGPoint(x: r.centre.x + 6, y: r.centre.y + 9),
                                    size: CGSize(width: side, height: side * 0.8), mode: .shadow, alpha: 0.5, z: -1.0))
            }
        }
        renderer.submergedSprites = under

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
        // Each pool: a stone at its shoulder, a lily pad with the bud that
        // opens once the level is done; a sleeping season lies under mist.
        var solids: [SolidInstance] = []
        for s in dressing { paper(s) }
        for pool in pools {
            let unlocked = progress.isUnlocked(level: pool.level)
            let done = progress.isComplete(levelID: pool.level.id)
            let stone = CGPoint(x: pool.centre.x + pool.radius * 0.7, y: pool.centre.y - pool.radius * 0.55)
            let winter = pool.season.id == "winter"
            let r: Float = 22 * 0.95
            solids.append(SolidInstance(position: SIMD2(Float(stone.x), Float(stone.y)), lift: r * 0.35,
                                        yaw: Float(pool.centre.y * 0.013), roll: Float(pool.centre.x * 0.37 + pool.centre.y * 0.11),
                                        tilt: .zero, length: r * 1.35, radius: r, shape: 2, alpha: 1,
                                        colourA: winter ? [0.62, 0.66, 0.72, 1] : [0.50, 0.53, 0.52, 1],
                                        colourB: winter ? [0.62, 0.66, 0.72, 1] : [0.36, 0.55, 0.30, 1]))
            let pad = CGPoint(x: pool.centre.x - pool.radius * 0.55, y: pool.centre.y + pool.radius * 0.5)
            over.append(Sprite("lilypad_1", at: CGPoint(x: pad.x + 3, y: pad.y + 4), size: CGSize(width: 62, height: 62), mode: .shadow, alpha: 0.3, z: 0))
            paper(Sprite("lilypad_1", at: pad, size: CGSize(width: 58, height: 58), rotation: Float(pool.centre.y * 0.01), mode: .floater, alpha: 1))
            let bud = done ? "bud_open" : "bud_closed"
            paper(Sprite(bud, at: CGPoint(x: pad.x + 2, y: pad.y - 4), size: CGSize(width: 44, height: 44), mode: .floater, alpha: unlocked ? 1 : 0.35))
            if !unlocked {
                // Mist: cloud sprites low over the pool.
                for k in 0..<2 {
                    let c = CGPoint(x: pool.centre.x + CGFloat(k * 70 - 35) + CGFloat(sin(Double(elapsed) * 0.13 + Double(k))) * 18,
                                    y: pool.centre.y + CGFloat(k * 24 - 12))
                    over.append(Sprite(art.clouds[k % max(1, art.clouds.count)], at: c, size: CGSize(width: 320, height: 200),
                                       mode: .floater, alpha: 0.28, z: 0.3))
                }
            }
        }
        for s in garden.skaterSprites() { paper(s) }
        for s in garden.petalSprites() { paper(s) }
        for s in stretchBranches { paper(s, cast: 18) }
        for f in snow {
            over.append(Sprite("snow_2", at: CGPoint(x: f.x, y: f.y), size: CGSize(width: f.size, height: f.size),
                               rotation: f.phase, mode: .floater, alpha: 0.85, z: 0.5))
        }
        over += garden.skySprites()
        renderer.surfaceSprites = over
        renderer.contactShadows = []
        renderer.solids = solids
    }

    // MARK: - Touch

    private func worldPoint(_ p: CGPoint) -> CGPoint { renderer?.worldPoint(screen: p) ?? p }

    func touchBegan(id: Int, at screen: CGPoint, in size: CGSize, weight: Float) {
        screenSize = size
        guard placed, opening == nil else { return }
        let now = CACurrentMediaTime()
        pending[id] = (screen, now)
        if scroll == nil { scroll = (id, screen.y, now, false, screen.y) }
        momentum = 0
    }

    func touchMoved(id: Int, to screen: CGPoint, in size: CGSize) {
        guard var s = scroll, s.id == id, let renderer else { return }
        let dy = screen.y - s.lastY
        let now = CACurrentMediaTime()
        if !s.moved, abs(screen.y - s.startY) > 8 { s.moved = true }
        if s.moved {
            centreTarget.y -= Float(dy) / renderer.zoom
            let dt = Float(max(0.004, now - s.lastAt))
            momentum = momentum * 0.6 + (-Float(dy) / renderer.zoom / dt) * 0.4
            // The finger drags the water too: a faint wake.
            renderer.addSplat(at: worldPoint(screen), in: viewSize, radius: 10, amplitude: -0.03)
        }
        s.lastY = screen.y
        s.lastAt = now
        scroll = s
    }

    func touchEnded(id: Int, at screen: CGPoint, in size: CGSize) {
        let wasScroll = scroll?.id == id ? scroll?.moved ?? false : false
        if scroll?.id == id { scroll = nil }
        guard let start = pending.removeValue(forKey: id), let renderer else { return }
        if wasScroll { return }
        if abs(momentum) > 600 { momentum = 600 * (momentum < 0 ? -1 : 1) }
        momentum = 0
        let point = worldPoint(screen)
        // A tap: a ripple, the life startles, and a pool opens.
        renderer.touchDown(id: id, at: point, in: viewSize, weight: 0.5)
        renderer.touchUp(id: id)
        garden.startle(at: point, in: viewSize)
        if CACurrentMediaTime() - start.began < 0.45,
           let pool = pools.first(where: { hypot($0.centre.x - point.x, $0.centre.y - point.y) < $0.radius }),
           progress.isUnlocked(level: pool.level) {
            renderer.addSplat(at: pool.centre, in: viewSize, radius: 40, amplitude: -0.6)
            // The dive: the camera drops toward the pool as the water closes.
            centreTarget = SIMD2(Float(pool.centre.x), Float(pool.centre.y))
            zoomTarget = 1.6
            opening = (pool.level, CACurrentMediaTime())
        }
    }
}
