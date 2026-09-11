import SwiftUI
import simd

/// One level in play. Owns the debris and the goals, decides what each
/// touch means, feeds the renderer its sprites, walls and probes every
/// frame, reads the pond for the goals, and runs the bloom when the pond
/// has woken.
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
    /// The menu that is up, when one is. The view draws it over the pond.
    @Published private(set) var presented: MenuScreen?
    /// The words low in the pond: the line that opens the level, what is
    /// left, a hint. One slot, so two of them never collide.
    @Published private(set) var words: PondWords?
    /// When the hint arrived, in level seconds. It goes on its own after a
    /// while, or on the next touch, whichever comes first.
    private var hintAt: Float = 0
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
    /// The reward moment running over the celebration, nil the rest of the time.
    private var reveal: RewardReveal?
    /// The look the level loaded with, so the bed can go gold and come back.
    private var baseLook: FloorLook?
    /// The completion's third word. RootView wires it to the player's own pond.
    var onYourPond: (() -> Void)?
    /// `-winNow`: the level is finished six seconds after launch, so the
    /// reward can be seen without playing.
    private var winNow = ProcessInfo.processInfo.arguments.contains("-winNow")

    private weak var renderer: WaterRenderer?
    /// The world (the whole pond) in points. Bigger than the screen.
    private var viewSize = CGSize.zero
    private var screenSize = CGSize.zero
    // The view: zoom and centre, eased toward their targets so it flows.
    private var zoomTarget: Float = 0.76
    private var centreTarget = SIMD2<Float>(0, 0)
    private struct Pinch {
        var ids: [Int]
        var startDistance: CGFloat
        var startZoom: Float
        var anchorWorld: SIMD2<Float>
        var active = false
        /// Two fingers drawn the same way tilt the camera instead of zooming
        /// it. Once they are read as a tilt they stay one.
        var tilting = false
        /// Where each finger was last seen, how far it has come since the
        /// two went down, and how fast it is going now.
        var last: [Int: CGPoint] = [:]
        var travel: [Int: CGPoint] = [:]
        var speed: [Int: CGFloat] = [:]
        var lastAt: TimeInterval = 0
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

    // MARK: Goals and what they read

    /// The level's goals in world points, and what has been met so far.
    private(set) var goals: [GoalSpec] = []
    private let evaluator = GoalEvaluator()
    /// The instruments this level plays: the bamboo, the chime stones, the
    /// dry pool. Each reads the water at its own points.
    private var instruments: [Instrument] = []
    private var instrumentProbeStart = 0
    /// Sixteen fixed cells over open water whose mean |velocity| says how
    /// glassy the pond is.
    private var calmCells: [CGPoint] = []
    private var calmProbeStart = 0
    private var calmSamples: [FieldSample] = []
    private(set) var agitation: Float = 0
    /// Level seconds when a finger last touched the water.
    private var lastTouchAt: Float = -100
    /// How busy the water was as the last finger came down, for the koi's
    /// curiosity: a tap on a calm pond is worth turning for.
    private var agitationAtTouch: Float = 0
    /// Fingers whose hold is calling a koi up.
    private var calling: Set<Int> = []
    /// The stillness the garden is shown, eased so the moon never snaps.
    private var stillShown: Float = 0
    /// Seeds that have taken root, and the seedlings standing where they did.
    private(set) var rootedSeeds = 0
    private var sprouts: [Sprout] = []
    /// Leaves still coming down on an autumn level.
    private var leafFall: LeafFall?
    /// What the instruments have done: knocks, the notes played so far, and
    /// how full the dry pool is.
    private(set) var knocks = 0
    private(set) var notesPlayed: [Int] = []
    private var phraseComplete = false
    private var phraseHeard = false
    private var phrase: Task<Void, Never>?
    private(set) var poolFill: Float = 0
    private var poolFull = false
    private var bambooState: ShishiOdoshiState?
    private var chimeState: SuikinkutsuState?
    private var poolState: DryPoolState?
    /// The fill the depth map was last painted at, and when.
    private var poolPainted: Float = 0
    private var poolRepaintAt: Float = 0
    /// The koi lie on the bed under a frozen pond until it opens.
    private var koiAsleep = false
    /// Lily pads in world points: ripples stop at them, taps on them do nothing.
    private(set) var pads: [(centre: CGPoint, radius: CGFloat, sprite: String)] = []
    /// Things a crest wakes.
    private(set) var targets: [Target] = []
    private var targetProbeStart = 0
    private var iceTidyTimer: Float = 0

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
        /// A slow, long drag: it shoves a body of water ahead of the hand.
        var isSlosh = false
        var travelled: CGFloat = 0
        var sinceSplat: CGFloat = 0
        var heading: SIMD2<Float>?
        /// The last stretch of the stroke: where it went and how far it
        /// turned at each step, for reading a circle out of it.
        var path: [(at: TimeInterval, point: CGPoint, turn: Float)] = []
        var stirring = false
        /// A finger spent on a gust: it lays no more wake behind it.
        var spent = false
        /// The points the wake was laid along, start to end, for the shoal.
        var wakePath: [CGPoint] = []
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

    /// The wind the pond gets on its own, with nobody's hand in it: a front
    /// of small dips marching across the water, the petals going with it and
    /// the reeds leaning after it.
    private struct Wind {
        var direction: SIMD2<Float>
        var origin: CGPoint
        var age: Float = 0
    }
    private var wind: Wind?
    private var nextWindAt: Float = 22
    /// The stream's own voice. Negative, so it never meets a touch id.
    private let inletSoundID = -8
    private var inletSounding = false
    /// When each stone last stirred the bed under it, so it does not fizz.
    private var stoneStirAt: [Int: Float] = [:]
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
    /// What the goals have made of the pond so far, for the demo.
    var goalStates: [GoalEvaluator.State] { evaluator.states }
    var shoalCentroids: [CGPoint] { garden.shoalCentroids() }

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
        reveal = nil
        phrase?.cancel()
        garden.releaseCall()
        calling.removeAll()
        presented = nil
        words = nil
        sound.stopAmbience()
        for id in Array(holdSounding) { sound.holdEnd(id: id) }
        holdSounding.removeAll()
        hushGestures()
        hushInlet()
        renderer?.cancelAll()
    }

    /// The stream falls quiet: on the way out, and whenever the next level
    /// has no stream of its own.
    private func hushInlet() {
        guard inletSounding else { return }
        inletSounding = false
        sound.inletEnd(id: inletSoundID)
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
        renderer.pitchLimit = WaterRenderer.maxPitch
        renderer.style = style
        garden.textureSize = { [weak renderer] name in renderer?.textures.size(name) ?? CGSize(width: 1, height: 1) }
        renderer.onFrame = { [weak self] dt in self?.frame(dt: dt) }
        renderer.onChargedRelease = { [weak self] charge, at in
            guard let self else { return }
            self.sound.holdRelease(charge: charge)
            self.haptics.holdRelease(charge: charge)
            // A swell big enough throws water into the air, and the fish that
            // was lying near it may answer with a leap of its own.
            if charge > 0.5 {
                self.garden.burstDroplets(at: at, power: charge)
                self.garden.bigSplash(at: at)
            }
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
        reveal = nil
        presented = nil
        words = nil
        statusText = ""
        level = newLevel
        season = Library.season(for: newLevel)
        art = season.art(for: style)
        phase = .playing
        elapsed = 0
        touchedYet = false
        Tutorial.shared.note(.levelOpened(id: newLevel.id, frozen: newLevel.frozen))
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
        hushInlet()
        wind = nil
        nextWindAt = Float.random(in: 20...45)
        stoneStirAt = [:]
        lastTap = nil
        debris = []
        probeOrder = []
        goals = []
        evaluator.reset(count: 0)
        instruments = []
        calmCells = []
        calmSamples = []
        agitation = 0
        lastTouchAt = -100
        calling.removeAll()
        garden.releaseCall()
        stillShown = 0
        rootedSeeds = 0
        sprouts = []
        leafFall = nil
        knocks = 0
        notesPlayed = []
        phraseComplete = false
        phraseHeard = false
        phrase?.cancel()
        poolFill = 0
        poolFull = false
        poolPainted = 0
        poolRepaintAt = 0
        bambooState = nil
        chimeState = nil
        poolState = nil
        koiAsleep = false
        for t in targets { t.tremble = 0 }

        var look = art.floor
        look.mosaicCentre = SIMD2(Float(newLevel.mosaicCentre.x), Float(newLevel.mosaicCentre.y))
        look.mosaicRadius = Float(newLevel.mosaicRadius)
        baseLook = look
        renderer?.floorLook = look
        // The materials this pond is made of: silt haze over the whole bed,
        // a film of duckweed over the water, or neither.
        renderer?.setSilt(wholePond: newLevel.wantsSilt)
        renderer?.setFilm(on: newLevel.wantsFilm)
        // The year's last level is played in the evening.
        if newLevel.dusk, let r = renderer, r.dayPhase < 0.74 { r.dayPhase = 0.74 }
        // The pond has a real bank all round it, in this season's ground.
        // One stretch covers the whole world, so all four slots wear it.
        let painting = "bank_\(season.id)"
        renderer?.bankPaintings = [painting, painting, painting, painting]
        renderer?.bank = SIMD3(1, 1, 1)
        renderer?.depthPainter = { [level = newLevel, weak self] w, h in
            DepthPainter.paint(level: level, width: w, height: h, poolFill: self?.poolFill ?? 0)
        }
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
        garden.depthAt = { [weak self] p in
            DepthPainter.depth(at: CGPoint(x: p.x / size.width, y: p.y / size.height), level: spec,
                               aspect: Float(size.width / size.height), poolFill: self?.poolFill ?? 0)
        }
        garden.groundAt = { p in
            DepthPainter.ground(at: CGPoint(x: p.x / size.width, y: p.y / size.height), aspect: Float(size.width / size.height))
        }
        garden.configure(art: art, size: viewSize, bloomStage: progress.bloomStage(for: season.id))
        // Mist lies thick over a cold pond and hardly at all over a warm one.
        garden.mistAmount = ["winter": 1.0, "autumn": 0.8, "spring": 0.5, "summer": 0.15][season.id] ?? 0.5
        // A stream running in, if this pond has one.
        garden.inlet = spec.inlet.map { CGPoint(x: $0.x * viewSize.width, y: $0.y * viewSize.height) }
        if garden.inlet != nil, !inletSounding {
            inletSounding = true
            sound.inletBegin(id: inletSoundID)
        } else if garden.inlet == nil {
            hushInlet()
        }
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
            if p.kind.isSeed {
                // A lotus seed, or the season's light piece until one is drawn.
                let pod = "seed_\(1 + p.variant % 3)"
                let name = Self.spriteExists(pod) ? pod : (art.light.isEmpty ? "leaf_1" : art.light[p.variant % art.light.count])
                let d = Debris(id: i, cls: .light, sprite: name,
                               position: CGPoint(x: p.at.x * viewSize.width, y: p.at.y * viewSize.height),
                               radius: p.kind.radius * p.scale, scale: p.scale, kind: .seed)
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
        // The sheet lies on the water, not on the bank around it.
        if let f = iceField {
            let aspect = Float(viewSize.width / viewSize.height)
            f.trimToWater { DepthPainter.ground(at: $0, aspect: aspect) >= 0.08 }
        }
        // A frozen pond is seen whole: nothing of the sheet hides off screen.
        // The pond is seen with its banks: pulled back, not pressed in.
        if level.frozen { showWholePond() } else { zoomTarget = 0.76 }
        garden.iceCover = iceField?.fraction ?? 0
        if let f = iceField {
            renderer?.setIce(f.cells, scuff: f.scuff, width: f.width, height: f.height)
            renderer?.setIceCracks(seeds: f.seeds, strikes: f.strikes)
            f.markCracksClean()
            f.markClean()
        } else {
            renderer?.setIce(nil, width: 0, height: 0)
            renderer?.setIceCracks(seeds: [], strikes: [])
        }
        placeGoals()
    }

    /// The goals in world points, the instruments they need, the calm
    /// probes, and the life that has to be arranged before play: a koi sent
    /// to hide, the koi put to sleep under the ice.
    private func placeGoals() {
        goals = level.goals.map { $0.placed(in: viewSize) }
        evaluator.reset(count: goals.count)
        instruments = []
        var shy: Shape?
        var pen: CGFloat?
        for g in goals {
            switch g.kind {
            case .shishiOdoshi(let at, _):
                // On the bank nearest the point, facing the water, with the
                // spout out over water that waves can reach.
                let dir = SIMD2<Float>(Float(viewSize.width / 2 - at.x), Float(viewSize.height / 2 - at.y))
                let into = simd_length(dir) > 1 ? simd_normalize(dir) : SIMD2<Float>(0, 1)
                let edge = onWater(from: at, inset: 12)
                let foot = CGPoint(x: edge.x - CGFloat(into.x) * 30, y: edge.y - CGFloat(into.y) * 30)
                instruments.append(ShishiOdoshi(at: foot, bankDirection: into))
            case .suikinkutsu(let stones, let order):
                instruments.append(Suikinkutsu(stones: stones, order: order))
            case .fillPool(let lip, let pool, let h):
                // The lip is the last of the water before the dry pool.
                instruments.append(DryPool(lip: onWater(from: lip, inset: 10), pool: pool, lipHeight: h))
            case .temptShyKoi(let home):
                shy = home
            case .leadShoal(let gate):
                // The shoal waits in the pocket below the gate until it is led.
                pen = max(gate.0.y, gate.1.y) + 30
            default:
                break
            }
        }
        garden.setShyHome(shy)
        garden.penShoals(below: pen)
        shoalPenned = pen != nil
        // Sixteen cells over the open middle of the pond, well in from the
        // banks and the things that stand in it.
        calmCells = []
        for row in 0..<4 {
            for col in 0..<4 {
                calmCells.append(CGPoint(x: viewSize.width * (0.2 + 0.6 * (CGFloat(col) + 0.5) / 4),
                                         y: viewSize.height * (0.2 + 0.6 * (CGFloat(row) + 0.5) / 4)))
            }
        }
        // Under a frozen pond the koi lie on the bed until the sheet opens
        // over each of them.
        if let f = iceField {
            garden.iceOverAt = { [weak f] p in f?.ice(at: p) ?? 0 }
        } else {
            garden.iceOverAt = nil
        }
        koiAsleep = level.frozen && level.wantsKoi
        garden.sleepKoiUnderIce(koiAsleep)
        leafFall = level.leaves > 0 ? LeafFall(total: level.leaves, textures: art.light.isEmpty ? ["leaf_1"] : art.light) : nil
        // The pond hums the chime phrase once the level has opened, unless
        // the stones hum it themselves first.
        if goals.contains(where: { if case .suikinkutsu = $0.kind { return true }; return false }) {
            let opened = level.id
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.level.id == opened, !self.phraseHeard, self.phase == .playing else { return }
                self.playPhrase()
            }
        }
    }

    /// Whether a picture by this name is in the bundle, so a piece drawn
    /// later can fall back to one that is.
    static func spriteExists(_ name: String) -> Bool {
        Bundle.main.url(forResource: name, withExtension: "png") != nil
    }

    /// The chime phrase, one note at a time, the way the pond hums it.
    private func playPhrase() {
        guard let g = goals.first(where: { if case .suikinkutsu = $0.kind { return true }; return false }),
              case .suikinkutsu(let stones, let order) = g.kind, viewSize.width > 0 else { return }
        phraseHeard = true
        phrase?.cancel()
        let w = Float(viewSize.width)
        phrase = Task { @MainActor [weak self] in
            for i in order where i < stones.count {
                guard let self, !Task.isCancelled else { return }
                self.sound.chime(note: i, x: Float(stones[i].x) / w)
                try? await Task.sleep(for: .seconds(0.55))
            }
        }
    }

    /// A tap on the sheet. Fresh ice takes the blow as a ring of shards, the
    /// cracks racing out from the point. A second tap anywhere inside that
    /// ring takes the whole of it out at once. Ice within a finger's width of
    /// open water is already weak: it gives way on the first tap, in a small
    /// bite. Returns true if the tap was on ice.
    @discardableResult
    private func tapIce(at point: CGPoint) -> Bool {
        guard let field = iceField else { return false }
        let now = renderer?.clock ?? 0
        if field.ice(at: point) < 0.5 {
            // A tap just beside a scrap is meant for the scrap: a small piece
            // near the finger goes under.
            guard let near = field.nearestIcePoint(to: point, range: 70),
                  let area = field.sinkIsland(at: near, maxArea: 40000, time: now) else { return false }
            afterBreak(at: near, shards: [(near, area)])
            return true
        }
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
            Tutorial.shared.note(.iceStruck(at: point))
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
        Tutorial.shared.note(.iceBroke)
        let total = shards.reduce(CGFloat(0)) { $0 + $1.area }
        haptics.iceBreak(size: Float(min(1, total / 60000)))
        sound.iceBreak(x: Float(point.x / viewSize.width), size: Float(min(1, total / 60000)))
        renderer?.addSplat(at: point, in: viewSize, radius: 22, amplitude: -0.45)
        garden.burstDroplets(at: point, power: 0.4 + 0.6 * Float(min(1, total / 60000)))
        garden.bigSplash(at: point)
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
        updateWind(dt: dt)
        updateInlet(dt: dt)

        // The phone moving tips the pond: a broad slosh toward the side it
        // tips to, more the harder it is handled. A still hand leaves it be.
        if garden.handMotion > 0.05, phase == .playing {
            handSloshAccumulator += garden.handMotion * dt * 6
            while handSloshAccumulator >= 1 {
                handSloshAccumulator -= 1
                let w = viewSize.width, h = viewSize.height
                let dir = simd_length(garden.handTilt) > 0.01 ? simd_normalize(garden.handTilt) : SIMD2<Float>(Float.random(in: -1...1), Float.random(in: -1...1))
                let p = CGPoint(x: w * 0.5 + CGFloat(dir.x) * w * 0.3 + CGFloat.random(in: -w * 0.15...w * 0.15),
                                y: h * 0.5 + CGFloat(dir.y) * h * 0.3 + CGFloat.random(in: -h * 0.15...h * 0.15))
                renderer.addSplat(at: p, in: viewSize, radius: Float.random(in: 30...50), amplitude: -0.02 * min(2, garden.handMotion))
            }
        }

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
            // Rain brings its own wind with it: a broad, faint chop that never
            // lets the surface lie flat.
            for _ in 0..<2 {
                let p = CGPoint(x: CGFloat.random(in: 0...w), y: CGFloat.random(in: 0...h))
                renderer.addSplat(at: p, in: viewSize, radius: Float.random(in: 22...42), amplitude: -0.006)
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
                if d.kind.isSeed { tendSeed(d, dt: dt) }
            }
            DebrisPhysics.separate(debris, dt: dt)
            for d in debris where !d.cleared && !d.kind.isSeed && (DebrisPhysics.hasReachedShore(d, in: viewSize) || isBeached(d)) {
                clear(d)
            }
            updateLeaves(dt: dt)
        }

        // The garden lives regardless of the puzzle. Drips come off the
        // branches once the rain has passed, and on a spring morning while
        // the pond is still new.
        garden.dripping = (level.rain && phase != .playing) || (season.id == "spring" && elapsed < 20)
        garden.update(dt: dt, now: now)
        for s in garden.splashes { renderer.addSplat(at: s.at, in: viewSize, radius: s.radius, amplitude: s.amplitude) }
        garden.splashes.removeAll()
        soundGarden()
        // A stone shoved along the bed stirs the mud under it.
        for d in debris where !d.cleared && d.cls == .heavy {
            guard let kind = NaturalSolid.forSprite(d.sprite) else { continue }
            if case .log = kind { continue }
            guard simd_length(d.velocity) > 16, elapsed - (stoneStirAt[d.id] ?? -10) > 0.6 else { continue }
            stoneStirAt[d.id] = elapsed
            garden.addBubble(at: d.position)
        }

        updateReveal(dt: dt, renderer: renderer)

        // Silt progress.
        cleaned = 1 - renderer.siltRemaining
        if cleaned > lastCleaned + 0.005 {
            lastCleaned = cleaned
            lastProgressAt = elapsed
        }
        if phase == .playing {
            // Ice: once most of the sheet is gone the scraps go under on their
            // own, and the last few percent are not worth hunting for.
            if let f = iceField {
                iceTidyTimer -= dt
                if iceTidyTimer <= 0 {
                    iceTidyTimer = 0.5
                    let fraction = f.fraction
                    if fraction < 0.08 {
                        f.sinkAll(time: renderer.clock)
                    } else if fraction < 0.35 {
                        f.sinkSmallIslands(maxArea: 40000, time: renderer.clock)
                    }
                }
                // The sheet is mostly open: whatever koi were still lying
                // under the last of it wake too.
                if koiAsleep, f.fraction < 0.6 {
                    koiAsleep = false
                    garden.sleepKoiUnderIce(false)
                }
            }
        }

        // The instruments and the calm probes read the water, then the
        // goals read everything.
        updateInstruments(dt: dt, samples: samples)
        updateCalm(samples: samples, dt: dt)
        if phase == .playing {
            readGoals(dt: dt)
            // Once led through, the shoal has the whole pond.
            if shoalPenned, evaluator.isDone(goals: goals) { if case .leadShoal = $0.kind { return true }; return false } {
                shoalPenned = false
                garden.penShoals(below: nil)
            }
            if evaluator.allDone || (winNow && elapsed > 6) { finish() }
        }

        // Feed the renderer.
        feedRenderer(renderer)

        // Weed tips read the water too; their samples ride at the end of the
        // probe list, after the debris.
        for (i, t) in targets.enumerated() where targetProbeStart + i < samples.count {
            // A wave is a wave, crest or trough: what matters is how far the
            // water under the target moved.
            let h = abs(samples[targetProbeStart + i].height)
            t.peak = max(t.peak, h)
            if !t.woke, h > t.spec.threshold {
                wake(t, by: "h=\(h)")
            } else if !t.woke, h > GoalTuning.trembleFraction * t.spec.threshold, elapsed - t.lastTrembleAt > 0.8 {
                // A near miss: the thing shivers and ticks, and the hand
                // learns how close that was.
                t.lastTrembleAt = elapsed
                t.tremble = 1
                sound.tremble(x: Float(t.position.x / viewSize.width))
                haptics.tremble()
            }
            // A koi come up under a bud nudges it open.
            if !t.woke, t.spec.kind == .bud, garden.koiSurfacedNear(t.position, radius: 60) != nil {
                wake(t, by: "koi")
            }
            t.tremble *= exp(-dt * 3)
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
        // The instruments read the water at their own points, then the
        // calm probes. A point off the grid is read as flat water, so the
        // order of the list is never thrown out by one.
        instrumentProbeStart = cells.count
        for inst in instruments {
            for p in inst.probePoints { cells.append(renderer.cell(for: p, in: viewSize) ?? SIMD2(0, 0)) }
        }
        calmProbeStart = cells.count
        for p in calmCells { cells.append(renderer.cell(for: p, in: viewSize) ?? SIMD2(0, 0)) }
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
            // A charged finger calls the koi: the nearest one rises and
            // comes to it, and the shy one reads the same finger.
            if charge > 0.15 {
                calling.insert(id)
                garden.callKoi(at: t.last, charge: charge, dt: dt)
            }
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

        // A hint stays a while and then goes by itself.
        if hint != nil, elapsed - hintAt > 6 { dismissHint() }
        updateStatus()
        updateWords()
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
                NSLog("[camera] zoom=%.2f pitch=%.2f solids=%d under=%d paintings=%d", renderer.zoom, renderer.pitch,
                      renderer.solids.count, renderer.submergedSolids.count, renderer.solidTextures.count)
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
        // Paintings the bodies wear this frame, handed to the batch by index.
        var paintings: [String] = []
        func painting(_ name: String) -> UInt32 {
            if let i = paintings.firstIndex(of: name) { return UInt32(i + 1) }
            paintings.append(name)
            return UInt32(paintings.count)
        }
        let koiBodies = garden.koiBodies(depthScale: WaterRenderer.depthScale, textureIndex: painting,
                                              tailCentre: { renderer.textures.tailCentre($0) })
        var underBodies = koiBodies.under
        underBodies += garden.bedStoneBodies(depthScale: WaterRenderer.depthScale, mossy: season.id != "winter")
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
        // The reward rising from the deep, while it is under.
        let revealDraw = reveal?.sprites()
        if let r = revealDraw { under += r.under }
        if let bodies = reveal?.solids() {
            for b in bodies.under {
                var inst = b.instance
                if let name = b.painting { inst.texture = painting(name) }
                underBodies.append(inst)
            }
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
        // Pads, buds and the bell are thin discs wearing their paintings,
        // sitting on the water and banking with it.
        func disc(_ name: String, at p: CGPoint, side: CGFloat, yaw: Float, alpha: Float, tilt: SIMD2<Float> = .zero) -> SolidInstance {
            SolidInstance(position: SIMD2(Float(p.x), Float(p.y)), lift: 1.5, yaw: yaw, roll: 0, texture: painting(name),
                          tilt: tilt, length: 3, radius: Float(side) * 0.5, shape: 4, alpha: alpha,
                          colourA: [0.16, 0.36, 0.22, 1], colourB: [0.16, 0.36, 0.22, 1])
        }
        for p in pads {
            let side = p.radius * 2.2
            over.append(Sprite(p.sprite, at: CGPoint(x: p.centre.x + 3, y: p.centre.y + 4),
                               size: CGSize(width: side * 1.06, height: side * 1.06), mode: .shadow, alpha: 0.3, z: 0))
            solids.append(disc(p.sprite, at: p.centre, side: side, yaw: Float(p.centre.x * 0.01), alpha: 1))
        }
        for t in targets {
            let side: CGFloat = 92
            // A near miss shivers the thing: a quick small wiggle that dies.
            let shiver = Float(sin(Double(elapsed) * 38)) * 0.10 * t.tremble
            switch t.spec.kind {
            case .bud:
                if t.opening < 1 { solids.append(disc("bud_closed", at: t.position, side: side, yaw: shiver, alpha: 1 - t.opening)) }
                if t.opening > 0 { solids.append(disc("bud_open", at: t.position, side: side, yaw: 0, alpha: t.opening)) }
            case .bell:
                let since = Double(elapsed - t.wokeAt)
                let swing = t.woke ? Float(sin(since * 14) * exp(-since * 1.5)) * 0.25 : shiver
                solids.append(disc("bell_float", at: t.position, side: side, yaw: swing, alpha: 1))
            }
        }
        // The instruments: the bamboo and its stone, the chime stones, the
        // dry pool's lip. Bodies into the solids pass, the rest as sprites.
        for inst in instruments {
            solids += inst.solids(depthScale: WaterRenderer.depthScale)
            over += inst.sprites(textureSize: { [weak renderer] in renderer?.textures.size($0) ?? CGSize(width: 1, height: 1) })
        }
        // Seedlings where the seeds rooted, growing over their first seconds.
        for sp in sprouts {
            let grown = min(1, max(0, (elapsed - sp.bornAt) / 6))
            let scale = CGFloat(0.2 + 0.8 * grown)
            let s = renderer.textures.size(sp.sprite)
            let long = max(s.width, s.height)
            let side = 48 * scale
            paper(Sprite(sp.sprite, at: sp.position, size: CGSize(width: side * s.width / long, height: side * s.height / long),
                         rotation: 0, mode: .floater, alpha: min(1, grown * 3 + 0.2)), cast: 6)
        }
        solids += koiBodies.surface
        if let bodies = reveal?.solids() {
            for b in bodies.surface {
                var inst = b.instance
                if let name = b.painting { inst.texture = painting(name) }
                solids.append(inst)
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
        renderer.solids = solids
        renderer.submergedSolids = underBodies
        renderer.solidTextures = paintings
        for s in garden.skaterSprites() { paper(s) }
        // The stream's rocks carry their own shadow, and foam has no cut edge.
        over += garden.inletSprites()
        for s in garden.petalSprites() { paper(s) }
        // Leaves still on their way down, this level's own.
        if let fall = leafFall { for s in fall.sprites() { paper(s) } }
        // Drops in the air are water, not paper: no cut edge under them.
        over += garden.dropletSprites()
        over += garden.dripSprites()
        // The reward: what it threw up, its ring of light, the item once it
        // is out of the water, and its name. Light and words carry no cut
        // edge; the petals it throws are paper.
        if let r = revealDraw {
            for s in r.over {
                if s.texture == "mote" || s.texture.hasPrefix("reward_") || s.texture == "ring_light" || s.gpu.mode & 3 == SpriteInstance.Mode.shadow.rawValue {
                    over.append(s)
                } else {
                    paper(s)
                }
            }
        }
        // A leaping fish is a painting in the air, not a cut-out on the water.
        over += garden.leapSprites()
        // The first walk's ring of light, where the next tap should land.
        if let at = Tutorial.shared.spot(for: .level).flatMap(tutorialPoint) { over += Tutorial.shared.ring(at: at, time: elapsed) }
        for s in garden.floraSprites() { paper(s, cast: s.texture == art.bank ? 0 : 18) }
        over += garden.skySprites()
        // The moon in the water on a still pond: light, not paper.
        over += garden.moonSprites()
        // Mist lies over everything on the water and under the sky.
        over += garden.mistSprites()
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
    /// A piece left on ground this shallow is out of the water for good: no
    /// ripple reaches it there, so it counts as landed rather than stuck.
    private func isBeached(_ d: Debris) -> Bool {
        guard viewSize.width > 0 else { return false }
        let aspect = Float(viewSize.width / viewSize.height)
        func onGround(_ p: CGPoint) -> Bool {
            let u = CGPoint(x: p.x / viewSize.width, y: p.y / viewSize.height)
            return DepthPainter.ground(at: u, aspect: aspect) < 0.08
        }
        if onGround(d.position) { return true }
        // A long piece has run aground when either end has.
        guard d.cls == .heavy else { return false }
        let along = CGVector(dx: cos(d.angle) * d.radius * 0.8, dy: sin(d.angle) * d.radius * 0.8)
        return onGround(CGPoint(x: d.position.x + along.dx, y: d.position.y + along.dy))
            || onGround(CGPoint(x: d.position.x - along.dx, y: d.position.y - along.dy))
    }

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

    // MARK: - Goals

    /// A target wakes: the bud opens, the bell rings.
    private func wake(_ t: Target, by cause: String) {
        t.woke = true
        t.wokeAt = elapsed
        t.tremble = 0
        haptics.plop()
        switch t.spec.kind {
        case .bud: sound.bud(x: Float(t.position.x / viewSize.width))
        case .bell: sound.bell(x: Float(t.position.x / viewSize.width))
        }
        renderer?.addSplat(at: t.position, in: viewSize, radius: 14, amplitude: -0.08)
        if diagnostics { NSLog("[target] woke (%@, threshold %.3f)", cause, t.spec.threshold) }
    }

    /// A finger that was calling a koi has gone, or become something else.
    private func endCall(_ id: Int) {
        guard calling.remove(id) != nil, calling.isEmpty else { return }
        garden.releaseCall()
    }

    /// A seed never lands on a bank: on dry ground it is eased back into
    /// the water. Lying still inside the shallows long enough, it roots: the
    /// pod fades and a seedling stands where it was.
    private func tendSeed(_ d: Debris, dt: Float) {
        if d.rooted {
            d.fade = max(0, d.fade - dt * 1.2)
            if d.fade <= 0 { d.cleared = true }
            return
        }
        if isBeached(d) || DebrisPhysics.hasReachedShore(d, in: viewSize) {
            let dx = Float(viewSize.width / 2 - d.position.x), dy = Float(viewSize.height / 2 - d.position.y)
            let len = max(1, (dx * dx + dy * dy).squareRoot())
            d.velocity += SIMD2(dx, dy) / len * 40 * dt
            d.restTime = 0
            return
        }
        var inShallows = false
        for g in goals {
            guard case .rootSeeds(let bed, _) = g.kind else { continue }
            if hypot(d.position.x - bed.centre.x, d.position.y - bed.centre.y) < bed.radius { inShallows = true }
        }
        guard inShallows, simd_length(d.velocity) < 4 else { d.restTime = 0; return }
        d.restTime += dt
        guard d.restTime >= GoalTuning.rootAfter else { return }
        d.rooted = true
        rootedSeeds += 1
        let name = "sprout_\(1 + rootedSeeds % 3)"
        sprouts.append(Sprout(position: d.position, sprite: Self.spriteExists(name) ? name : d.sprite, bornAt: elapsed))
        renderer?.addSplat(at: d.position, in: viewSize, radius: 8, amplitude: -0.05)
        garden.addBubble(at: d.position)
        haptics.clear()
        sound.clearNote(index: rootedSeeds, of: max(rootedSeeds, goals.reduce(0) { n, g in
            if case .rootSeeds(_, let c) = g.kind { return n + c }
            return n
        }))
    }

    /// Leaves coming down: each one that reaches the water becomes a real
    /// piece there, and the fall stops once enough have landed.
    private func updateLeaves(dt: Float) {
        guard let fall = leafFall, viewSize != .zero else { return }
        for landing in fall.update(dt: dt, world: viewSize) {
            let d = Debris(id: 5000 + fall.landed, cls: .light, sprite: landing.texture,
                           position: landing.at, radius: 15 * landing.scale, scale: landing.scale)
            d.angle = CGFloat(landing.rotation)
            debris.append(d)
            renderer?.addSplat(at: landing.at, in: viewSize, radius: 7, amplitude: -0.10)
            sound.leaves(x: Float(landing.at.x / viewSize.width))
        }
    }

    /// The instruments read their samples and say what they did; the pond
    /// answers with sound, a shiver in the hand and a splash.
    private var instrumentPeak: [Int: Float] = [:]
    private var instrumentTrough: [Int: Float] = [:]

    /// Water depth at a world point, as the level's painter sees it.
    private func depthAt(_ p: CGPoint) -> Float {
        guard viewSize != .zero else { return 0 }
        let f = CGPoint(x: p.x / viewSize.width, y: p.y / viewSize.height)
        return DepthPainter.depth(at: f, level: level, aspect: Float(viewSize.width / viewSize.height), poolFill: poolFill)
    }

    /// From a point on or near the bank, the nearest point in open water
    /// along the way to the pond's centre, `inset` points past the edge.
    private func onWater(from p: CGPoint, inset: CGFloat) -> CGPoint {
        let c = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let dx = c.x - p.x, dy = c.y - p.y
        let len = max(1, hypot(dx, dy))
        let dir = CGVector(dx: dx / len, dy: dy / len)
        var t: CGFloat = 0
        while t < len, depthAt(CGPoint(x: p.x + dir.dx * t, y: p.y + dir.dy * t)) < 0.25 { t += 6 }
        return CGPoint(x: p.x + dir.dx * (t + inset), y: p.y + dir.dy * (t + inset))
    }

    private func updateInstruments(dt: Float, samples: [FieldSample]) {
        guard let renderer, !instruments.isEmpty else { return }
        var cursor = instrumentProbeStart
        let flat = FieldSample(height: 0, slope: .zero, velocity: 0)
        var events: [InstrumentEvent] = []
        for inst in instruments {
            let n = inst.probePoints.count
            var mine: [FieldSample] = []
            for k in 0..<n { mine.append(cursor + k < samples.count ? samples[cursor + k] : flat) }
            cursor += n
            if diagnostics {
                for (k, m) in mine.enumerated() {
                    instrumentPeak[k + cursor - n] = max(instrumentPeak[k + cursor - n] ?? 0, m.height)
                    instrumentTrough[k + cursor - n] = min(instrumentTrough[k + cursor - n] ?? 0, m.height)
                }
                if diagFrames % 120 == 0 {
                    let peaks = (0..<n).map { String(format: "%+.3f/%+.3f", instrumentPeak[$0 + cursor - n] ?? 0, instrumentTrough[$0 + cursor - n] ?? 0) }.joined(separator: " ")
                    let d = (0..<n).map { String(format: "%.2f", depthAt(inst.probePoints[$0])) }.joined(separator: " ")
                    let extra = (inst as? ShishiOdoshi).map { String(format: "fill=%.2f knocks=%d", $0.fill, $0.knocks) }
                        ?? (inst as? DryPool).map { String(format: "fill=%.2f", $0.fill) }
                        ?? (inst as? Suikinkutsu).map { "played=\($0.state.played)" } ?? ""
                    NSLog("[instrument] %@ peaks=%@ depth=%@ %@ n=%d", String(describing: type(of: inst)), peaks, d, extra, instruments.count)
                    for k in 0..<n { instrumentPeak[k + cursor - n] = 0; instrumentTrough[k + cursor - n] = 0 }
                }
            }
            if phase == .playing { inst.update(dt: dt, samples: mine, events: &events) }
            for sp in inst.splashes { renderer.addSplat(at: sp.at, in: viewSize, radius: sp.radius, amplitude: sp.amplitude) }
            inst.splashes.removeAll()
            // Each instrument keeps its own score; the goals read it from here.
            if let b = inst as? ShishiOdoshi {
                bambooState = b.state
                knocks = b.state.knocks
            }
            if let c = inst as? Suikinkutsu {
                chimeState = c.state
                notesPlayed = c.state.played
                phraseComplete = c.state.complete
            }
            if let d = inst as? DryPool {
                poolState = d.state
                poolFill = d.state.fill
                poolFull = d.state.full
            }
        }
        let w = Float(viewSize.width)
        for e in events {
            switch e {
            case .knock(let at):
                sound.bamboo(x: Float(at.x) / w)
                haptics.knock()
                renderer.addSplat(at: at, in: viewSize, radius: 14, amplitude: -0.12)
                garden.burstDroplets(at: at, power: 0.5)
            case .note(let index, let at, _):
                sound.chime(note: index, x: Float(at.x) / w)
                haptics.chime(note: index)
                renderer.addSplat(at: at, in: viewSize, radius: 6, amplitude: -0.04)
            case .phraseComplete:
                haptics.complete()
            case .phraseReplay:
                playPhrase()
            case .spill(let at, let amount):
                sound.spill(x: Float(at.x) / w)
                haptics.spill()
                // Water going over the lip: foam and wet at the edge.
                renderer.addSplat(at: at, in: viewSize, radius: 10, amplitude: -0.06 * max(0.3, amount))
                garden.burstDroplets(at: at, power: 0.2 + 0.4 * amount)
            case .poolFull:
                sound.spill(x: Float(poolState.map { _ in 0.5 } ?? 0.5))
                haptics.swell()
            }
        }
        // The pool is water now, or more of it is: the depth map is painted
        // again, a few times a second while it changes, never every frame.
        if poolFill != poolPainted, elapsed - poolRepaintAt > 0.25 {
            poolRepaintAt = elapsed
            poolPainted = poolFill
            renderer.repaintDepth()
        }
    }

    /// How glassy the pond is: the mean |velocity| over the fixed probes.
    private func updateCalm(samples: [FieldSample], dt: Float) {
        guard !calmCells.isEmpty else { return }
        var sum: Float = 0
        var n = 0
        calmSamples = []
        for k in 0..<calmCells.count where calmProbeStart + k < samples.count {
            let sample = samples[calmProbeStart + k]
            calmSamples.append(sample)
            sum += abs(sample.velocity)
            n += 1
        }
        agitation = n > 0 ? sum / Float(n) : 0
    }

    /// The goals read the pond, and the pond shows what they have made of
    /// it: the moon coming up as the water lies still.
    private var lastWakeAt: Float = -99
    private var handSloshAccumulator: Float = 0
    private var shoalPenned = false

    private func readGoals(dt: Float) {
        guard !goals.isEmpty else { return }
        let ctx = GoalContext(dt: dt, elapsed: elapsed,
                              sinceTouch: elapsed - lastTouchAt,
                              agitation: agitation,
                              iceFraction: iceField?.fraction ?? 0,
                              siltCleaned: cleaned,
                              filmCover: renderer?.filmCover ?? 0,
                              probes: calmSamples,
                              surfacedKoi: garden.surfacedKoi(),
                              shoalCentroids: garden.shoalCentroids(),
                              shyKoiOut: garden.shyKoiOut,
                              rootedSeeds: rootedSeeds,
                              remainingDebris: remainingDebris + (leafFall.map { $0.finished ? 0 : 1 } ?? 0),
                              bamboo: bambooState,
                              chime: chimeState,
                              pool: poolState,
                              targetWoke: targets.allSatisfy(\.woke),
                              sinceWake: elapsed - lastWakeAt,
                              calledKoi: garden.calledKoi,
                              handMotion: garden.handMotion)
        evaluator.update(goals: goals, ctx: ctx)
        // Stillness rises with the wait and falls away softly at a touch.
        let still = evaluator.stillness(of: goals)
        if still > stillShown { stillShown = still } else { stillShown += (still - stillShown) * min(1, dt / 1.5) }
        garden.stillness(stillShown)
    }

    // MARK: - Hints

    private func show(_ h: Hint) {
        guard !hintsShown.contains(h), !HintMemory.seen(h), hint == nil else { return }
        hintsShown.insert(h)
        hint = h
        hintAt = elapsed
    }

    private func updateHints() {
        guard phase == .playing else { return }
        // The first walk is saying what to do; a hint would say it twice.
        guard Tutorial.shared.lines[.level] == nil else { return }
        if let h = level.hint, !touchedYet, elapsed > 4.0 { show(h) }
        // Once, a little way in: how to look at the pond from the side.
        if elapsed > 30, touchedYet, !HintMemory.seen(.tilt), hint == nil { show(.tilt) }
        if level.hint == .ice, touchedYet, let f = iceField, f.fraction > 0.97, elapsed > 12 { show(.ice) }
        // A frozen pond whose sheet is open but whose goal is still not met:
        // the level's own hint, now that the ice is out of the way.
        if let h = level.hint, h != .ice, let f = iceField, f.fraction < 0.5, elapsed - lastTouchAt > 6 { show(h) }
    }

    private func dismissHint() {
        guard let h = hint else { return }
        HintMemory.markSeen(h)
        hint = nil
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
    /// close, a tilt if they are both drawn the same way up or down the
    /// screen. Once a pinch is decided the water stops hearing those fingers.
    private func updatePinch(moved id: Int) {
        guard var p = pinch, p.ids.contains(id),
              let a = screenTouches[p.ids[0]], let b = screenTouches[p.ids[1]], let r = renderer else { return }
        let now = CACurrentMediaTime()
        let here = id == p.ids[0] ? a : b
        var step = CGPoint.zero
        if let was = p.last[id] {
            step = CGPoint(x: here.x - was.x, y: here.y - was.y)
            let elapsedSince = max(1.0 / 240, now - p.lastAt)
            p.speed[id] = hypot(step.x, step.y) / CGFloat(elapsedSince)
            var t = p.travel[id] ?? .zero
            t.x += step.x
            t.y += step.y
            p.travel[id] = t
        }
        p.last[id] = here
        p.lastAt = now
        let dist = hypot(a.x - b.x, a.y - b.y)

        // A tilt, read before the pinch and read leniently: both fingers
        // going the same way, the pair's middle travelling more up or down
        // than across, and the two of them not spreading. Speed says
        // nothing, so a brisk drag tilts as surely as a slow one, and the
        // whole thing is decided inside the first few points of travel.
        if !p.active, !p.tilting,
           let ta = p.travel[p.ids[0]], let tb = p.travel[p.ids[1]] {
            let mid = CGPoint(x: (ta.x + tb.x) / 2, y: (ta.y + tb.y) / 2)
            let sameWay = ta.y * tb.y > 0
            let upright = abs(mid.y) > (abs(mid.x) + abs(mid.y)) * GameTuning.tiltUpright
            let held = abs(dist - p.startDistance) < GameTuning.tiltSpread
            if sameWay, upright, held, hypot(mid.x, mid.y) > GameTuning.tiltTravel {
                p.tilting = true
                r.cancelAll()
                for pid in p.ids { forgetWaterTouch(pid) }
            }
        }

        if p.tilting {
            // Half the step from each of the two fingers is their average.
            // Drawn up the screen the camera lies down toward the water.
            r.pitchTarget -= Float(step.y) * 0.5 * GameTuning.tiltPerPoint
            pinch = p
            return
        }

        if !p.active {
            guard abs(dist - p.startDistance) > 18 else { pinch = p; return }
            // Two fingers thrown the same way are a gust, and a gust must not
            // be read as a pinch just because the hand spread a little.
            if gustPair() != nil { pinch = p; return }
            p.active = true
            r.cancelAll()
            for pid in p.ids { forgetWaterTouch(pid) }
        }
        let z = max(GameTuning.zoomMin, min(GameTuning.zoomMax, p.startZoom * Float(dist / max(1, p.startDistance))))
        zoomTarget = z
        // Keep the world point that was under the fingers under them.
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        centreTarget = p.anchorWorld - SIMD2(Float(mid.x - screenSize.width / 2), Float(mid.y - screenSize.height / 2)) / z
        pinch = p
    }

    /// A finger that turned out to belong to the camera and not the water:
    /// its hold, its wake and its voice all go.
    private func forgetWaterTouch(_ id: Int) {
        pondTouches.removeValue(forKey: id)
        endCall(id)
        if holdSounding.remove(id) != nil { sound.holdEnd(id: id) }
        if wakeSounding.remove(id) != nil { sound.wakeEnd(id: id); haptics.slideEnd() }
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
        t.travelled += step

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
            if !t.isSlosh { beginStroke(id: id) }
            t.isWake = true
            t.isSlosh = false
        }
        // Slower than a wake but going somewhere: the hand is not cutting the
        // water, it is pushing it. Once it has carried far enough the hold is
        // let go and a body of water is shoved along ahead of the finger.
        if !t.isWake, !t.isSlosh, !t.spent,
           t.speed > GameTuning.sloshSlowest, t.travelled > GameTuning.sloshTravel {
            t.isSlosh = true
            beginStroke(id: id)
        }

        if t.isWake, !t.spent {
            let strength = min(1.6, max(0.35, t.speed / GameTuning.wakeFullSpeed))
            if t.wakePath.isEmpty { t.wakePath.append(t.last) }
            if step > 4 { t.wakePath.append(point) }
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
        } else if t.isSlosh, !t.spent {
            // Broad and shallow, laid a step at a time: the water in front of
            // the hand is heaped up and runs on to the bank on its own.
            sound.wakeLevel(id: id, speed: t.speed * 0.35)
            haptics.slide(speed: t.speed, grain: 0.05, travel: Float(step))
            t.sinceSplat += step
            if t.sinceSplat >= GameTuning.sloshSpacing {
                let n = min(Int(t.sinceSplat / GameTuning.sloshSpacing), 4)
                t.sinceSplat -= CGFloat(n) * GameTuning.sloshSpacing
                for i in 1...n {
                    let f = CGFloat(i) / CGFloat(n)
                    budgetedSplat(at: CGPoint(x: t.last.x + dx * f, y: t.last.y + dy * f),
                                  radius: GameTuning.sloshRadius,
                                  amplitude: GameTuning.sloshAmplitude)
                }
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

    /// A finger that has stopped pressing and started moving water: the hold
    /// it was charging goes, and the water rushing past it is heard and felt.
    private func beginStroke(id: Int) {
        renderer?.cancelHold(id: id)
        endCall(id)
        if holdSounding.remove(id) != nil { sound.holdEnd(id: id) }
        sound.wakeBegin(id: id)
        wakeSounding.insert(id)
        haptics.slideBegin()
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
        leafFall?.blow(direction: direction, strength: 90)
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

    // MARK: - The pond's own weather

    /// Wind the player did not ask for. Every half minute or so a front
    /// crosses the pond: a line of small dips marching along at walking pace,
    /// the petals blown with it, the reeds and the weeds leaning as it goes.
    private func updateWind(dt: Float) {
        guard let renderer, viewSize != .zero, phase != .complete else { return }
        // A pond that is asked to lie still is spared its own weather.
        let wantsStill = goals.contains { if case .stillness = $0.kind { return true }; return false }
        if wind == nil, elapsed > nextWindAt, !(wantsStill && phase == .playing) {
            nextWindAt = elapsed + Float.random(in: 20...45)
            startWind()
        }
        guard var g = wind else { return }
        g.age += dt
        let seconds: Float = 1.5
        let front = CGFloat(400 * g.age)
        let perp = SIMD2(-g.direction.y, g.direction.x)
        let across = abs(perp.x) * Float(viewSize.width) + abs(perp.y) * Float(viewSize.height)
        // Softest at the two ends of the sweep, fullest in the middle of it.
        let body = sin(Float.pi * min(1, g.age / seconds))
        let n = 10
        for i in 0..<n {
            let f = (Float(i) / Float(n - 1) - 0.5) * across * 1.05
            // The front is not a ruled line: each dab sits a little ahead of
            // or behind it.
            let ahead = front + CGFloat.random(in: -16...16)
            let at = CGPoint(x: g.origin.x + CGFloat(g.direction.x) * ahead + CGFloat(perp.x * f),
                             y: g.origin.y + CGFloat(g.direction.y) * ahead + CGFloat(perp.y * f))
            renderer.addSplat(at: at, in: viewSize, radius: 3, amplitude: -0.012 * (0.5 + 0.5 * body))
        }
        garden.blow(direction: g.direction, strength: 70 * dt)
        leafFall?.blow(direction: g.direction, strength: 70 * dt)
        garden.lean(direction: g.direction, strength: 2.6 * dt)
        wind = g.age >= seconds ? nil : g
    }

    private func startWind() {
        guard viewSize != .zero else { return }
        let angle = Float.random(in: 0...(2 * .pi))
        let direction = SIMD2(cos(angle), sin(angle))
        let w = Float(viewSize.width), h = Float(viewSize.height)
        let centre = SIMD2(w / 2, h / 2)
        let span = abs(direction.x) * w + abs(direction.y) * h
        let start = centre - direction * (span / 2 + 60)
        wind = Wind(direction: direction, origin: CGPoint(x: CGFloat(start.x), y: CGFloat(start.y)))
        sound.breeze(x: 0.5 - direction.x * 0.3)
    }

    /// The stream running in: a ripple train off the rocks, frame after
    /// frame, and a slow current that leans the whole pond away from it.
    private func updateInlet(dt: Float) {
        guard let renderer, let flow = garden.inletFlow(), phase != .complete else { return }
        let at = CGPoint(x: flow.at.x + flow.into.dx * 12 + CGFloat.random(in: -7...7),
                         y: flow.at.y + flow.into.dy * 12 + CGFloat.random(in: -7...7))
        renderer.addSplat(at: at, in: viewSize, radius: 8, amplitude: -0.03)
        // It only ever adds up to a drift. A stroke along the bank is still
        // much the stronger current, and this never fights it.
        if simd_length(current) < GameTuning.inletCurrent {
            current += SIMD2(Float(flow.into.dx), Float(flow.into.dy)) * GameTuning.inletCurrentGain * dt
        }
    }

    /// What the garden did this frame that a hand would hear or feel.
    private func soundGarden() {
        guard viewSize.width > 0 else { garden.events.removeAll(); return }
        for e in garden.events {
            switch e {
            case .leapOut(let p):
                sound.holdRelease(charge: 1)
                haptics.holdRelease(charge: 0.8)
                garden.startle(at: p, in: viewSize)
            case .leapIn(let p):
                sound.holdRelease(charge: 0.65)
                haptics.holdRelease(charge: 0.4)
                garden.startle(at: p, in: viewSize)
            case .drip(let p):
                sound.drip(x: Float(p.x / viewSize.width))
            case .mouth(let p):
                sound.mouth(x: Float(p.x / viewSize.width))
            case .dip(let p):
                sound.drip(x: Float(p.x / viewSize.width))
                haptics.tap(weight: 0.1)
            }
        }
        garden.events.removeAll()
    }

    // MARK: - Scripted triggers

    /// `-gestures "leap:@t"`: a koi goes up now, so the leap can be watched.
    func scriptedLeap() { garden.leapNow() }

    /// `-gestures "drip:@t"`: a drop leaves a branch now.
    func scriptedDrip() {
        garden.dripping = true
        garden.dripNow()
    }

    /// `-gestures "dusk:@t"`: the day jumps to late light.
    func scriptedDusk(_ phase: Float) { renderer?.dayPhase = phase }

    /// `-gestures "wind:@t"`: the wind crosses now.
    func scriptedWind() { startWind() }

    /// Two taps in one spot: a stone goes in. A deep splat, water thrown up,
    /// and everything nearby feels it land.
    private func dropStone(at point: CGPoint) {
        guard viewSize != .zero else { return }
        renderer?.addSplat(at: point, in: viewSize, radius: GameTuning.stoneRadius,
                           amplitude: GameTuning.stoneAmplitude)
        garden.burstDroplets(at: point, power: 1)
        garden.startle(at: point, in: viewSize)
        garden.bigSplash(at: point)
        waveBitesIce(from: point)
        sound.holdRelease(charge: 1)
        haptics.holdRelease(charge: 1)
    }

    func touchBegan(id: Int, at screen: CGPoint, in screenBounds: CGSize, weight: Float) {
        screenSize = screenBounds
        // A menu is in the way: nothing reaches the water through it.
        if presented != nil { return }
        touchedYet = true
        dismissHint()
        guard phase == .playing || phase == .celebrating, viewSize != .zero else { return }
        // The reward is up: a tap anywhere sends it on its way to the bank.
        if let r = reveal, r.canDive {
            r.dive()
            haptics.tap(weight: 0.4)
            return
        }
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
                          startZoom: r.zoom, anchorWorld: SIMD2(Float(anchor.x), Float(anchor.y)),
                          last: [other: op, id: screen], lastAt: CACurrentMediaTime())
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
        agitationAtTouch = agitation
        lastTouchAt = elapsed
        garden.startle(at: point, in: size)
        if let k = garden.koiHit(at: point) {
            garden.dive(k)
            sound.plop()
            haptics.plop()
        }
        // The second finger of a pair makes no ring: two fingers are a
        // swell, a pinch, a tilt or a gust, none of which begins with a tap.
        renderer?.touchDown(id: id, at: point, in: size, weight: weight, ring: pinch == nil)
        pondTouches[id] = PondTouch(last: point, lastAt: CACurrentMediaTime())
        if pinch == nil {
            sound.tap(x: Float(point.x / size.width), weight: weight)
            haptics.tap(weight: weight)
        }
    }

    func touchMoved(id: Int, to screen: CGPoint, in screenBounds: CGSize) {
        if presented != nil { return }
        screenTouches[id] = screen
        if pinch != nil {
            updatePinch(moved: id)
            // A finger that turned out to be half a pinch, or half a tilt, is
            // no longer on the ice.
            if pinch?.active == true || pinch?.tilting == true {
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
            lastTouchAt = elapsed
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
            Tutorial.shared.note(.iceSlid(step))
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
        if presented != nil { return }
        if let p = pinch, p.ids.contains(id) {
            pinch = nil
            if p.active || p.tilting { renderer?.touchUp(id: id); pondTouches.removeValue(forKey: id); return }
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
            lastTouchAt = elapsed
            if wakeSounding.remove(id) != nil {
                sound.wakeEnd(id: id)
                haptics.slideEnd()
            }
            // The whirl keeps turning on its own once the hand has gone.
            if whirl?.stirring == id { whirl?.stirring = nil }
            if holdSounding.remove(id) != nil { sound.holdEnd(id: id) }
            endCall(id)
            renderer?.touchUp(id: id)
            // The wake is laid: the shoal takes it up.
            if t.isWake, t.wakePath.count >= 2 {
                garden.followWake(path: t.wakePath + [point])
                lastWakeAt = elapsed
            }
            // A plain tap, and one just landed beside it: a stone drops in.
            let plain = !t.isWake && !t.isSlosh && !t.spent && t.held < Float(GameTuning.doubleTapSeconds)
            let now = CACurrentMediaTime()
            if plain, let last = lastTap, now - last.at < GameTuning.doubleTapSeconds,
               hypot(last.point.x - point.x, last.point.y - point.y) < GameTuning.doubleTapDistance {
                lastTap = nil
                dropStone(at: CGPoint(x: (last.point.x + point.x) / 2, y: (last.point.y + point.y) / 2))
            } else {
                lastTap = plain ? (point, now) : nil
                // One ring on a quiet pond: the koi far off turn to look.
                if plain { garden.curious(tap: point, calm: agitationAtTouch < 3 * GoalTuning.calmThreshold) }
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
        winNow = false
        Tutorial.shared.note(.levelFinished)
        iceField?.sinkAll(time: renderer?.clock ?? 0)
        garden.releaseCall()
        calling.removeAll()
        let target = level.bloomTarget
        let alreadyComplete = progress.isComplete(levelID: level.id)
        progress.markComplete(levelID: level.id, seasonID: season.id, bloomStage: target)
        // What this pond woke stays woken on the map.
        let woke = goals.reduce(into: Set<WokeToken>()) { $0.formUnion($1.wakes) }
        progress.markWoke(levelID: level.id, tokens: woke)
        // The draw: what this win gives, and what it pays.
        var rng = SystemRandomNumberGenerator()
        let drawn = RewardSource.award(level: level.id, replay: alreadyComplete, using: &rng)
        if let textures = renderer?.textures {
            reveal = RewardReveal(award: RewardReveal.Award(item: drawn.item, rarity: drawn.rarity, petals: drawn.petals),
                                  textures: textures, world: viewSize,
                                  centre: worldAt(CGPoint(x: 0.5, y: 0.50)),
                                  wordsAt: worldAt(CGPoint(x: 0.5, y: 0.70)),
                                  bank: CGPoint(x: viewSize.width - 36, y: worldAt(CGPoint(x: 0.5, y: 0.5)).y),
                                  seasonID: season.id, petalTexture: art.petalParticle)
        }
        // The bloom and the reveal overlap: the burst comes with the bloom,
        // the item rises a moment later, and the words wait for the dive.
        celebration = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(0.8))
            if Task.isCancelled { return }
            self.garden.bloom(to: target, duration: 5.0)
            if let r = self.reveal { r.burst() } else { self.sound.complete(); self.haptics.complete() }
            try? await Task.sleep(for: .seconds(1.2))
            if Task.isCancelled { return }
            self.reveal?.reveal()
            while let r = self.reveal, !r.isDone {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
            }
            self.reveal = nil
            self.phase = .complete
            // Nothing at all for a moment: no scrim, no words, no cue. The
            // ripples the player made are allowed to die out on their own,
            // and that silence is the reward.
            try? await Task.sleep(for: .seconds(Motion.completionPause))
            if Task.isCancelled { return }
            self.showCompletion()
        }
    }

    /// The reward moment is fed, and what it asks for goes into the water,
    /// the garden, the bed, the speaker and the hand.
    private func updateReveal(dt: Float, renderer: WaterRenderer) {
        guard let r = reveal else { return }
        r.update(dt: dt)
        for s in r.splashes { renderer.addSplat(at: s.at, in: viewSize, radius: s.radius, amplitude: s.amplitude) }
        for b in r.bubbles { garden.addBubble(at: b) }
        for e in r.events {
            switch e {
            case .chord:
                sound.rewardChord(tier: r.award.rarity)
                haptics.reward(tier: r.award.rarity)
            case .revealNote:
                sound.rewardNote(tier: r.award.rarity)
            case .dive:
                sound.rewardDive()
                haptics.plop()
            case .petals:
                sound.petalPick()
                haptics.tap(weight: 0.3)
            }
        }
        r.drain()
        // The bed's light goes gold for the burst and comes back.
        if let base = baseLook {
            let gold = r.bedGold
            if gold > 0.004 || revealGoldShown > 0.004 {
                renderer.floorLook = GameController.golden(base, by: gold)
                revealGoldShown = gold
            }
        }
    }
    /// How gold the bed was last painted, so it is painted back once.
    private var revealGoldShown: Float = 0

    /// The season's bed warmed toward gold by `t`: the light of the reward
    /// on the floor and in the water.
    private static func golden(_ base: FloorLook, by t: Float) -> FloorLook {
        var look = base
        func warm(_ c: SIMD3<Float>) -> SIMD3<Float> {
            // A warm breath of light on the bed, not a wash: the pond must
            // still look like itself while the prize comes up.
            let gold = c * SIMD3(1.25, 1.15, 0.85) + SIMD3(0.06, 0.04, 0.0)
            return simd_mix(c, gold, SIMD3(repeating: t * 0.35))
        }
        look.deep = warm(base.deep)
        look.mid = warm(base.mid)
        look.shallow = warm(base.shallow)
        look.waterTint = simd_mix(base.waterTint, SIMD3(1.0, 0.92, 0.72), SIMD3(repeating: t * 0.5))
        look.waterTintStrength = base.waterTintStrength + 0.08 * t
        return look
    }

    func next() {
        guard let following = Library.level(after: level) else { return }
        load(level: following)
    }

    // MARK: - Words and menus

    /// A point in the pond at this fraction of the screen, kept inside the
    /// water so nothing is laid out on the bank.
    private func worldAt(_ f: CGPoint) -> CGPoint {
        guard viewSize != .zero else { return .zero }
        guard screenSize != .zero else { return CGPoint(x: viewSize.width * f.x, y: viewSize.height * f.y) }
        let p = worldPoint(CGPoint(x: screenSize.width * f.x, y: screenSize.height * f.y))
        return CGPoint(x: min(max(p.x, 50), viewSize.width - 50),
                       y: min(max(p.y, 50), viewSize.height - 50))
    }

    /// Where the first walk's ring goes in this pond: the middle of the
    /// sheet that is left, or inside the ring the last strike opened.
    private func tutorialPoint(_ spot: Tutorial.Spot) -> CGPoint? {
        switch spot {
        case .iceCentre: return iceField?.nearestIcePoint(to: worldAt(CGPoint(x: 0.5, y: 0.5)), range: 2000)
        case .iceAt(let p): return (iceField?.ice(at: p) ?? 0) > 0.5 ? p : iceField?.nearestIcePoint(to: p, range: 2000)
        default: return nil
        }
    }

    /// The level opens: its name and what it is for, low in the pond.
    private func openWords() {
        statusText = ""
        statusKey = SIMD4<Int>(-1, -1, -1, -1)
        updateStatus()
        updateWords()
    }

    /// One slot, filled by whatever matters most right now: a hint while it
    /// is up, then the line that opened the level for its first few seconds,
    /// then what is left.
    private func updateWords() {
        var next: PondWords?
        // Once the pond is being cleared there is nothing on the screen at
        // all: the last ripples are allowed to die out on their own.
        if phase == .playing {
            if let h = hint {
                next = PondWords(title: nil, line: h.text)
            } else if elapsed < 6 {
                // The level's name over its goal, with the season and
                // number small above them. A level without a name yet
                // opens on its number alone.
                next = level.name.isEmpty
                    ? PondWords(title: level.title, line: level.goal)
                    : PondWords(title: level.name, line: level.goal, chapter: level.title)
            } else if !statusText.isEmpty {
                next = PondWords(title: nil, line: statusText)
            }
        }
        if next != words { words = next }
    }

    /// What is left, from the goals not yet met, said the way the level's
    /// opening line says things: a quiet sentence, never a readout. The
    /// first two unmet goals are joined; any more wait their turn. The line
    /// is only written again when it has changed.
    private func updateStatus() {
        var parts: [String] = []
        let states = evaluator.states
        for (i, g) in goals.enumerated() where i < states.count && !states[i].done {
            parts.append(statusPhrase(for: g.kind, state: states[i]))
        }
        // The line is written when its words change, not every frame.
        let key = SIMD4<Int>(parts.count, parts.joined(separator: ",").hashValue & 0x7FFFFFFF, 0, 0)
        guard key != statusKey else { return }
        statusKey = key
        statusText = parts.isEmpty ? (goals.isEmpty ? "" : "The pond wakes.") : parts.prefix(2).joined(separator: "; ")
    }

    /// One goal's sentence while it is still open.
    private func statusPhrase(for kind: GoalKind, state st: GoalEvaluator.State) -> String {
        switch kind {
        case .clearDebris:
            let left = remainingDebris + (leafFall.map { $0.total - $0.landed } ?? 0)
            if level.leaves > 0 {
                if left == 1 { return "One leaf still to reach the bank" }
                return "\(Words.count(left, capitalised: true)) leaves still to reach the bank"
            }
            let logs = debris.filter { !$0.cleared && $0.cls == .heavy && $0.meltsIn == nil }.count
            if logs == left, left > 0 {
                return left == 1 ? "The log still lies in the way" : "The logs still lie in the way"
            }
            if left == 1 { return "One piece still to reach the bank" }
            return "\(Words.count(left, capitalised: true)) pieces still to reach the bank"
        case .breakIce:
            return Words.byThirds(iceField?.fraction ?? 1,
                                  "A last few scraps of ice", "The ice is breaking up", "The ice holds")
        case .clearSilt:
            return Words.byThirds(1 - cleaned,
                                  "The bed is nearly clear", "The silt is clearing", "The silt still lies thick")
        case .partDuckweed:
            return Words.byThirds(renderer?.filmCover ?? 1,
                                  "A last drift of duckweed", "The duckweed is parting", "The duckweed lies unbroken")
        case .rootSeeds(_, let n):
            let left = max(0, n - rootedSeeds)
            if left == 1 { return "One seed still to root" }
            return "\(Words.count(left, capitalised: true)) seeds still to root"
        case .callKoi:
            return "Hold a finger on the water and the koi will rise to it"
        case .koiOpensBud:
            return "The bud waits for the koi"
        case .leadShoal:
            return "The shoal has not gone through"
        case .temptShyKoi:
            return "The shy koi keeps to its hiding place"
        case .wakeTarget(let kind, _, _):
            return kind == .bud ? "The bud sleeps" : "The bell hangs silent"
        case .shishiOdoshi(_, let n):
            let k = min(knocks, n)
            if k == 0 { return "The bamboo waits for its first knock" }
            return "The bamboo has knocked \(Words.times(k))"
        case .suikinkutsu(_, let order):
            let played = min(notesPlayed.count, order.count)
            let left = max(0, order.count - played)
            if played == 0 { return "The stones wait for their first note" }
            if left == 1 { return "\(Words.count(played, capitalised: true)) notes played, one to go" }
            return "\(Words.count(played, capitalised: true)) \(played == 1 ? "note" : "notes") played, \(Words.count(left)) to go"
        case .fillPool:
            if poolFill <= 0.02 { return "The pool is dry" }
            return Words.byThirds(1 - poolFill,
                                  "The pool is nearly full", "The pool is half full", "The pool is filling")
        case .stillness(let seconds):
            if st.held <= 0 { return "Hold the phone still and let the water go glassy" }
            return st.held < seconds * 0.6 ? "Stillness gathers" : "Almost still"
        }
    }

    /// Pieces still on the water that are the player's to clear: not seeds,
    /// not chunks of ice on their way to melting.
    private var remainingDebris: Int {
        debris.filter { !$0.cleared && !$0.kind.isSeed && $0.meltsIn == nil }.count
    }

    /// A menu opens: one real impulse in the real water at the point that
    /// asked for it, and then the scrim. That single ring is the whole
    /// diegetic ambition, kept, at no cost to legibility.
    private func present(_ screen: MenuScreen, from screen0: CGPoint?) {
        if viewSize != .zero {
            let at = screen0.map { worldPoint($0) } ?? worldAt(CGPoint(x: 0.5, y: 0.6))
            renderer?.addSplat(at: at, in: viewSize, radius: 90, amplitude: -0.09)
        }
        sound.plop()
        haptics.swell()
        withAnimation(Motion.scrim) { presented = screen }
    }

    func openSettings(from screen: CGPoint? = nil) { present(.settings, from: screen) }

    func openStore(from screen: CGPoint? = nil) { present(.store, from: screen) }

    /// The pond is clear: four words and two ways on.
    func showCompletion() {
        withAnimation(Motion.scrim) { presented = .complete }
        Tutorial.shared.note(.completionShown)
    }

    /// Arriving is savoured; leaving is instant.
    func closeMenu() {
        guard presented != nil, presented != .complete else { return }
        sound.holdRelease(charge: 0.25)
        haptics.holdRelease(charge: 0.25)
        withAnimation(Motion.leave) { presented = nil }
    }

    /// Whether the completion may offer the next pond.
    var hasNext: Bool { Library.level(after: level) != nil }

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
            hintAt = elapsed
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
    /// A near miss set this to 1; it dies away over a second or so.
    var tremble: Float = 0
    var lastTrembleAt: Float = -10
    init(spec: TargetSpec, position: CGPoint) {
        self.spec = spec
        self.position = position
    }
}

enum HintMemory {
    static func seen(_ h: Hint) -> Bool {
        if ProcessInfo.processInfo.arguments.contains("-resetHints") { return false }
        return UserDefaults.standard.bool(forKey: "hint.seen.\(h.rawValue)")
    }
    static func markSeen(_ h: Hint) { UserDefaults.standard.set(true, forKey: "hint.seen.\(h.rawValue)") }
}

/// Numbers said as words, so a line under the pond never reads as a readout.
enum Words {
    private static let small = ["zero", "one", "two", "three", "four", "five", "six",
                                "seven", "eight", "nine", "ten", "eleven", "twelve"]

    /// "one" ... "twelve", and "many" past that.
    static func count(_ n: Int, capitalised: Bool = false) -> String {
        let w = n >= 0 && n < small.count ? small[n] : "many"
        return capitalised ? w.prefix(1).uppercased() + w.dropFirst() : w
    }

    /// "once", "twice", "three times".
    static func times(_ n: Int) -> String {
        switch n {
        case 1: return "once"
        case 2: return "twice"
        default: return "\(count(n)) times"
        }
    }

    /// One of three phrases for how much of something remains, 0...1: the
    /// last third, the middle, and the first.
    static func byThirds(_ remaining: Float, _ low: String, _ mid: String, _ high: String) -> String {
        remaining < 1.0 / 3 ? low : (remaining < 2.0 / 3 ? mid : high)
    }
}

/// Smooth value noise in 0...1. The pond and the stream both wander their
/// shorelines with it, so no bank is ever a straight line.
enum ShoreNoise {
    static func value(_ x: Float, _ y: Float) -> Float {
        func hash(_ i: Int, _ j: Int) -> Float {
            var h = UInt32(truncatingIfNeeded: i) &* 374761393 &+ UInt32(truncatingIfNeeded: j) &* 668265263
            h = (h ^ (h >> 13)) &* 1274126177
            return Float(h & 0xFFFF) / 65535
        }
        let ix = Int(floor(x)), iy = Int(floor(y))
        let fx = x - floor(x), fy = y - floor(y)
        let ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy)
        let a = hash(ix, iy), b = hash(ix + 1, iy), c = hash(ix, iy + 1), d = hash(ix + 1, iy + 1)
        let lo = a + (b - a) * ux
        return lo + ((c + (d - c) * ux) - lo) * uy
    }
}

/// Turns a level's rocks and shallows into the depth map the wave kernel
/// samples. 1 is deep open water, 0 is a wall.
enum DepthPainter {
    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// Where the bowl stops and the shore begins, and where the ground is
    /// dry. The line between them wanders, so no pond has a straight edge.
    static let shoreStart: Float = 0.86
    static let shoreEnd: Float = 0.93
    /// Depth of dry ground. Below `dryDepth` no ripple reaches a piece.
    static let dryDepth: Float = 0.03

    /// How far out a point is, 0 at the middle and 1 at the pond's edge. No
    /// pond is a rectangle: the edge is a rounded shape with soft corners,
    /// and it swells and pinches a little round its length.
    static func rimAt(bx: Float, by: Float, aspect: Float) -> Float {
        let rx = abs(bx) / (0.5 * aspect), ry = abs(by) / 0.5
        // A rounder shape than before (the sides were nearly straight),
        // with a bigger slow swell so the pond is a lobed oval, and enough
        // bank round it for the plants to stand on.
        let n: Float = 3.4
        let rounded = pow(pow(rx, n) + pow(ry, n), 1 / n)
        // Sampled on a circle so the wobble meets itself round the back.
        let angle = atan2(by, bx)
        let swell = (ShoreNoise.value(cos(angle) * 1.6 + 10, sin(angle) * 1.6 + 10) - 0.5) * 0.22
        return rounded / (1 + swell)
    }

    /// The bowl shelving up to the bank at the world's rim, on a shoreline
    /// that wanders. `d` is the bowl's depth here.
    private static func shore(_ d: Float, rim: Float, px: Float, py: Float) -> Float {
        // A slow swell of the shoreline and a finer raggedness over it.
        let wander = (ShoreNoise.value(px * 6.5, py * 6.5) - 0.5) * 0.05
                   + (ShoreNoise.value(px * 21.0 + 4.3, py * 21.0 + 9.1) - 0.5) * 0.018
        let up = smoothstep(shoreStart + wander, shoreEnd + wander, rim)
        return d + (dryDepth - d) * up
    }

    /// The bed alone at a unit point: the bowl and the shore it shelves up
    /// to, with none of the rocks and pads that stand in it. This is what
    /// says whether a piece is on dry ground.
    static func ground(at p: CGPoint, aspect: Float) -> Float {
        let px = Float(p.x), py = Float(p.y)
        let bx = (px - 0.5) * aspect, by = py - 0.5
        let rim = rimAt(bx: bx, by: by, aspect: aspect)
        return shore(1 - 0.62 * smoothstep(0.55, 1.0, rim), rim: rim, px: px, py: py)
    }

    /// The dry pool a level may have beyond its lip, as a fraction of the
    /// world, if it has one.
    private static func pool(of level: LevelSpec) -> (centre: CGPoint, radius: CGFloat, lip: CGPoint)? {
        for g in level.goals {
            if case .fillPool(let lip, let pool, _) = g.kind { return (pool.centre, pool.radius, lip) }
        }
        return nil
    }

    /// Depth at a unit point: the bowl, then the level's shallows and rocks,
    /// and the dry pool beyond the lip as far as it has filled.
    static func depth(at p: CGPoint, level: LevelSpec, aspect: Float, poolFill: Float = 0) -> Float {
        let px = Float(p.x), py = Float(p.y)
        // The pond is a bowl: deep in the middle, shelving to the banks,
        // so waves slow near the edge and the bed shows there.
        let bx = (px - 0.5) * aspect, by = py - 0.5
        let rim = rimAt(bx: bx, by: by, aspect: aspect)
        var d: Float = 1 - 0.62 * smoothstep(0.55, 1.0, rim)
        d = shore(d, rim: rim, px: px, py: py)
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
        // The dry pool: a walled hollow at the bank, dry until it fills,
        // ringed by a rim of ground with one low sill on the pond side.
        // Water crossing the sill fills it; full, it is as deep as the
        // shelf and the sill sinks so it joins the pond.
        if let pool = pool(of: level) {
            let r = Float(pool.radius)
            let dx = (px - Float(pool.centre.x)) * aspect, dy = py - Float(pool.centre.y)
            let dist = (dx * dx + dy * dy).squareRoot() / r
            if dist < 1 {
                d = max(dryDepth, poolFill * 0.3 * (1 - dist * dist * 0.5))
            } else if dist < 1.16 {
                let gx = Float(pool.lip.x - pool.centre.x) * aspect, gy = Float(pool.lip.y - pool.centre.y)
                let gl = max(0.001, (gx * gx + gy * gy).squareRoot())
                let toward = (dx * gx + dy * gy) / (dist * r * gl)
                d = toward > 0.8 ? min(d, 0.09 + poolFill * 0.25) : dryDepth
            }
        }
        return d
    }

    static func paint(level: LevelSpec, width: Int, height: Int, poolFill: Float = 0) -> [Float] {
        var map = [Float](repeating: 1, count: width * height)
        let fw = Float(width), fh = Float(height)
        let aspect = fw / fh
        for y in 0..<height {
            for x in 0..<width {
                map[y * width + x] = depth(at: CGPoint(x: CGFloat(Float(x) / fw), y: CGFloat(Float(y) / fh)),
                                           level: level, aspect: aspect, poolFill: poolFill)
            }
        }
        return map
    }
}

// MARK: - Goals

/// Marks each goal met from what the pond reads each frame, and keeps what
/// a goal has to remember between frames: how long a condition has held,
/// where each shoal was, so a crossing can be seen.
final class GoalEvaluator {
    struct State {
        var done = false
        /// Seconds a condition has held: a koi up within reach, the pond glassy.
        var held: Float = 0
        /// Where each shoal's centroid was last frame.
        var centroids: [CGPoint] = []
    }
    private(set) var states: [State] = []

    func reset(count: Int) { states = Array(repeating: State(), count: count) }

    var allDone: Bool { !states.isEmpty && states.allSatisfy(\.done) }

    /// How far toward its stillness the pond has come, 0...1, over the
    /// stillness goals (1 when there are none and everything else is met).
    /// Whether the first goal matching `test` is done.
    func isDone(goals: [GoalSpec], _ test: (GoalSpec) -> Bool) -> Bool {
        for (i, g) in goals.enumerated() where i < states.count && test(g) { return states[i].done }
        return false
    }

    func stillness(of goals: [GoalSpec]) -> Float {
        var out: Float = 0
        for (i, g) in goals.enumerated() where i < states.count {
            if case .stillness(let seconds) = g.kind {
                out = max(out, states[i].done ? 1 : min(1, states[i].held / max(0.1, seconds)))
            }
        }
        return out
    }

    /// Signed side of the line through `a` and `b` that `p` lies on.
    private static func side(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
    }

    /// Whether the step from `p0` to `p1` crosses the gate between its ends.
    private static func crosses(_ p0: CGPoint, _ p1: CGPoint, gate a: CGPoint, _ b: CGPoint) -> Bool {
        let s0 = side(p0, a, b), s1 = side(p1, a, b)
        guard s0 * s1 < 0 else { return false }
        // Where the step meets the gate's line, as a fraction along the gate.
        let t = s0 / (s0 - s1)
        let x = p0.x + (p1.x - p0.x) * t, y = p0.y + (p1.y - p0.y) * t
        let gx = b.x - a.x, gy = b.y - a.y
        let len2 = max(1, gx * gx + gy * gy)
        let u = ((x - a.x) * gx + (y - a.y) * gy) / len2
        return u >= 0 && u <= 1
    }

    func update(goals: [GoalSpec], ctx: GoalContext) {
        guard states.count == goals.count else { reset(count: goals.count); return }
        for (i, g) in goals.enumerated() where !states[i].done {
            var st = states[i]
            switch g.kind {
            case .clearDebris:
                st.done = ctx.remainingDebris == 0
            case .breakIce:
                st.done = ctx.iceFraction < 0.06
            case .clearSilt(let clean):
                st.done = ctx.siltCleaned >= clean
            case .partDuckweed(let cover):
                st.done = ctx.filmCover <= cover
            case .rootSeeds(_, let n):
                st.done = ctx.rootedSeeds >= n
            case .callKoi(let at, let r):
                // A koi that has come up to the finger anywhere counts, as
                // does one surfaced where the level asked for it.
                let near = ctx.calledKoi != nil || ctx.surfacedKoi.contains { hypot($0.x - at.x, $0.y - at.y) < r }
                st.held = near ? st.held + ctx.dt : 0
                st.done = st.held >= GoalTuning.callHold
            case .koiOpensBud:
                st.done = ctx.targetWoke
            case .leadShoal(let gate):
                // Only a shoal that was led counts: through the gate from
                // its own side within a few seconds of a wake being laid.
                let now = ctx.shoalCentroids
                if st.centroids.count == now.count, ctx.sinceWake < 8 {
                    let gy = (gate.0.y + gate.1.y) / 2
                    for (k, c) in now.enumerated()
                    where st.centroids[k].y > gy && Self.crosses(st.centroids[k], c, gate: gate.0, gate.1) {
                        st.done = true
                    }
                }
                st.centroids = now
            case .temptShyKoi:
                st.done = ctx.shyKoiOut
            case .wakeTarget:
                st.done = ctx.targetWoke
            case .shishiOdoshi(_, let n):
                st.done = (ctx.bamboo?.knocks ?? 0) >= n
            case .suikinkutsu:
                st.done = ctx.chime?.complete ?? false
            case .fillPool:
                st.done = ctx.pool?.full ?? false
            case .stillness(let seconds):
                // Glassy water and a still hand: moving the phone sloshes
                // the pond, so the wait is something the player does.
                let calm = ctx.sinceTouch > GoalTuning.calmAfterTouch && ctx.agitation < GoalTuning.calmThreshold
                    && ctx.handMotion < GoalTuning.stillHand
                // A stir costs some of the wait, not all of it.
                st.held = calm ? st.held + ctx.dt : max(0, st.held - ctx.dt * 2)
                st.done = st.held >= seconds
            }
            states[i] = st
        }
    }
}

/// A seedling standing where a seed rooted, growing over its first seconds.
struct Sprout {
    var position: CGPoint
    var sprite: String
    var bornAt: Float
}

/// Leaves coming down onto the water for a while. Each is a falling petal
/// until it reaches the water; there it is handed to the controller to
/// become a real piece, and the fall stops once enough have landed.
final class LeafFall {
    let total: Int
    private let textures: [String]
    private(set) var spawned = 0
    private(set) var landed = 0
    private var leaves: [(petal: FallingPetal, landAt: CGFloat, scale: CGFloat)] = []
    private var accumulator: Float = 0.8

    struct Landing {
        var at: CGPoint
        var texture: String
        var rotation: Float
        var scale: CGFloat
    }

    init(total: Int, textures: [String]) {
        self.total = total
        self.textures = textures
    }

    /// Every leaf that was going to fall has landed.
    var finished: Bool { landed >= total && leaves.isEmpty }

    /// One step: new leaves while there are more to come, and the ones that
    /// reached the water this frame.
    func update(dt: Float, world: CGSize) -> [Landing] {
        if spawned < total {
            accumulator += dt * 1.1
            while accumulator >= 1, spawned < total {
                accumulator -= 1
                let p = FallingPetal(x: CGFloat.random(in: 0.18...0.82) * world.width, y: -24,
                                     texture: textures[spawned % textures.count])
                // A leaf comes down faster than blossom does.
                p.blow(dx: 0, dy: CGFloat.random(in: 50...90))
                leaves.append((p, CGFloat.random(in: 0.25...0.80) * world.height, CGFloat.random(in: 0.9...1.25)))
                spawned += 1
            }
        }
        var out: [Landing] = []
        for (i, l) in leaves.enumerated().reversed() {
            l.petal.update(dt: dt)
            guard l.petal.y >= l.landAt else { continue }
            out.append(Landing(at: CGPoint(x: l.petal.x, y: l.petal.y), texture: l.petal.texture,
                               rotation: l.petal.rotation, scale: l.scale))
            leaves.remove(at: i)
            landed += 1
        }
        return out
    }

    /// A gust or the wind takes the leaves still in the air.
    func blow(direction: SIMD2<Float>, strength: Float) {
        for l in leaves { l.petal.blow(dx: CGFloat(direction.x * strength), dy: CGFloat(direction.y * strength) * 0.4) }
    }

    func sprites() -> [Sprite] {
        leaves.map { l in
            let side = 26 * l.scale
            return Sprite(l.petal.texture, at: CGPoint(x: l.petal.x, y: l.petal.y), size: CGSize(width: side, height: side),
                          rotation: l.petal.rotation, mode: .plain, alpha: 1, z: 0.5)
        }
    }
}
