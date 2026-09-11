import CoreGraphics
import Foundation
import QuartzCore
import SwiftUI
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

    private var entries: [(name: String, y: CGFloat)] = []
    private var mouthY: CGFloat = 0
    /// The level a splash is opening, once the water has closed over the tap.
    var onPlay: ((LevelSpec) -> Void)?
    private var storeNote: CGPoint = .zero
    /// The menu that is up, when one is. The view draws it over the stream.
    @Published private(set) var presented: MenuScreen?
    /// `-showMenu settings|store`, so a menu can be seen without a finger.
    private var pendingMenu: String? = {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-showMenu"), i + 1 < args.count { return args[i + 1] }
        if args.contains("-showSettings") { return "settings" }
        if args.contains("-showStore") { return "store" }
        return nil
    }()

    static let worldScale = CGSize(width: 1.15, height: 4.0)
    static let gridLongSide = 1400

    private(set) var pools: [Pool] = []
    /// Weak, like the level's: the Metal view owns the renderer, and the
    /// hub must not keep a whole second one alive while a level plays.
    private weak var renderer: WaterRenderer?
    private var garden: Garden
    private let art: ArtSet
    private var viewSize = CGSize.zero
    private var screenSize = CGSize.zero
    private var centreTarget = SIMD2<Float>(0, 0)
    private var momentum: Float = 0
    private var scroll: (id: Int, lastY: CGFloat, lastAt: TimeInterval, moved: Bool, startY: CGFloat)?
    private var pending: [Int: (start: CGPoint, began: TimeInterval)] = [:]
    private var touches: [Int: CGPoint] = [:]
    /// Two fingers drawn the same way up or down the screen tilt the camera,
    /// the same as they do on a pond.
    private struct Tilt {
        var ids: [Int]
        var last: [Int: CGPoint]
        var travel: [Int: CGPoint] = [:]
        var speed: [Int: CGFloat] = [:]
        var lastAt: TimeInterval
        var on = false
    }
    private var tilt: Tilt?
    private var lastMarksAt: TimeInterval = 0
    private var opening: (level: LevelSpec, at: TimeInterval)?
    private var elapsed: Float = 0
    private let progress = ProgressStore.shared
    let sound = SoundDirector()
    let haptics = Haptics()
    private var placed = false
    private var zoomTarget: Float = 0.9
    /// Things laid along each stretch so the year shows: ice at the source,
    /// petals, lotus, leaves; and the season's branches over the bank.
    private var dressing: [Sprite] = []
    private var stretchBranches: [Sprite] = []
    private var snow: [(x: CGFloat, y: CGFloat, phase: Float, size: CGFloat)] = []
    private var winterBand: ClosedRange<CGFloat> = 0...0
    /// The lips between seasons: a shelf of stones the stream pours over.
    private var lips: [CGFloat] = []
    private var foam: [(x: CGFloat, y: CGFloat, phase: Float, size: CGFloat)] = []
    private var shoreStones: [SolidInstance] = []
    /// The source lies in mist, so the world does not end in a line.
    private var sourceMist: [(x: CGFloat, y: CGFloat, phase: Float, size: CGFloat)] = []
    /// Haze lying over each stretch, which thins as the stretch's pools wake.
    private var stretchMist: [(season: String, x: CGFloat, y: CGFloat, phase: Float, size: CGFloat, texture: String)] = []

    // MARK: - What each pool has been woken into

    /// Read from the store once per change, never fetched in the frame.
    private struct PoolState {
        var unlocked = false
        var done = false
        var tokens: Set<WokeToken> = []
    }
    private var states: [PoolState] = []
    private var statesVersion = -1
    /// How much of each season's stretch is awake, 0 to 1, by season id.
    private var wokeFraction: [String: Float] = [:]
    /// The life each pool keeps, parallel to `pools`.
    private var life: [PoolLife] = []
    /// The koi and the small fish the pools are given, one kind per pool.
    private let koiKinds = ["n_koi_1", "n_koi_5", "n_koi_3", "n_koi_2", "n_koi_6", "n_koi_4"]
    private let shoalKinds = ["minnow_1", "rudd_1", "stickleback_1", "minnow_2", "rudd_2", "stickleback_2"]

    init() {
        // Spring dresses the stream; the seasons show in what sits at each
        // pool. The garden's own koi and shoals stay out of the hub: every
        // pool starts dormant with no fish showing, and the fish a pool has
        // are the ones its level woke, which the hub keeps itself.
        var a = Library.springWoodblock
        a.koi = []
        a.shoal = []
        a.branch = []          // each stretch hangs its own season's branches
        art = a
        garden = Garden(art: a)
    }

    // MARK: - Wiring

    func attach(renderer: WaterRenderer) {
        // An older view still fading out must stop driving the hub, or the
        // stream would be stepped twice a frame.
        self.renderer?.onFrame = nil
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
        renderer.bank = SIMD3(1, 0.915, (0.915 - 0.06) / 4)
        renderer.floorLook = look
        renderer.depthPainter = { [weak self] w, h in self?.paintDepth(width: w, height: h) ?? Array(repeating: 1, count: w * h) }
        renderer.rebuildDepth()
        garden.textureSize = { [weak renderer] name in renderer?.textures.size(name) ?? CGSize(width: 1, height: 1) }
        renderer.onFrame = { [weak self] dt in self?.frame(dt: dt) }
        renderer.zoom = 0.9
        sound.blendAmbience(["amb_stream": 0.5])
        nextLifeSoundAt = 6
    }

    // MARK: - The air along the stream

    /// The stream's air is the season the camera is over: the brook runs
    /// under everything, quieter than before, and each season's own
    /// recording comes up as its stretch fills the screen and gives way
    /// to the next over a pool's length at the lip between them. Now and
    /// then something lives in it: a bird, a frog, a creak of ice, leaves.
    private var airUpdateAt: Float = 0
    private var nextLifeSoundAt: Float = 0

    private func updateAir(dt: Float) {
        guard let renderer, placed else { return }
        airUpdateAt -= dt
        let seasons = Library.seasons
        let y = CGFloat(renderer.viewCentre.y)
        let h = viewSize.height
        let top = h * 0.06, bottom = h * 0.915
        let stretch = (bottom - top) / CGFloat(seasons.count)
        // Position up the stream in stretches: 0 at the mouth (winter), 4 at the source.
        let u = max(0, min(CGFloat(seasons.count) - 0.001, (bottom - y) / stretch))
        if airUpdateAt <= 0 {
            airUpdateAt = 0.25
            var shares: [String: Float] = ["amb_stream": 0.45]
            let i = Int(u)
            let f = u - CGFloat(i)
            // Blend across the lip: the last fifth of one stretch and the
            // first fifth of the next share the air.
            let blend: CGFloat = 0.2
            var wHere: CGFloat = 1, wNext: CGFloat = 0
            if f > 1 - blend, i + 1 < seasons.count {
                wNext = (f - (1 - blend)) / (2 * blend)
                wHere = 1 - wNext
            } else if f < blend, i > 0 {
                let wPrev = (blend - f) / (2 * blend)
                shares["amb_\(seasons[i - 1].id)"] = Float(wPrev) * 0.9
                wHere = 1 - wPrev
            }
            shares["amb_\(seasons[i].id)"] = Float(wHere) * 0.9
            if wNext > 0 { shares["amb_\(seasons[i + 1].id)"] = Float(wNext) * 0.9 }
            sound.blendAmbience(shares)
        }
        // Sparse life, from the season under the camera.
        if elapsed > nextLifeSoundAt {
            nextLifeSoundAt = elapsed + Float.random(in: 14...32)
            let x = Float.random(in: 0.15...0.85)
            switch seasons[Int(u)].id {
            case "winter": sound.iceCrack(x: x, gain: 0.22)
            case "spring": sound.bird(x: x)
            case "summer": sound.frog(x: x, gain: 0.5)
            default: sound.leaves(x: x)
            }
        }
    }

    private func place() {
        let w = viewSize.width, h = viewSize.height
        pools = []
        let seasons = Library.seasons
        // The mouth is at the bottom and the source at the top: the year is
        // walked upstream, winter first.
        let top = h * 0.06, bottom = h * 0.915
        let stretch = (bottom - top) / CGFloat(seasons.count)
        for (si, season) in seasons.enumerated() {
            let levels = Library.levels(in: season)
            for (li, level) in levels.enumerated() {
                let t = (CGFloat(li) + 0.5) / CGFloat(levels.count)
                let y = bottom - stretch * CGFloat(si) - stretch * t
                let side: CGFloat = (si * levels.count + li) % 2 == 0 ? -1 : 1
                let x = w * (0.5 + side * 0.13)
                pools.append(Pool(level: level, season: season, centre: CGPoint(x: x, y: y), radius: min(w * 0.22, 118)))
            }
        }
        lips = (1..<seasons.count).map { bottom - stretch * CGFloat($0) }
        entries = seasons.enumerated().map { ($0.element.name, bottom - stretch * CGFloat($0.offset) - 34) }
        mouthY = bottom + 92
        storeNote = CGPoint(x: w * 0.5, y: top - 34)
        sourceMist = []
        for end in [top - 70, bottom + 170] {
            for k in 0..<7 {
                let x: CGFloat = CGFloat(k) / 6 * w
                let y: CGFloat = end + CGFloat.random(in: -30...50)
                let phase: Float = Float.random(in: 0...(2 * .pi))
                let size: CGFloat = CGFloat.random(in: 260...360)
                sourceMist.append((x, y, phase, size))
            }
        }
        garden.depthAt = { [weak self] p in
            guard let self else { return 1 }
            return self.depth(at: CGPoint(x: p.x / self.viewSize.width, y: p.y / self.viewSize.height))
        }
        garden.configure(art: art, size: viewSize, bloomStage: 1.5)
        // The map lies under more mist than any pond: the world has to end
        // in weather rather than in a line.
        garden.mistAmount = 0.9
        garden.rocks = pools.map { (CGPoint(x: $0.centre.x + $0.radius * 0.7, y: $0.centre.y - $0.radius * 0.55), 22) }
        // What each pool has woken, before the banks are planted: a stretch
        // with more of its pools awake grows more along its banks.
        statesVersion = -1
        refreshStates()
        // Start at the source, on the first pool not yet done.
        guard let first = pools.first else { placed = true; return }
        let start = pools.first { !progress.isComplete(levelID: $0.level.id) } ?? first
        centreTarget = SIMD2(Float(viewSize.width / 2), Float(start.centre.y))
        if ProcessInfo.processInfo.arguments.contains("-hubTop") { centreTarget.y = Float(top) }
        // `-hubTap`: a scripted tap on the first pool after three seconds.
        if ProcessInfo.processInfo.arguments.contains("-hubTap") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, let r = self.renderer, let pool = self.pools.first else { return }
                let sp = r.screenPoint(world: pool.centre)
                self.touchBegan(id: 77, at: sp, in: self.screenSize, weight: 0.5)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.touchEnded(id: 77, at: sp, in: self.screenSize) }
            }
        }
        renderer?.viewCentre = centreTarget
        dress(bottom: bottom, stretch: stretch)
        placed = true
    }

    /// The year along the stream: each season's branches over its stretch,
    /// ice around the winter pools, blossom in spring, lotus in summer,
    /// leaves in autumn, and snow in the air at the source.
    private func dress(bottom: CGFloat, stretch: CGFloat) {
        dressing = []
        stretchBranches = []
        shoreStones = []
        var rng = SystemRandomNumberGenerator()
        let w = viewSize.width
        for (si, season) in Library.seasons.enumerated() {
            let y1 = bottom - stretch * CGFloat(si)          // where the stretch is entered
            let a = season.woodblock
            // Branches reach in from both banks where the stretch is entered.
            if a.branch.count > 2 {
                let name = a.branch[si == 0 ? 1 : 2]
                let side = w * a.branchScale * 0.62
                let head = y1 + stretch * 0.06
                stretchBranches.append(Sprite(name, at: CGPoint(x: side * 0.32 - a.branchInset, y: head - side * 0.12),
                                              size: CGSize(width: side, height: side), z: 0.9))
                let small = side * 0.8
                stretchBranches.append(Sprite(name, at: CGPoint(x: w - small * 0.3 + a.branchInset, y: head + small * 0.05),
                                              size: CGSize(width: small, height: small), flipX: true, z: 0.9))
            }
            if si == 0 { winterBand = (y1 - stretch)...(y1 + 40) }
            for (pi, pool) in pools.enumerated() where pool.season.id == season.id {
                let awake = pi < states.count && states[pi].done
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
                        // The flower only where the pool is awake; asleep, pads.
                        let name = k == 0 && awake ? "lotus_1" : "lilypad_\(Int.random(in: 2...3, using: &rng))"
                        let sz = k == 0 && awake ? CGFloat(72) : CGFloat.random(in: 40...60, using: &rng)
                        dressing.append(Sprite(name, at: p, size: CGSize(width: sz, height: sz), rotation: turn, mode: .floater, alpha: 1))
                    default:
                        let leaf = "leaf_\(Int.random(in: 1...3, using: &rng))"
                        let sz = CGFloat.random(in: 30...46, using: &rng)
                        dressing.append(Sprite(leaf, at: p, size: CGSize(width: sz, height: sz), rotation: turn, mode: .floater, alpha: 1))
                    }
                }
            }
        }
        foam = lips.flatMap { lip in
            (0..<14).map { _ in
                (CGFloat.random(in: (w * 0.22)...(w * 0.78), using: &rng), lip + CGFloat.random(in: -6...18, using: &rng),
                 Float.random(in: 0...(2 * .pi), using: &rng), CGFloat.random(in: 26...46, using: &rng))
            }
        }
        // Haze over each stretch: wisps of the mist the ponds wear, laid
        // between the pools. How much of it shows is decided each frame by
        // how much of the stretch is awake.
        stretchMist = []
        for (si, season) in Library.seasons.enumerated() {
            let y1 = bottom - stretch * CGFloat(si)
            for k in 0..<4 {
                stretchMist.append((season.id,
                                    w * (0.2 + 0.6 * CGFloat(k % 2) + CGFloat.random(in: -0.08...0.08, using: &rng)),
                                    y1 - stretch * (CGFloat(k) + 0.5) / 4 + CGFloat.random(in: -30...30, using: &rng),
                                    Float.random(in: 0...(2 * .pi), using: &rng),
                                    CGFloat.random(in: 300...420, using: &rng),
                                    k % 2 == 0 ? "mist_1" : "mist_2"))
            }
        }
        plantBanks(&rng)
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
            if dist < r * 1.6 {
                // A soft bowl with a ragged rim: the bed shelves gently up to
                // a bank that is never a circle.
                let ang = atan2(dy, dx)
                let rim = r * (1.45 + (noise(ang * 1.4 + 20, Float(pool.centre.y) * 0.01) - 0.5) * 0.36)
                let t = max(0, min(1, (rim - dist) / (r * 0.9)))
                poolD = max(poolD, 0.3 + 0.7 * t * t * (3 - 2 * t))
            }
            // Nearby pools bend the channel toward them.
            let ady = abs(dy)
            if ady < r * 2.6 {
                let wgt = 1 - ady / (r * 2.6)
                pull += (Float(pool.centre.x) - w / 2) * wgt
            }
        }
        // The shore wanders: a slow swell of width and a finer raggedness,
        // different on each side.
        let side: Float = x < w / 2 ? 0 : 7
        let wander = (noise(y / 190 + side, 3.1) - 0.5) * 60 + (noise(y / 48 + side, 9.7) - 0.5) * 18
        half = w * 0.16 + wander
        let centreX = w / 2 + pull * 0.6
        let off = abs(x - centreX)
        let channel: Float = 0.42 * (1 - smooth(half - 70, half + 50, off))
        d = max(d, max(channel, poolD))
        // Head and mouth of the stream: shallows.
        let ends = smooth(h * 0.02, h * 0.05, y) * (1 - smooth(h * 0.95, h * 0.985, y))
        d *= 0.3 + 0.7 * ends
        // Between seasons the stream pours over a lip of stones: shallow
        // right across, with a notch in the middle where it runs through.
        for lip in lips {
            let dy = abs(y - Float(lip))
            if dy < 26 {
                let across = 1 - smooth(8, 26, dy)
                let notch = 1 - smooth(22, 48, abs(x - centreX))
                d = min(d, max(0.14, d * (1 - across * (1 - notch) * 0.8)))
            }
        }
        return max(0.05, d)
    }

    /// The shoreline wanders on the same noise the ponds use.
    private func noise(_ x: Float, _ y: Float) -> Float { ShoreNoise.value(x, y) }

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

    /// Tufts of grass, roots reaching into the water, reeds and the odd
    /// stone along both banks, found by walking down the stream and looking
    /// for where the bed comes out of the water.
    private func plantBanks(_ rng: inout SystemRandomNumberGenerator) {
        let w = viewSize.width, h = viewSize.height
        var y: CGFloat = h * 0.03
        var sinceRoot: [CGFloat] = [400, 250]
        while y < h * 0.985 {
            for side in 0..<2 {
                // Walk in from the edge until the water starts.
                var x: CGFloat = side == 0 ? 4 : w - 4
                let step: CGFloat = side == 0 ? 6 : -6
                var found: CGPoint?
                for _ in 0..<80 {
                    if depth(at: CGPoint(x: x / w, y: y / h)) > 0.1 { found = CGPoint(x: x - step * 2.5, y: y); break }
                    x += step
                }
                guard let edge = found else { continue }
                let winter = y > winterBand.lowerBound
                // The stretch this point falls in, kept inside the seasons we
                // actually have so a fifth season never walks off the end.
                let stretchIndex = Int((0.915 - y / h) / ((0.915 - 0.06) / 4))
                let seasonIndex = min(Library.seasons.count - 1, max(0, stretchIndex))
                let reedSet = Library.seasons[seasonIndex].woodblock.reeds
                let flip = side == 1
                // A sleeping stretch has half the growth of one that is all
                // awake: the tufts and reeds come with the pools.
                let woke = CGFloat(wokeFraction[Library.seasons[seasonIndex].id] ?? 0)
                let growth = 0.5 + 0.5 * woke
                let roll = CGFloat.random(in: 0...1, using: &rng)
                sinceRoot[side] += 55
                // The waterline itself: pebbles, gravel and mud at the edge,
                // some half in the water, and now and then a stone sitting in it.
                for _ in 0..<Int.random(in: 1...3, using: &rng) {
                    let kind = Int.random(in: 0...9, using: &rng)
                    let name = kind < 5 ? "stone_a_\(Int.random(in: 1...8, using: &rng))"
                             : kind < 8 ? "gravel_\(Int.random(in: 1...4, using: &rng))"
                                        : "sand_\(Int.random(in: 1...3, using: &rng))"
                    let sz = kind < 5 ? CGFloat.random(in: 12...26, using: &rng) : CGFloat.random(in: 30...50, using: &rng)
                    let along = CGFloat.random(in: -26...26, using: &rng)
                    let inOut = CGFloat.random(in: -10...16, using: &rng)   // minus: into the water
                    let at = CGPoint(x: edge.x + (flip ? -inOut : inOut), y: edge.y + along)
                    dressing.append(Sprite(name, at: at, size: CGSize(width: sz, height: sz * 0.8),
                                           rotation: Float.random(in: 0...(2 * .pi), using: &rng), mode: .floater,
                                           alpha: kind < 5 ? 1 : 0.8, tint: kind < 5 ? [1, 1, 1, 1] : [0.62, 0.6, 0.55, 1], z: 0.015 + (inOut > 0 ? 0.06 : 0)))
                }
                if CGFloat.random(in: 0...1, using: &rng) < 0.12 {
                    // A stone in the shallows, half out of the water.
                    let r: Float = Float.random(in: 14...24, using: &rng)
                    let at = CGPoint(x: edge.x + (flip ? -CGFloat(r) * 0.9 : CGFloat(r) * 0.9), y: edge.y)
                    let cold = winter
                    shoreStones.append(SolidInstance(position: SIMD2(Float(at.x), Float(at.y)), lift: r * 0.3,
                                                     yaw: Float.random(in: 0...3, using: &rng), roll: Float(at.x * 0.13 + at.y * 0.07),
                                                     tilt: .zero, length: r * 1.4, radius: r, shape: 2, alpha: 1,
                                                     colourA: cold ? [0.6, 0.63, 0.68, 1] : [0.52, 0.53, 0.5, 1],
                                                     colourB: cold ? [0.6, 0.63, 0.68, 1] : [0.38, 0.5, 0.3, 1]))
                }
                if sinceRoot[side] > CGFloat.random(in: 380...640, using: &rng) {
                    sinceRoot[side] = 0
                    let name = "root_\(Int.random(in: 1...2, using: &rng))"
                    let len = CGFloat.random(in: 110...170, using: &rng)
                    let at = CGPoint(x: edge.x + (flip ? -len * 0.28 : len * 0.28), y: edge.y)
                    dressing.append(Sprite(name, at: at, size: CGSize(width: len, height: len * 0.38),
                                           rotation: Float.random(in: -0.25...0.25, using: &rng), mode: .floater, alpha: 1, flipX: flip, z: 0.075))
                } else if roll < 0.5 * growth {
                    let name = "tuft_\(Int.random(in: 1...3, using: &rng))"
                    let sz = CGFloat.random(in: 36...60, using: &rng)
                    // Rooted on the bank, leaning a little out over the water.
                    let at = CGPoint(x: edge.x + (flip ? sz * 0.18 : -sz * 0.18), y: edge.y + CGFloat.random(in: -12...12, using: &rng))
                    let lean: Float = flip ? .pi : 0
                    dressing.append(Sprite(name, at: at, size: CGSize(width: sz, height: sz * 0.55),
                                           rotation: lean + Float.random(in: -0.5...0.5, using: &rng), mode: .floater, alpha: winter ? 0.75 : 1, z: 0.09))
                } else if roll < 0.78 * growth, !reedSet.isEmpty {
                    let name = reedSet.randomElement(using: &rng)!
                    let ht = CGFloat.random(in: 70...110, using: &rng)
                    let t = garden.textureSize(name)
                    let at = CGPoint(x: edge.x + (flip ? 14 : -14), y: edge.y - ht * 0.42)
                    dressing.append(Sprite(name, at: at, size: CGSize(width: ht * t.width / max(1, t.height), height: ht),
                                           rotation: Float.random(in: -0.2...0.2, using: &rng), mode: .floater, alpha: 1, flipX: flip, z: 0.32))
                }
            }
            y += 55
        }
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
        updateAir(dt: dt)

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

        // The pools' own life, only where the camera can see it.
        refreshStates()
        let viewY = CGFloat(renderer.viewCentre.y)
        let reach = CGFloat(screenSize.height) / CGFloat(max(0.3, renderer.zoom)) * 0.75 + 180
        for i in life.indices where abs(pools[i].centre.y - viewY) < reach {
            life[i].koi?.update(dt: dt, now: now)
            life[i].shoal?.update(dt: dt)
            if let k = life[i].koi, k.mouthed {
                // A koi at the surface takes a mouthful: a bead of a ring.
                renderer.addSplat(at: k.position, in: viewSize, radius: 5, amplitude: -0.03)
            }
        }

        if let flag = pendingMenu, elapsed > 1.0 {
            pendingMenu = nil
            switch flag {
            case "settings": openSettings()
            case "store": openStore()
            default: break
            }
        }

        feed(renderer)

        if let o = opening, now - o.at > 0.75 {
            opening = nil
            sound.stopAmbience()
            onPlay?(o.level)
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
        var paintings: [String] = []
        func painting(_ name: String) -> UInt32 {
            if let i = paintings.firstIndex(of: name) { return UInt32(i + 1) }
            paintings.append(name)
            return UInt32(paintings.count)
        }
        let koiBodies = garden.koiBodies(depthScale: WaterRenderer.depthScale, textureIndex: painting,
                                              tailCentre: { renderer.textures.tailCentre($0) })
        var underBodies = koiBodies.under
        underBodies += garden.bedStoneBodies(depthScale: WaterRenderer.depthScale, mossy: true)
        for pool in pools {
            let rock = garden.rocks.first { hypot($0.centre.x - pool.centre.x, $0.centre.y - pool.centre.y) < pool.radius }
            if let r = rock {
                let side = r.radius * 2.3
                under.append(Sprite(art.rock, at: CGPoint(x: r.centre.x + 6, y: r.centre.y + 9),
                                    size: CGSize(width: side, height: side * 0.8), mode: .shadow, alpha: 0.5, z: -1.0))
            }
        }

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
        var solids: [SolidInstance] = shoreStones
        // A pad or a lotus lying on the water is a body like the pool's own:
        // a thin disc wearing its painting, with a shadow under it. The rest
        // of the dressing is still cut paper.
        for s in dressing {
            let name = s.texture
            guard name.hasPrefix("lilypad") || name.hasPrefix("lotus") else { paper(s); continue }
            let c = CGPoint(x: CGFloat(s.gpu.center.x), y: CGFloat(s.gpu.center.y))
            let side = CGFloat(s.gpu.size.x)
            over.append(Sprite(name, at: CGPoint(x: c.x + 3, y: c.y + 4),
                               size: CGSize(width: side, height: side), mode: .shadow, alpha: 0.28, z: 0))
            solids.append(SolidInstance(position: SIMD2(Float(c.x), Float(c.y)),
                                        lift: name.hasPrefix("lotus") ? 3.5 : 1.5,
                                        yaw: s.gpu.rotation, roll: 0, texture: painting(name), tilt: .zero,
                                        length: 3, radius: Float(side) * 0.5, shape: 4, alpha: 1,
                                        colourA: [0.16, 0.36, 0.22, 1], colourB: [0.16, 0.36, 0.22, 1]))
        }
        let viewY = CGFloat(renderer.viewCentre.y)
        let reach = CGFloat(screenSize.height) / CGFloat(max(0.3, renderer.zoom)) * 0.75 + 180
        let night = nightAmount(renderer.dayPhase)
        for (i, pool) in pools.enumerated() {
            let state = i < states.count ? states[i] : PoolState()
            let unlocked = state.unlocked
            let done = state.done
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
            solids.append(SolidInstance(position: SIMD2(Float(pad.x), Float(pad.y)), lift: 1.5, yaw: Float(pool.centre.y * 0.01), roll: 0,
                                        texture: painting("lilypad_1"), tilt: .zero, length: 3, radius: 29, shape: 4, alpha: 1,
                                        colourA: [0.16, 0.36, 0.22, 1], colourB: [0.16, 0.36, 0.22, 1]))
            let bud = done ? "bud_open" : "bud_closed"
            solids.append(SolidInstance(position: SIMD2(Float(pad.x + 2), Float(pad.y - 4)), lift: 4.5, yaw: 0, roll: 0,
                                        texture: painting(bud), tilt: .zero, length: 3, radius: 22, shape: 4, alpha: unlocked ? 1 : 0.35,
                                        colourA: [0.6, 0.35, 0.4, 1], colourB: [0.6, 0.35, 0.4, 1]))
            if !unlocked {
                // Mist: cloud sprites low over the pool.
                for k in 0..<2 {
                    guard let name = cloud(k) else { break }
                    let c = CGPoint(x: pool.centre.x + CGFloat(k * 70 - 35) + CGFloat(sin(Double(elapsed) * 0.13 + Double(k))) * 18,
                                    y: pool.centre.y + CGFloat(k * 24 - 12))
                    over.append(Sprite(name, at: c, size: CGSize(width: 320, height: 200),
                                       mode: .floater, alpha: 0.28, z: 0.3))
                }
            }
            guard i < life.count, abs(pool.centre.y - viewY) < reach else { continue }
            dressPool(pool, state: state, life: life[i], night: night,
                      over: &over, under: &under, solids: &solids, painting: painting)
        }
        // The haze over each stretch, thinning as its pools wake.
        for m in stretchMist {
            let woke = wokeFraction[m.season] ?? 0
            let alpha = 0.3 * (1 - woke)
            guard alpha > 0.02, abs(m.y - viewY) < reach else { continue }
            let t = garden.textureSize(m.texture)
            let breath = 0.85 + 0.15 * CGFloat(sin(Double(elapsed) * 0.23 + Double(m.phase)))
            let drift = CGFloat(sin(Double(elapsed) * 0.06 + Double(m.phase))) * 30
            over.append(Sprite(m.texture, at: CGPoint(x: m.x + drift, y: m.y),
                               size: CGSize(width: m.size * breath, height: m.size * breath * t.height / max(1, t.width)),
                               mode: .floater, alpha: alpha, tint: [0.93, 0.97, 1.0, 1], z: 0.38))
        }
        // Words: a washi chip beside each pool, the season's name on the line
        // where its stretch is entered, the title at the mouth. Paper on
        // the water, so they tilt with it and move with the camera.
        if let tex = renderer.textures as TextureCache? {
            for (i, pool) in pools.enumerated() {
                let idx = Library.levels(in: pool.season).firstIndex { $0.id == pool.level.id } ?? 0
                let words = ["one", "two", "three", "four", "five", "six"]
                let word = idx < words.count ? words[idx] : "\(idx + 1)"
                let done = i < states.count && states[i].done
                let unlocked = i < states.count && states[i].unlocked
                let name = LabelSprites.chip(word, done: done, textures: tex)
                let at = CGPoint(x: pool.centre.x - pool.radius * 0.3, y: pool.centre.y + pool.radius * 0.95)
                let tip = Float(sin(Double(pool.centre.y) * 0.013 + Double(idx))) * 0.11
                paper(Sprite(name, at: at, size: CGSize(width: 86, height: 36), rotation: tip,
                             mode: .floater, alpha: unlocked ? 1 : 0.55, z: 0.1))
            }
            for e in entries {
                let name = LabelSprites.caption(e.name, points: 26, textures: tex)
                let t = tex.size(name)
                let h: CGFloat = 26 * 1.9
                over.append(Sprite(name, at: CGPoint(x: viewSize.width / 2, y: e.y), size: CGSize(width: h * t.width / max(1, t.height), height: h),
                                   mode: .floater, alpha: 1, z: 0.25))
            }
            // Beyond autumn, at the source, a note about the seasons to come.
            let note = LabelSprites.chip("Seasons to come", done: false, textures: tex, wide: true)
            paper(Sprite(note, at: storeNote, size: CGSize(width: 150, height: 40), rotation: 0.05, mode: .floater, alpha: 1, z: 0.1))
            let title = LabelSprites.caption("Ripple Garden", points: 32, textures: tex)
            let ts = tex.size(title)
            let th: CGFloat = 32 * 1.9
            over.append(Sprite(title, at: CGPoint(x: viewSize.width / 2, y: mouthY), size: CGSize(width: th * ts.width / max(1, ts.height), height: th),
                               mode: .floater, alpha: 1, z: 0.3))
        }
        for s in garden.skaterSprites() { paper(s) }
        for s in garden.petalSprites() { paper(s) }
        over += garden.dropletSprites()
        for s in stretchBranches { paper(s, cast: 18) }
        for (i, m) in sourceMist.enumerated() {
            guard let name = cloud(i) else { break }
            let drift = CGFloat(sin(Double(elapsed) * 0.09 + Double(m.phase))) * 24
            over.append(Sprite(name, at: CGPoint(x: m.x + drift, y: m.y),
                               size: CGSize(width: m.size * 1.6, height: m.size), rotation: m.phase * 0.05,
                               mode: .floater, alpha: 0.55, z: 0.35))
        }
        // Foam at each lip: pale wisps that swell and shrink.
        for (i, f) in foam.enumerated() {
            guard let name = cloud(i) else { break }
            let pulse = 0.75 + 0.25 * CGFloat(sin(Double(elapsed) * 1.7 + Double(f.phase)))
            over.append(Sprite(name, at: CGPoint(x: f.x, y: f.y),
                               size: CGSize(width: f.size * 2.2 * pulse, height: f.size * pulse), rotation: f.phase * 0.1,
                               mode: .floater, alpha: 0.42, z: 0.02))
        }
        for f in snow {
            over.append(Sprite("snow_2", at: CGPoint(x: f.x, y: f.y), size: CGSize(width: f.size, height: f.size),
                               rotation: f.phase, mode: .floater, alpha: 0.85, z: 0.5))
        }
        over += garden.skySprites()
        over += garden.mistSprites()
        renderer.submergedSprites = under
        renderer.surfaceSprites = over
        renderer.contactShadows = []
        renderer.solids = solids
        renderer.submergedSolids = underBodies
        renderer.solidTextures = paintings
    }

    // MARK: - The pools' life

    /// Every pool starts dormant and what its level woke stays. The store is
    /// read again only when it has changed, and the life is laid out then.
    private func refreshStates() {
        guard statesVersion != progress.version || states.count != pools.count else { return }
        statesVersion = progress.version
        states = pools.map { p in
            PoolState(unlocked: progress.isUnlocked(level: p.level),
                      done: progress.isComplete(levelID: p.level.id),
                      tokens: progress.woke(levelID: p.level.id))
        }
        wokeFraction = [:]
        for season in Library.seasons {
            let mine = pools.indices.filter { pools[$0].season.id == season.id }
            let awake = mine.filter { states[$0].done }.count
            wokeFraction[season.id] = mine.isEmpty ? 0 : Float(awake) / Float(mine.count)
        }
        buildLife()
    }

    /// Lay out what each pool keeps: the fish its level woke, the sprouts,
    /// the post, the stones. A pool that is still asleep keeps only the
    /// phase its mist breathes on.
    private func buildLife() {
        var rng = SystemRandomNumberGenerator()
        let w = viewSize.width
        life = pools.enumerated().map { i, pool -> PoolLife in
            var l = PoolLife()
            l.phase = Float.random(in: 0...(2 * .pi), using: &rng)
            guard i < states.count, states[i].done else { return l }
            let tokens = states[i].tokens
            let r = pool.radius
            // The bank side: away from the channel, where the pool's rim is.
            let out: CGFloat = pool.centre.x < w / 2 ? -1 : 1
            let outAngle: CGFloat = out < 0 ? .pi : 0
            let rock = CGPoint(x: pool.centre.x + r * 0.7, y: pool.centre.y - r * 0.55)
            func rim(_ angle: CGFloat, _ reach: CGFloat) -> CGPoint {
                CGPoint(x: pool.centre.x + cos(angle) * r * reach, y: pool.centre.y + sin(angle) * r * reach * 0.9)
            }
            if tokens.contains(.koi) {
                l.koi = PoolKoi(texture: koiKinds[i % koiKinds.count], centre: pool.centre, radius: r, rock: rock)
            }
            if tokens.contains(.shoal) {
                l.shoal = PoolShoal(texture: shoalKinds[i % shoalKinds.count], centre: pool.centre, radius: r,
                                    count: 7, seed: i, rock: rock)
            }
            if tokens.contains(.bud) {
                l.lotus = (CGPoint(x: pool.centre.x - r * 0.12, y: pool.centre.y + r * 0.66),
                           Float.random(in: 0...(2 * .pi), using: &rng))
            }
            if tokens.contains(.seeds) {
                // Two or three sprouts standing in the shallows at the rim.
                let n = Int.random(in: 2...3, using: &rng)
                for k in 0..<n {
                    let name = "sprout_\(k % 3 + 1)"
                    guard garden.textureSize(name).width > 1 else { continue }
                    let a = outAngle + (CGFloat(k) - CGFloat(n - 1) / 2) * 0.42 + CGFloat.random(in: -0.1...0.1, using: &rng)
                    l.sprouts.append((name, rim(a, CGFloat.random(in: 1.02...1.16, using: &rng)),
                                      CGFloat.random(in: 34...50, using: &rng),
                                      Float.random(in: -0.16...0.16, using: &rng),
                                      Float.random(in: 0...(2 * .pi), using: &rng), out > 0))
                }
            }
            if tokens.contains(.moon) { l.moon = true }
            if tokens.contains(.bamboo), garden.textureSize("bamboo_post").width > 1 {
                l.bamboo = (rim(outAngle - 0.55 * out, 1.32), CGFloat.random(in: 60...72, using: &rng),
                            Float.random(in: 0...(2 * .pi), using: &rng), out > 0)
            }
            if tokens.contains(.chime) {
                // Three small stones in a row along the pool's lower edge.
                let foot = rim(.pi / 2, 0.98)
                for k in 0..<3 {
                    let sr = Float.random(in: 8...11, using: &rng)
                    let at = CGPoint(x: foot.x + CGFloat(k - 1) * 28, y: foot.y + CGFloat(k % 2) * 5)
                    l.chime.append(SolidInstance(position: SIMD2(Float(at.x), Float(at.y)), lift: sr * 0.3,
                                                 yaw: Float.random(in: 0...3, using: &rng), roll: Float(at.x * 0.13 + at.y * 0.07),
                                                 tilt: .zero, length: sr * 1.3, radius: sr, shape: 2, alpha: 1,
                                                 colourA: [0.56, 0.57, 0.55, 1], colourB: [0.42, 0.52, 0.36, 1]))
                }
            }
            if tokens.contains(.clear) { l.clear = true }
            if tokens.contains(.pool) {
                // Water spilling over the rim into a little side pool: pale
                // wisps that swell and shrink at the bank.
                for k in 0..<4 {
                    let a = outAngle + (CGFloat(k) - 1.5) * 0.22
                    let p = rim(a, CGFloat.random(in: 1.22...1.4, using: &rng))
                    l.spill.append((p.x, p.y, Float.random(in: 0...(2 * .pi), using: &rng), CGFloat.random(in: 18...30, using: &rng)))
                }
            }
            return l
        }
    }

    /// 1 when the moon would be in the water, 0 at midday. Noon is a half.
    private func nightAmount(_ phase: Float) -> Float {
        max(smooth(0.72, 0.9, phase), 1 - smooth(0.1, 0.28, phase))
    }

    /// One pool's state on the water: the murk and the mist of a pool still
    /// asleep, or the life its level woke.
    private func dressPool(_ pool: Pool, state: PoolState, life l: PoolLife, night: Float,
                           over: inout [Sprite], under: inout [Sprite], solids: inout [SolidInstance],
                           painting: (String) -> UInt32) {
        let r = pool.radius
        let t = Double(elapsed)
        let breath = Float(sin(t * 0.5 + Double(l.phase)))
        if !state.done {
            // The bed under a sleeping pool lies darker: two cloud shadows
            // turning slowly against each other, so the murk never sits still.
            for k in 0..<2 {
                guard let name = cloud(k + 2) else { break }
                let turn = Float(t) * (k == 0 ? 0.05 : -0.04) + l.phase
                let side = r * (2.5 + 0.15 * CGFloat(breath))
                under.append(Sprite(name, at: CGPoint(x: pool.centre.x + CGFloat(k * 20 - 10), y: pool.centre.y + CGFloat(k * 14 - 7)),
                                    size: CGSize(width: side, height: side * 0.8), rotation: turn,
                                    mode: .shadow, alpha: 0.42, z: -1.0))
            }
            if state.unlocked {
                // Mist lying on the pool, denser than the clouds over a
                // sleeping season, breathing and drifting the way the ponds' does.
                for k in 0..<2 {
                    let name = k == 0 ? "mist_1" : "mist_2"
                    let ts = garden.textureSize(name)
                    let drift = CGFloat(sin(t * 0.07 + Double(l.phase) + Double(k) * 2.1)) * 22
                    let lift = CGFloat(cos(t * 0.05 + Double(l.phase) + Double(k) * 1.3)) * 10
                    let side = r * (2.7 + 0.2 * CGFloat(sin(t * 0.19 + Double(k) + Double(l.phase))))
                    over.append(Sprite(name, at: CGPoint(x: pool.centre.x + drift * (k == 0 ? 1 : -1), y: pool.centre.y + lift + CGFloat(k * 16 - 8)),
                                       size: CGSize(width: side, height: side * ts.height / max(1, ts.width)),
                                       mode: .floater, alpha: 0.5, tint: [0.93, 0.97, 1.0, 1], z: 0.3))
                }
            }
            return
        }
        if l.clear {
            // Cleared water: the bed shows pale through it, a light lying in
            // the bowl that turns as slowly as the murk did.
            let ts = garden.textureSize("mist_1")
            let side = r * (2.2 + 0.1 * CGFloat(breath))
            under.append(Sprite("mist_1", at: pool.centre, size: CGSize(width: side, height: side * ts.height / max(1, ts.width)),
                                rotation: Float(t) * 0.03 + l.phase, mode: .submerged, alpha: 0.3, depth: 0.15,
                                tint: [1.5, 1.6, 1.5, 1], z: -0.95))
        }
        if let k = l.koi {
            let ts = garden.textureSize(k.texture)
            let width: CGFloat = 46
            let height = width * ts.height / max(1, ts.width)
            let d = k.depth
            let offset = CGFloat(8 + 22 * d)
            under.append(Sprite(k.texture, at: CGPoint(x: k.position.x + offset * 0.6, y: k.position.y + offset),
                                size: CGSize(width: width, height: height), rotation: k.heading - .pi / 2,
                                mode: .shadow, alpha: 0.6 * (1 - d * 0.6), wave: k.phase, waveAmp: 0.09, z: -1.0))
            under.append(Sprite(k.texture, at: k.position, size: CGSize(width: width, height: height),
                                rotation: k.heading - .pi / 2, mode: .submerged, alpha: 1, depth: d,
                                wave: k.phase, waveAmp: 0.09, z: -0.2 - 0.7 * d))
        }
        if let s = l.shoal {
            let ts = garden.textureSize(s.texture)
            for f in s.fish {
                let h = f.length, w = h * ts.width / max(1, ts.height)
                under.append(Sprite(s.texture, at: CGPoint(x: f.position.x + 5, y: f.position.y + 10),
                                    size: CGSize(width: w, height: h), rotation: f.heading - .pi / 2, mode: .shadow,
                                    alpha: 0.35, wave: f.phase, waveAmp: 0.14, z: -1.0))
                under.append(Sprite(s.texture, at: f.position, size: CGSize(width: w, height: h),
                                    rotation: f.heading - .pi / 2, mode: .submerged, alpha: 1, depth: s.depth,
                                    wave: f.phase, waveAmp: 0.14, z: -0.2 - 0.7 * s.depth))
            }
        }
        if let lotus = l.lotus {
            // The lotus open on the water: a disc wearing its painting, like
            // the pads, with its shadow under it.
            let side: CGFloat = 66
            over.append(Sprite("lotus_1", at: CGPoint(x: lotus.at.x + 3, y: lotus.at.y + 4),
                               size: CGSize(width: side, height: side), mode: .shadow, alpha: 0.28, z: 0))
            solids.append(SolidInstance(position: SIMD2(Float(lotus.at.x), Float(lotus.at.y)), lift: 3.5,
                                        yaw: lotus.turn, roll: 0, texture: painting("lotus_1"), tilt: .zero,
                                        length: 3, radius: Float(side) * 0.5, shape: 4, alpha: 1,
                                        colourA: [0.16, 0.36, 0.22, 1], colourB: [0.16, 0.36, 0.22, 1]))
        }
        for s in l.sprouts {
            // Standing in the shallows on the surface plane, swaying at the tip.
            let ts = garden.textureSize(s.name)
            let width = s.height * ts.width / max(1, ts.height)
            over.append(Sprite(s.name, at: CGPoint(x: s.at.x + 5, y: s.at.y + s.height * 0.3),
                               size: CGSize(width: width, height: s.height * 0.5), rotation: 0,
                               mode: .shadow, alpha: 0.28, z: 0))
            over.append(Sprite(s.name, at: s.at, size: CGSize(width: width, height: s.height),
                               rotation: -.pi / 2 + s.lean, alpha: 1, flipX: s.flip,
                               wave: Float(t) * 0.9 + s.phase, z: 0, stands: true))
        }
        if let b = l.bamboo {
            let ts = garden.textureSize("bamboo_post")
            let width = b.height * ts.width / max(1, ts.height)
            over.append(Sprite("bamboo_post", at: CGPoint(x: b.at.x + 6, y: b.at.y + b.height * 0.32),
                               size: CGSize(width: width, height: b.height * 0.5), rotation: 0,
                               mode: .shadow, alpha: 0.3, z: 0))
            over.append(Sprite("bamboo_post", at: b.at, size: CGSize(width: width, height: b.height),
                               rotation: -.pi / 2, alpha: 1, flipX: b.flip,
                               wave: Float(t) * 0.4 + b.phase, z: 0, stands: true))
        }
        solids += l.chime
        for (i, f) in l.spill.enumerated() {
            guard let name = cloud(i) else { break }
            let pulse = 0.75 + 0.25 * CGFloat(sin(t * 1.5 + Double(f.phase)))
            over.append(Sprite(name, at: CGPoint(x: f.x, y: f.y),
                               size: CGSize(width: f.size * 2.2 * pulse, height: f.size * pulse), rotation: f.phase * 0.1,
                               mode: .floater, alpha: 0.4, z: 0.02))
        }
        if l.moon, garden.textureSize("moon").width > 1 {
            // The moon in the water: faint by day, full at night, riding the
            // surface with a slow breath in it.
            let alpha = (0.16 + 0.36 * night) * (0.88 + 0.12 * breath)
            let side: CGFloat = 56 + 4 * CGFloat(breath)
            over.append(Sprite("moon", at: CGPoint(x: pool.centre.x - r * 0.1, y: pool.centre.y - r * 0.15),
                               size: CGSize(width: side, height: side), rotation: l.phase * 0.1,
                               mode: .floater, alpha: alpha, tint: [1.0, 0.97, 0.9, 1], z: 0.03))
        }
    }

    // MARK: - Touch

    private func worldPoint(_ p: CGPoint) -> CGPoint { renderer?.worldPoint(screen: p) ?? p }

    /// A cloud sprite by count, or nothing when the season has none painted.
    private func cloud(_ i: Int) -> String? {
        art.clouds.isEmpty ? nil : art.clouds[i % art.clouds.count]
    }

    func touchBegan(id: Int, at screen: CGPoint, in size: CGSize, weight: Float) {
        screenSize = size
        // A menu is in the way: the stream neither scrolls nor ripples.
        if presented != nil { return }
        guard placed, opening == nil else { return }
        let now = CACurrentMediaTime()
        pending[id] = (screen, now)
        touches[id] = screen
        if scroll == nil { scroll = (id, screen.y, now, false, screen.y) }
        // A second finger down beside the first: they may be a tilt.
        if tilt == nil, let other = touches.keys.first(where: { $0 != id }), let op = touches[other] {
            tilt = Tilt(ids: [other, id], last: [other: op, id: screen], lastAt: now)
        }
        momentum = 0
    }

    // MARK: - Menus over the stream

    /// A menu opens: one real impulse in the real water where it was asked
    /// for, and then the scrim.
    private func present(_ screen: MenuScreen, from screen0: CGPoint?) {
        if viewSize != .zero {
            let at = screen0.map { worldPoint($0) }
                ?? renderer.map { CGPoint(x: CGFloat($0.viewCentre.x), y: CGFloat($0.viewCentre.y)) }
                ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
            renderer?.addSplat(at: at, in: viewSize, radius: 90, amplitude: -0.09)
        }
        sound.plop()
        haptics.swell()
        withAnimation(Motion.scrim) { presented = screen }
    }

    func openSettings(from screen: CGPoint? = nil) { present(.settings, from: screen) }

    func openStore(from screen: CGPoint? = nil) { present(.store, from: screen) }

    /// Arriving is savoured; leaving is instant.
    func closeMenu() {
        guard presented != nil else { return }
        sound.holdRelease(charge: 0.25)
        haptics.holdRelease(charge: 0.25)
        withAnimation(Motion.leave) { presented = nil }
    }

    func touchMoved(id: Int, to screen: CGPoint, in size: CGSize) {
        if presented != nil { return }
        touches[id] = screen
        if tilt?.ids.contains(id) == true, updateTilt(moved: id, to: screen) { return }
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

    /// A finger of the pair moving. Returns true once the two are read as a
    /// tilt, so the stream stops scrolling under them. Both must be going
    /// much the same way, both mostly up or down, and neither of them fast.
    private func updateTilt(moved id: Int, to screen: CGPoint) -> Bool {
        guard var t = tilt, let r = renderer else { return false }
        let now = CACurrentMediaTime()
        var step = CGPoint.zero
        if let was = t.last[id] {
            step = CGPoint(x: screen.x - was.x, y: screen.y - was.y)
            let dt = max(1.0 / 240, now - t.lastAt)
            t.speed[id] = hypot(step.x, step.y) / CGFloat(dt)
            var travel = t.travel[id] ?? .zero
            travel.x += step.x
            travel.y += step.y
            t.travel[id] = travel
        }
        t.last[id] = screen
        t.lastAt = now
        if !t.on, let ta = t.travel[t.ids[0]], let tb = t.travel[t.ids[1]] {
            let sameWay = ta.y * tb.y > 0
            let upright = abs(ta.y) > abs(ta.x) * 1.2 && abs(tb.y) > abs(tb.x) * 1.2
            let gentle = max(t.speed[t.ids[0]] ?? 0, t.speed[t.ids[1]] ?? 0) < CGFloat(GameTuning.gustSpeed)
            let far = min(hypot(ta.x, ta.y), hypot(tb.x, tb.y))
            if sameWay, upright, gentle, far > 10 {
                t.on = true
                scroll = nil
                momentum = 0
            }
        }
        if t.on {
            // Half a step from each finger is the pair's average.
            r.pitchTarget -= Float(step.y) * 0.5 * GameTuning.tiltPerPoint
        }
        tilt = t
        return t.on
    }

    func touchEnded(id: Int, at screen: CGPoint, in size: CGSize) {
        touches.removeValue(forKey: id)
        let wasTilt = tilt?.ids.contains(id) == true && tilt?.on == true
        if tilt?.ids.contains(id) == true { tilt = nil }
        if wasTilt {
            pending.removeValue(forKey: id)
            if scroll?.id == id { scroll = nil }
            return
        }
        if presented != nil { return }
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
        for l in life {
            l.koi?.startle(from: point)
            l.shoal?.startle(from: point)
        }
        sound.tap(x: Float(point.x / viewSize.width), weight: 0.5)
        haptics.tap(weight: 0.5)
        if CACurrentMediaTime() - start.began < 0.45, abs(point.x - storeNote.x) < 90, abs(point.y - storeNote.y) < 34 {
            openStore(from: screen)
            return
        }
        if CACurrentMediaTime() - start.began < 0.45,
           let pool = pools.first(where: { hypot($0.centre.x - point.x, $0.centre.y - point.y) < $0.radius }),
           progress.isUnlocked(level: pool.level) {
            renderer.addSplat(at: pool.centre, in: viewSize, radius: 40, amplitude: -0.6)
            garden.burstDroplets(at: pool.centre, power: 1)
            sound.dive()
            haptics.holdRelease(charge: 1)
            // The dive: the camera drops toward the pool as the water closes.
            centreTarget = SIMD2(Float(pool.centre.x), Float(pool.centre.y))
            zoomTarget = 1.6
            opening = (pool.level, CACurrentMediaTime())
        }
    }
}

// MARK: - What a woken pool keeps

/// The life one pool on the map keeps. Built once from the store; the fish
/// in it move every frame the pool is in view.
private struct PoolLife {
    var koi: PoolKoi?
    var shoal: PoolShoal?
    /// Sprouts standing in the shallows at the rim.
    var sprouts: [(name: String, at: CGPoint, height: CGFloat, lean: Float, phase: Float, flip: Bool)] = []
    /// The bamboo post at the bank.
    var bamboo: (at: CGPoint, height: CGFloat, phase: Float, flip: Bool)?
    /// The chime stones, half out of the water.
    var chime: [SolidInstance] = []
    /// Wisps where the water spills over the rim.
    var spill: [(x: CGFloat, y: CGFloat, phase: Float, size: CGFloat)] = []
    var lotus: (at: CGPoint, turn: Float)?
    var moon = false
    var clear = false
    /// Where this pool's breathing is in its cycle, so no two pools swell together.
    var phase: Float = 0
}

/// A koi that lives in one pool of the stream. It is a cut-out that wags
/// like the shoal fish rather than a spined body, since the map can have
/// more woken koi than the renderer has spines. It wanders between points
/// inside the bowl, rises to show itself now and then, mouths at the
/// surface, and sinks again.
private final class PoolKoi {
    let texture: String
    let centre: CGPoint
    let radius: CGFloat
    private let rock: CGPoint
    private(set) var position: CGPoint
    private(set) var heading: Float
    /// 0 at the surface, 1 on the bed.
    private(set) var depth: Float = 0.6
    private(set) var phase: Float
    /// True for the one frame it takes a mouthful at the surface.
    private(set) var mouthed = false
    private var depthTarget: Float = 0.6
    private var target: CGPoint
    private var retargetAt: TimeInterval = 0
    private var riseAt: TimeInterval = 0
    private var mouthAt: TimeInterval = 0
    private var fright: Float = 0
    private let cruise: Float

    init(texture: String, centre: CGPoint, radius: CGFloat, rock: CGPoint) {
        self.texture = texture
        self.centre = centre
        self.radius = radius
        self.rock = rock
        let a = Float.random(in: 0...(2 * .pi))
        position = CGPoint(x: centre.x + CGFloat(cos(a)) * radius * 0.3, y: centre.y + CGFloat(sin(a)) * radius * 0.3)
        heading = a + .pi / 2
        phase = Float.random(in: 0...(2 * .pi))
        cruise = Float.random(in: 22...30)
        target = centre
    }

    /// A tap near it: it turns away and goes down.
    func startle(from point: CGPoint) {
        let dx = Float(position.x - point.x), dy = Float(position.y - point.y)
        let d = (dx * dx + dy * dy).squareRoot()
        guard d < 200 else { return }
        fright = 1
        depthTarget = 0.85
        riseAt = CACurrentMediaTime() + Double.random(in: 5...9)
        let a = CGFloat(atan2(dy, dx))
        target = CGPoint(x: centre.x + cos(a) * radius * 0.5, y: centre.y + sin(a) * radius * 0.45)
        retargetAt = CACurrentMediaTime() + 4
    }

    func update(dt: Float, now: TimeInterval) {
        mouthed = false
        fright *= exp(-dt * 0.8)
        let dx = Float(target.x - position.x), dy = Float(target.y - position.y)
        if now > retargetAt || dx * dx + dy * dy < 18 * 18 {
            var a = CGFloat.random(in: 0...(2 * .pi))
            var r = radius * CGFloat.random(in: 0.15...0.6)
            // Not into the stone at the pool's shoulder.
            for _ in 0..<4 {
                let p = CGPoint(x: centre.x + cos(a) * r, y: centre.y + sin(a) * r * 0.9)
                if hypot(p.x - rock.x, p.y - rock.y) > 48 { break }
                a = CGFloat.random(in: 0...(2 * .pi))
                r = radius * CGFloat.random(in: 0.15...0.6)
            }
            target = CGPoint(x: centre.x + cos(a) * r, y: centre.y + sin(a) * r * 0.9)
            retargetAt = now + Double.random(in: 4...9)
        }
        var want = atan2(dy, dx)
        // The stone pushes its heading off if it is about to nose into it.
        let rx = Float(rock.x - position.x), ry = Float(rock.y - position.y)
        let rd = (rx * rx + ry * ry).squareRoot()
        if rd < 60 {
            var away = atan2(-ry, -rx) - want
            while away > .pi { away -= 2 * .pi }
            while away < -.pi { away += 2 * .pi }
            want += away * (1 - rd / 60) * 0.8
        }
        var diff = want - heading
        while diff > .pi { diff -= 2 * .pi }
        while diff < -.pi { diff += 2 * .pi }
        heading += diff * min(1, dt * (1.5 + fright * 3))
        // Slower up at the surface, like a fish that has stopped to look,
        // and quicker for a while after a fright.
        let speed = cruise * (0.6 + 0.4 * depth) * (1 + fright * 1.8)
        position.x += CGFloat(cos(heading) * speed * dt)
        position.y += CGFloat(sin(heading) * speed * dt)
        phase += dt * (3.5 + speed * 0.06)
        if now > riseAt {
            depthTarget = depthTarget < 0.4 ? Float.random(in: 0.5...0.8) : Float.random(in: 0.12...0.28)
            riseAt = now + Double.random(in: 5...14)
            mouthAt = now + 1.5
        }
        depth += (depthTarget - depth) * min(1, dt * 0.7)
        if depth < 0.3, now > mouthAt {
            mouthed = true
            mouthAt = now + Double.random(in: 1.2...2.6)
        }
    }
}

/// A few small fish that keep to one pool, going round it together. The
/// same flocking as the garden's shoals, with the bowl's rim holding them in.
private final class PoolShoal {
    final class Fish {
        var position: CGPoint
        var velocity: SIMD2<Float>
        var heading: Float
        var phase: Float
        let length: CGFloat
        init(position: CGPoint, velocity: SIMD2<Float>, length: CGFloat, phase: Float) {
            self.position = position
            self.velocity = velocity
            heading = atan2(velocity.y, velocity.x)
            self.length = length
            self.phase = phase
        }
    }

    let texture: String
    let centre: CGPoint
    let radius: CGFloat
    /// How deep the shoal swims, 0 surface to 1 bed.
    let depth: Float
    private(set) var fish: [Fish] = []
    private let rock: CGPoint
    /// Where round the pool the shoal is heading, and which way it goes.
    private var ring: Float
    private let spin: Float
    private let cruise: Float
    private var fright: Float = 0

    init(texture: String, centre: CGPoint, radius: CGFloat, count: Int, seed: Int, rock: CGPoint) {
        self.texture = texture
        self.centre = centre
        self.radius = radius
        self.rock = rock
        depth = [0.38, 0.5, 0.44][seed % 3]
        cruise = [40, 34, 46][seed % 3]
        spin = (seed % 2 == 0 ? 1 : -1) * Float.random(in: 0.25...0.4)
        ring = Float.random(in: 0...(2 * .pi))
        let start = CGPoint(x: centre.x + CGFloat(cos(ring)) * radius * 0.4, y: centre.y + CGFloat(sin(ring)) * radius * 0.36)
        let a = ring + .pi / 2 * (spin > 0 ? 1 : -1)
        fish = (0..<count).map { _ in
            Fish(position: CGPoint(x: start.x + CGFloat.random(in: -22...22), y: start.y + CGFloat.random(in: -22...22)),
                 velocity: SIMD2(cos(a), sin(a)) * cruise + SIMD2(Float.random(in: -6...6), Float.random(in: -6...6)),
                 length: CGFloat.random(in: 18...26) * [1.0, 0.85, 1.15][seed % 3],
                 phase: Float.random(in: 0...(2 * .pi)))
        }
    }

    func startle(from point: CGPoint) {
        var any = false
        for f in fish {
            let dx = Float(f.position.x - point.x), dy = Float(f.position.y - point.y)
            let d = max(1, (dx * dx + dy * dy).squareRoot())
            guard d < 180 else { continue }
            f.velocity += SIMD2(dx, dy) / d * (1 - d / 180) * 160
            any = true
        }
        if any { fright = 1 }
    }

    func update(dt: Float) {
        ring += spin * dt * (1 + fright)
        fright *= exp(-dt * 0.9)
        let c = SIMD2(Float(centre.x), Float(centre.y))
        let wander = c + SIMD2(cos(ring) * Float(radius) * 0.42, sin(ring) * Float(radius) * 0.38)
        let keep = Float(radius) * 0.72
        let stone = SIMD2(Float(rock.x), Float(rock.y))
        let n = fish.count
        for i in 0..<n {
            let f = fish[i]
            let tooClose = Float(f.length) * 0.95
            var middle = SIMD2<Float>(0, 0), align = SIMD2<Float>(0, 0), apart = SIMD2<Float>(0, 0)
            var count: Float = 0
            let p = SIMD2(Float(f.position.x), Float(f.position.y))
            for j in 0..<n where j != i {
                let g = fish[j]
                let q = SIMD2(Float(g.position.x), Float(g.position.y))
                let d = simd_length(q - p)
                guard d < 60 else { continue }
                middle += q
                align += g.velocity
                count += 1
                if d < tooClose { apart -= (q - p) / max(0.5, d) * (tooClose - d) }
            }
            var steer = SIMD2<Float>(0, 0)
            if count > 0 {
                steer += (middle / count - p) * 0.8
                steer += (align / count - f.velocity) * 1.4
            }
            steer += apart * 22
            steer += (wander - p) * 0.5
            // The bowl holds them, and the stone is kept clear of.
            let out = p - c
            let d = simd_length(out)
            if d > keep { steer -= out / max(1, d) * (d - keep) * 8 }
            let fromStone = p - stone
            let sd = simd_length(fromStone)
            if sd < 50 { steer += fromStone / max(1, sd) * (50 - sd) * 6 }
            f.velocity += steer * dt
            let want = cruise * (1 + fright * 1.6)
            let sp = simd_length(f.velocity)
            if sp > 0.01 { f.velocity *= 1 + (want / sp - 1) * min(1, dt * 2.2) }
            let target = atan2(f.velocity.y, f.velocity.x)
            var diff = target - f.heading
            while diff > .pi { diff -= 2 * .pi }
            while diff < -.pi { diff += 2 * .pi }
            f.heading += diff * min(1, dt * 6)
            f.position.x += CGFloat(f.velocity.x * dt)
            f.position.y += CGFloat(f.velocity.y * dt)
            f.phase += dt * (6 + sp * 0.12)
        }
    }
}
