import CoreGraphics
import CoreMotion
import Foundation
import simd

/// Everything alive in the pond that is not the puzzle: the flora at the
/// edges and its bloom, the koi, the blossom that falls. It produces sprite
/// lists each frame; the renderer draws them under or over the water.
final class Garden {

    private(set) var art: ArtSet
    private(set) var size = CGSize.zero
    private var koi: [Koi] = []
    private var petals: [FallingPetal] = []
    private var bloomStage: Float = 0
    private var bloomTarget: Float = 0
    private var bloomRate: Float = 0
    private var petalRate: Float = 0
    private var petalUntil: TimeInterval = 0
    private var petalAccumulator: Float = 0
    private var time: TimeInterval = 0

    /// Splats the garden wants made in the water this frame (a diving koi, a
    /// petal landing). Drained by the controller.
    var splashes: [(at: CGPoint, radius: Float, amplitude: Float)] = []
    /// Rocks in the pond, in points, so the koi go round them.
    var rocks: [(centre: CGPoint, radius: CGFloat)] = []

    /// Something the garden did that a hand would hear or feel. Cleared at
    /// the top of every frame, so a controller that ignores them loses
    /// nothing but the sound.
    enum Event {
        case leapOut(CGPoint)
        case leapIn(CGPoint)
        case drip(CGPoint)
        case mouth(CGPoint)
        case dip(CGPoint)
    }
    var events: [Event] = []

    /// Where the camera is, laterally, in points. A slow breath, the phone's
    /// tilt if it has a gyroscope, and a small lean toward the last touch.
    private(set) var camera = SIMD2<Float>(0, 0)
    private var cameraTarget = SIMD2<Float>(0, 0)
    private var leanToward = SIMD2<Float>(0, 0)
    private let motion = CMMotionManager()
    private var tiltRest: SIMD2<Float>?
    private var weeds: [Weed] = []
    /// Water slope under each weed tip, set by the controller from the probes.
    var weedSamples: [Int: FieldSample] = [:]
    private var critters: [Critter] = []
    private var shoals: [Shoal] = []
    /// Koi drawn as bodies rather than cut-outs; the sprite path stays behind
    /// this for comparison.
    var koiAsBodies = true
    /// Which koi got which spine this frame, for the bodies.
    private var koiSpines: [(koi: Koi, spine: Int)] = []
    private var clouds: [Cloud] = []
    private var dragonfly: Dragonfly?
    private var nextFlyerAt: TimeInterval = 0
    private var bedPieces: [BedPiece] = []
    private var reeds: [Reed] = []
    private var frog: Frog?
    private var newt: Critter?
    private var heron: Heron?
    private var nextHeronAt: TimeInterval = 0
    private var motes: [Mote] = []
    /// Water thrown into the air by a big splash, on its way back down.
    private var droplets: [Droplet] = []
    /// Air rising from the bed under a finger that is pressing.
    private var bubbles: [Bubble] = []
    /// Mist lying on the water, and how much of it this pond wants: thick on
    /// a cold morning, next to nothing in high summer.
    private var mists: [Mist] = []
    var mistAmount: Float = 0.5
    /// Seconds since this pond was laid out, for the mist burning off.
    private var levelAge: Float = 0
    /// Where a stream runs in, in points. Nil on a still pond.
    var inlet: CGPoint?
    private var foam: [Foam] = []
    private var foamAccumulator: Float = 0
    /// Drops falling off the branches, and whether any are falling at all.
    var dripping = false
    private var drips: [Drip] = []
    private var nextDripAt: [TimeInterval] = []
    /// A koi out of the water, and when the next one may go up.
    private var leaps: [Leap] = []
    private var nextLeapAt: TimeInterval = 0
    /// The slow trickle of air out of the deep middle.
    private var nextBedBubbleAt: TimeInterval = 0
    /// The bowl depth at a point, 0...1 (1 deep), set by the controller.
    var depthAt: (CGPoint) -> Float = { _ in 1 }
    /// The bed alone, without the rocks and pads standing in it: what says
    /// where the bank is, so nothing is planted on a stone.
    var groundAt: ((CGPoint) -> Float)?
    /// How much of the pond is still under ice, 0...1. The koi stay deep
    /// until the water opens.
    var iceCover: Float = 0
    /// Ice over a given point, 0...1, when the controller can say per cell.
    /// Left nil, every koi reads `iceCover`. A sleeping koi wakes when the
    /// sheet over it, by this reading, drops below a half.
    var iceOverAt: ((CGPoint) -> Float)?
    /// The plot: every fish keeps to the water. On, each koi and shoal fish
    /// reads `depthAt` ahead of itself and turns back from the ground the
    /// way it turns from a rock, a fish that finds itself over earth makes
    /// for the nearest water, and no fish picks a point to swim to that is
    /// not over water. A level's bowl is water everywhere, so it stays off.
    var confineToWater = false

    // MARK: - Life and coax state

    /// The koi answering a held finger, and where the finger is.
    private var called: Koi?
    private var callPoint: CGPoint?
    private var lastCallAt: TimeInterval = -1
    /// After the finger lifts the fish stays up until this, then cruises off.
    private var callHoldUntil: TimeInterval = 0
    /// The one koi that lives under a shape, its home, and whether it has
    /// been tempted all the way out (after which it is an ordinary fish).
    private var shyKoi: Koi?
    private var shyHome: Shape?
    private var shyOut = false
    /// The last time the water over the shy koi's home was churned.
    private var shyDisturbedAt: TimeInterval = -100
    private var shyEdging = false
    /// The held finger this frame as the shy koi sees it: nil when none.
    private var temptPoint: CGPoint?
    /// Every koi lies on the bed under the ice until its sheet opens.
    private var koiAsleep = false
    /// How glassy the pond has lain, 0...1, from the controller.
    private var stillAmount: Float = 0
    /// The moon in the water, eased in and out.
    private var moonAlpha: Float = 0
    private var moonPhase: Float = 0

    init(art: ArtSet) {
        self.art = art
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 60.0
            motion.startDeviceMotionUpdates()
        }
    }

    /// A tap lands: the camera leans toward it a little, and anything close
    /// startles away from it.
    func startle(at point: CGPoint, in size: CGSize) {
        leanToward = SIMD2(Float(point.x - size.width / 2), Float(point.y - size.height / 2)) * 0.05
        for c in critters { c.startle(from: point) }
        for s in shoals { s.startle(from: point) }
        // A slap beside the called fish breaks the spell: it bolts like the rest.
        if let c = called, hypot(c.position.x - point.x, c.position.y - point.y) < 220 {
            c.freeGuide(now: time, in: size)
            called = nil
        }
        for k in koi where !k.resting && !(k === shyKoi && !shyOut) {
            k.startle(from: point, now: time)
        }
        disturb(at: point)
        frog?.startle(from: point, now: time)
        newt?.startle(from: point)
        // The reed tufts nearest the splash are shoved away from it and
        // spring back on their own stems.
        for i in reeds.indices {
            let dx = Float(reeds[i].position.x - point.x), dy = Float(reeds[i].position.y - point.y)
            let dist = hypot(dx, dy)
            guard dist < 260, dist > 0.5 else { continue }
            let side: Float = dx >= 0 ? 1 : -1
            reeds[i].swayVel += side * (1 - dist / 260) * 2.2
        }
    }

    /// Something churned the water here. The shy koi notes it if it was
    /// over its home.
    private func disturb(at point: CGPoint) {
        guard let home = shyHome, shyKoi != nil, !shyOut else { return }
        if hypot(point.x - home.centre.x, point.y - home.centre.y) < home.radius * 1.6 {
            shyDisturbedAt = time
        }
    }

    /// Pixel size of a named texture, for keeping aspect; set by the controller.
    var textureSize: (String) -> CGSize = { _ in CGSize(width: 1, height: 1) }

    // MARK: - Water thrown about

    /// A splash big enough to throw water into the air. Every big splash in
    /// the game comes through here, so drops always fly and land alike.
    /// - Parameters:
    ///   - point: where the water was struck.
    ///   - power: 0 to 1, how big the splash was.
    func burstDroplets(at point: CGPoint, power: Float) {
        guard size.width > 0 else { return }
        let p = min(max(power, 0), 1)
        if p > 0.3 { disturb(at: point) }
        let n = max(3, Int(Float.random(in: 10...16) * (0.4 + 0.6 * p)))
        guard droplets.count + n < 160 else { return }
        for _ in 0..<n {
            let angle = CGFloat.random(in: 0...(2 * .pi))
            let out = CGFloat.random(in: 18...70) * CGFloat(0.5 + 0.5 * p)
            let up = CGFloat.random(in: 60...140) * CGFloat(0.55 + 0.45 * p)
            droplets.append(Droplet(at: point, velocity: CGVector(dx: cos(angle) * out, dy: sin(angle) * out * 0.75),
                                    up: up, size: CGFloat.random(in: 4...7)))
        }
    }

    /// One bubble of air leaves the bed under a pressing finger.
    func addBubble(at point: CGPoint) {
        guard size.width > 0, bubbles.count < 60 else { return }
        let jitter = CGPoint(x: point.x + CGFloat.random(in: -14...14), y: point.y + CGFloat.random(in: -14...14))
        bubbles.append(Bubble(at: jitter, size: CGFloat.random(in: 4...9)))
    }

    /// A gust crosses the pond: whatever is in the air goes with it.
    func blow(direction: SIMD2<Float>, strength: Float) {
        for p in petals { p.blow(dx: CGFloat(direction.x * strength), dy: CGFloat(direction.y * strength)) }
        for d in droplets { d.blow(dx: CGFloat(direction.x * strength * 0.4), dy: CGFloat(direction.y * strength * 0.4)) }
    }

    /// The same gust on what is rooted: the weed strands are shoved the way
    /// it goes and the reed tufts lean after it, both on their own springs,
    /// so they come back upright once it has passed.
    func lean(direction: SIMD2<Float>, strength: Float) {
        for w in weeds {
            let lateral = SIMD2(cos(w.lean), sin(w.lean))
            w.bendVel += simd_dot(direction, lateral) * strength
        }
        for i in reeds.indices {
            reeds[i].swayVel += direction.x * strength * 0.5
        }
    }

    // MARK: - The leap

    /// A koi throws itself clear of the water. The owner does not want it
    /// ("it looks weird"), so no koi leaps on its own or on a splash; the
    /// code is kept for the scripted `leap:` only.
    static let leapsAllowed = false

    func leapNow() {
        guard leaps.isEmpty, size.width > 0 else { return }
        // A fish being led, resting or asleep is not in the mood.
        let ready = koi.filter { !$0.leaping && $0.depth < 0.3 && $0.guide == nil && !$0.resting }
        guard let k = ready.randomElement() else { return }
        let from = k.position
        let reach = CGFloat.random(in: 130...200)
        let head = CGFloat(k.heading)
        var to = CGPoint(x: from.x + cos(head) * reach, y: from.y + sin(head) * reach)
        // A fish that would come down on the bank turns for open water
        // instead: the whole arc has to happen over the pond.
        let inset = CGPoint(x: 130, y: 260)
        if to.x < inset.x || to.x > size.width - inset.x || to.y < inset.y || to.y > size.height - inset.y {
            let dx = size.width / 2 - from.x, dy = size.height / 2 - from.y
            let len = max(1, hypot(dx, dy))
            to = CGPoint(x: from.x + dx / len * reach, y: from.y + dy / len * reach)
        }
        to.x = min(max(to.x, inset.x), max(inset.x, size.width - inset.x))
        to.y = min(max(to.y, inset.y), max(inset.y, size.height - inset.y))
        k.beginLeap()
        leaps.append(Leap(koi: k, texture: Garden.leapPainting(for: k.texture), from: from, to: to,
                          height: CGFloat.random(in: 60...110)))
        splashes.append((from, 18, -0.34))
        burstDroplets(at: from, power: 0.85)
        events.append(.leapOut(from))
    }

    /// A big splash beside a fish that is up at the surface may bring its
    /// leap forward, so a stone dropped in is now and then answered.
    func bigSplash(at point: CGPoint) {
        disturb(at: point)
        let near = koi.contains {
            !$0.leaping && $0.depth < 0.3 && $0.guide == nil && !$0.resting
                && hypot($0.position.x - point.x, $0.position.y - point.y) < 280
        }
        guard near else { return }
        nextLeapAt = min(nextLeapAt, time + Double.random(in: 2...15))
    }

    /// The leaping painting that matches the fish's own: 1 kohaku, 2 sanke,
    /// 3 gold, picked off the last digit of the koi's texture name.
    private static func leapPainting(for koiTexture: String) -> String {
        let digit = koiTexture.last.flatMap { Int(String($0)) } ?? 1
        return "koi_leap_\((max(1, digit) - 1) % 3 + 1)"
    }

    private func updateLeaps(dt: Float, now: TimeInterval) {
        if nextLeapAt == 0 { nextLeapAt = now + Double.random(in: 40...90) }
        if Garden.leapsAllowed, now > nextLeapAt {
            nextLeapAt = now + Double.random(in: 40...90)
            leapNow()
        }
        for l in leaps { l.update(dt: dt) }
        for l in leaps where l.done {
            splashes.append((l.to, 16, -0.30))
            burstDroplets(at: l.to, power: 0.7)
            events.append(.leapIn(l.to))
            l.koi.land(at: l.to, heading: l.heading, now: now, in: size)
        }
        leaps.removeAll { $0.done }
    }

    // MARK: - The stream running in

    /// Where the stream comes in and which way it points into the pond, for
    /// the ripple train and the current the controller lays from it.
    func inletFlow() -> (at: CGPoint, into: CGVector)? {
        guard let inlet, size.width > 0 else { return nil }
        let dx = size.width / 2 - inlet.x, dy = size.height / 2 - inlet.y
        let len = max(1, hypot(dx, dy))
        return (inlet, CGVector(dx: dx / len, dy: dy / len))
    }

    private func updateInlet(dt: Float) {
        guard let flow = inletFlow() else {
            foam.removeAll()
            return
        }
        foamAccumulator += dt * 3
        while foamAccumulator >= 1, foam.count < 9 {
            foamAccumulator -= 1
            let out = CGFloat.random(in: 4...26)
            let p = CGPoint(x: flow.at.x + flow.into.dx * out + CGFloat.random(in: -12...12),
                            y: flow.at.y + flow.into.dy * out + CGFloat.random(in: -12...12))
            foam.append(Foam(at: p, drift: CGVector(dx: flow.into.dx * 16, dy: flow.into.dy * 16),
                             size: CGFloat.random(in: 16...30)))
        }
        foamAccumulator = min(foamAccumulator, 1)
        for f in foam { f.update(dt: dt) }
        foam.removeAll { $0.dead }
    }

    // MARK: - Drips off the branches

    /// Where the two branches hang lowest over the water. What falls off
    /// them falls from here.
    private func branchTips() -> [CGPoint] {
        guard size.width > 0, !art.branch.isEmpty else { return [] }
        let w = size.width
        let side = w * art.branchScale
        let small = side * art.branchRightScale
        return [CGPoint(x: side * 0.60 - art.branchInset, y: side * 0.80 - art.branchInset),
                CGPoint(x: w - small * 0.60 + art.branchInset, y: small * 0.80 + art.branchRightDrop)]
    }

    /// One drop leaves a branch now, whichever branch is nearest to ready.
    func dripNow() {
        let tips = branchTips()
        guard let tip = tips.randomElement(), drips.count < 12 else { return }
        addDrip(from: tip)
    }

    private func addDrip(from tip: CGPoint) {
        let from = CGPoint(x: tip.x + CGFloat.random(in: -26...26), y: tip.y + CGFloat.random(in: -16...16))
        let to = CGPoint(x: from.x + CGFloat.random(in: -6...6), y: from.y + CGFloat.random(in: 100...190))
        drips.append(Drip(from: from, to: to))
    }

    private func updateDrips(dt: Float, now: TimeInterval) {
        let tips = branchTips()
        if nextDripAt.count != tips.count { nextDripAt = tips.map { _ in now + Double.random(in: 1...4) } }
        if dripping {
            for (i, tip) in tips.enumerated() where now > nextDripAt[i] {
                nextDripAt[i] = now + Double.random(in: 2...5)
                if drips.count < 12 { addDrip(from: tip) }
            }
        } else {
            for i in nextDripAt.indices { nextDripAt[i] = max(nextDripAt[i], now + 2) }
        }
        for d in drips {
            d.update(dt: dt)
            if d.landed {
                // Small, but a real ring: a drip off a branch is heard and
                // seen as the circle it leaves, not as the bead that fell.
                splashes.append((d.position, 7, -0.075))
                events.append(.drip(d.position))
            }
        }
        drips.removeAll { $0.landed }
    }

    func configure(art: ArtSet, size: CGSize, bloomStage: Float) {
        self.art = art
        self.size = size
        self.bloomStage = bloomStage
        bloomTarget = bloomStage
        bloomRate = 0
        petals = []
        petalRate = 0
        petalAccumulator = 0
        koi = (0..<min(2, art.koi.count)).map { i in
            Koi(texture: art.koi[i], forward: art.koiForward.isEmpty ? .pi / 2 : art.koiForward[i % art.koiForward.count], seed: i,
                waveAmp: art.koiWaveAmp)
        }
        // Weed clumps rooted in the bed, mostly toward the banks where it is
        // shallow, each a few strands of different heights.
        weeds = []
        if !art.weeds.isEmpty {
            var rng = SystemRandomNumberGenerator()
            let clumps = 8
            for c in 0..<clumps {
                let angle = Float(c) / Float(clumps) * 2 * .pi + Float.random(in: -0.3...0.3, using: &rng)
                let rx = Float(size.width) * Float.random(in: 0.30...0.46, using: &rng)
                let ry = Float(size.height) * Float.random(in: 0.26...0.40, using: &rng)
                let root = CGPoint(x: size.width / 2 + CGFloat(cos(angle) * rx), y: size.height / 2 + CGFloat(sin(angle) * ry))
                for k in 0..<Int.random(in: 1...2, using: &rng) {
                    let name = art.weeds[(c + k) % art.weeds.count]
                    let rootPoint = CGPoint(x: root.x + CGFloat.random(in: -16...16, using: &rng),
                                            y: root.y + CGFloat.random(in: -10...10, using: &rng))
                    weeds.append(Weed(texture: name,
                                      root: rootPoint,
                                      bedDepth: depthAt(rootPoint),
                                      height: CGFloat.random(in: 130...210, using: &rng),
                                      lean: angle + .pi + Float.random(in: -0.7...0.7, using: &rng),
                                      phase: Float.random(in: 0...(2 * .pi), using: &rng),
                                      depth: Float.random(in: 0.2...0.45, using: &rng)))
                }
            }
        }
        critters = art.under.enumerated().map { i, name in
            let forward: Float = name.hasPrefix("tadpole_1") ? -.pi / 2 : (name.hasPrefix("boatman") ? -.pi / 2 : .pi)
            return Critter(texture: name, forward: forward, size: name.hasPrefix("boatman") ? 26 : 22, seed: i, under: true)
        } + art.skaters.enumerated().map { i, name in
            Critter(texture: name, forward: -.pi / 2, size: 30, seed: i + 10, under: false)
        }
        clouds = art.clouds.enumerated().map { i, name in
            Cloud(texture: name, seed: i, size: size)
        }
        dragonfly = nil
        nextFlyerAt = time + 6
        nextHeronAt = time + Double.random(in: 25...45)
        heron = nil
        motes = (0..<70).map { _ in Mote(size: size) }
        // A fresh pond: the mist is at its thickest, nothing is in the air,
        // and the first leap is a long way off.
        mists = (0..<Int.random(in: 4...6)).map { i in
            Mist(texture: i % 2 == 0 ? "mist_1" : "mist_2", size: size)
        }
        levelAge = 0
        leaps = []
        drips = []
        foam = []
        nextDripAt = []
        nextLeapAt = time + Double.random(in: 40...90)
        nextBedBubbleAt = time + 2
        buildBed()
        buildShore()
        frog = art.frog.map { Frog(texture: $0.frog, pad: $0.pad, size: size) }
        newt = art.newt.map { Critter(texture: $0, forward: -.pi / 2, size: 34, seed: 3, under: true, slow: true) }
        shoals = art.shoal.enumerated().map { i, name in
            Shoal(texture: name, count: 10 + i * 4, size: size, seed: i)
        }
        // A fresh pond: nobody is called, nobody is shy, nobody is asleep,
        // and the moon is not in the water.
        called = nil
        callPoint = nil
        callHoldUntil = 0
        shyKoi = nil
        shyHome = nil
        shyOut = false
        shyEdging = false
        temptPoint = nil
        koiAsleep = false
        stillAmount = 0
        moonAlpha = 0
    }

    /// The bed is not a painting: it is stones and gravel lying at their own
    /// depths, big ones on the shelves near the banks, smaller and fewer out
    /// in the deep middle, each lit and shadowed like everything else.
    private func buildBed() {
        bedPieces = []
        guard !art.stones.isEmpty else { return }
        var rng = SystemRandomNumberGenerator()
        let w = size.width, h = size.height
        func drop(_ name: String, sizePt: CGFloat, count: Int, rimBias: Float) {
            for _ in 0..<count {
                var p = CGPoint.zero
                for _ in 0..<8 {
                    p = CGPoint(x: CGFloat.random(in: 10...max(10, w - 10), using: &rng), y: CGFloat.random(in: 60...max(60, h - 40), using: &rng))
                    let d = depthAt(p)
                    // rimBias 1 wants the shelves, 0 does not care.
                    if Float.random(in: 0...1, using: &rng) > d * rimBias { break }
                }
                let d = depthAt(p)
                bedPieces.append(BedPiece(texture: name, position: p,
                                          size: sizePt * CGFloat.random(in: 0.7...1.3, using: &rng),
                                          rotation: Float.random(in: 0...(2 * .pi), using: &rng),
                                          z: -(0.6 + 0.4 * d), depth: d))
            }
        }
        for name in art.sand { drop(name, sizePt: 96, count: 1, rimBias: 0.9) }
        // Gravel sparingly: a clutch of pebbles with an ink edge round it
        // reads as a bunch of grapes when there is one every few steps.
        for (i, name) in art.gravel.enumerated() where i % 2 == 0 { drop(name, sizePt: 62, count: 1, rimBias: 0.7) }
        for (i, name) in art.stones.enumerated() {
            drop(name, sizePt: i < 3 ? 78 : 46, count: i < 3 ? 2 : 3, rimBias: 0.85)
        }
        // Draw order: deep and large first, so nearer things overlap.
        bedPieces.sort { $0.z < $1.z }
    }

    /// Reed tufts stand in the shallows at the banks, breaking the surface.
    private func buildShore() {
        reeds = []
        let plants = art.reeds + art.flowers
        guard !plants.isEmpty, size.width > 0 else { return }
        var rng = SystemRandomNumberGenerator()
        let w = size.width, h = size.height
        let c = CGPoint(x: w / 2, y: h / 2)
        // Walk round the pond and plant the dry band just past the
        // waterline: reeds and the season's flowers in clumps, more where
        // the ground is wide, none where the bank is a sliver.
        let steps = 52
        for i in 0..<steps {
            let a = CGFloat(i) / CGFloat(steps) * 2 * .pi + CGFloat.random(in: -0.04...0.04, using: &rng)
            let dir = CGVector(dx: cos(a), dy: sin(a))
            // From the centre out to where the ground comes up dry.
            var r: CGFloat = min(w, h) * 0.3
            var shore: CGPoint?
            while r < max(w, h) {
                let q = CGPoint(x: c.x + dir.dx * r, y: c.y + dir.dy * r)
                if q.x < 6 || q.y < 6 || q.x > w - 6 || q.y > h - 6 { break }
                if (groundAt ?? depthAt)(q) < 0.10 { shore = q; break }
                r += 5
            }
            guard let edge = shore else { continue }
            guard CGFloat.random(in: 0...1, using: &rng) < 0.7 else { continue }
            let count = Int.random(in: 1...2, using: &rng)
            for _ in 0..<count {
                let out = CGFloat.random(in: 10...44, using: &rng)
                let along = CGFloat.random(in: -24...24, using: &rng)
                let p = CGPoint(x: edge.x + dir.dx * out - dir.dy * along, y: edge.y + dir.dy * out + dir.dx * along)
                guard p.x > 8, p.y > 8, p.x < w - 8, p.y < h - 8 else { continue }
                let flower = !art.flowers.isEmpty && CGFloat.random(in: 0...1, using: &rng) < 0.42
                let name = flower ? art.flowers.randomElement(using: &rng)! : art.reeds.randomElement(using: &rng) ?? plants[0]
                reeds.append(Reed(texture: name, position: p,
                                  size: name.hasPrefix("moss") ? CGFloat.random(in: 16...26, using: &rng)
                                      : flower ? CGFloat.random(in: 34...58, using: &rng) : CGFloat.random(in: 56...96, using: &rng),
                                  rotation: Float.random(in: -0.3...0.3, using: &rng) - .pi / 2,
                                  phase: Float.random(in: 0...(2 * .pi), using: &rng)))
            }
        }
        // Nearer tufts draw last so they overlap the farther ones.
        reeds.sort { $0.position.y < $1.position.y }
    }

    func resize(_ newSize: CGSize) {
        size = newSize
    }

    // MARK: - Bloom

    func bloom(to stage: Float, duration: Float) {
        bloomTarget = max(0, min(3, stage))
        guard bloomTarget > bloomStage + 0.01 else { return }
        bloomRate = (bloomTarget - bloomStage) / max(0.1, duration)
        // Blossom falls in proportion to how far the garden just came on.
        petalRate = 2 + 3 * (bloomTarget - bloomStage)
        petalUntil = time + TimeInterval(duration) + 7
    }

    // MARK: - Koi

    func koiHit(at point: CGPoint) -> Koi? {
        koi.first { !$0.leaping && $0.depth < 0.5 && hypot($0.position.x - point.x, $0.position.y - point.y) < 46 }
    }

    func dive(_ k: Koi) {
        if k === called { called = nil }
        k.dive(now: time, quick: true)
        splashes.append((k.position, 16, -0.32))
    }

    // MARK: - Fish let go (the plot)

    /// A koi released into the pond at a point: the same fish a level has,
    /// spine, guide and all, so it bends and answers a finger like any
    /// other. `size` scales its body, 1 being as it was won. The plot keeps
    /// the fish it gets back so it can grow it and take it out again.
    @discardableResult
    func addKoi(texture: String, at point: CGPoint, size: CGFloat = 1) -> Koi {
        let forward = art.koiForward.first ?? .pi / 2
        let k = Koi(texture: texture, forward: forward, seed: koi.count, waveAmp: art.koiWaveAmp > 0 ? art.koiWaveAmp : 0.075)
        k.bodyScale = size
        k.waterAt = confineToWater ? depthAt : nil
        k.release(at: point, in: self.size, now: time)
        koi.append(k)
        return k
    }

    /// The fish is taken out of the water. Nothing goes on pointing at it.
    func removeKoi(_ k: Koi) {
        if k === called { called = nil }
        if k === shyKoi { shyKoi = nil }
        leaps.removeAll { $0.koi === k }
        koi.removeAll { $0 === k }
    }

    /// A shoal let go at a point, `count` small fish schooling from there.
    @discardableResult
    func addShoal(texture: String, at point: CGPoint, count: Int) -> Shoal {
        let s = Shoal(texture: texture, count: count, size: self.size, seed: shoals.count, centre: point)
        shoals.append(s)
        return s
    }

    func removeShoal(_ s: Shoal) {
        shoals.removeAll { $0 === s }
    }

    /// Every koi in the water right now.
    var allKoi: [Koi] { koi }

    // MARK: - Life and coax (the LifeCoax contract)

    /// A koi that can answer a hand right now: not in the air, not lying
    /// still, and not the shy one while it is still shy.
    private func answers(_ k: Koi) -> Bool {
        !k.leaping && !k.resting && !(k === shyKoi && !shyOut)
    }

    /// A charged hold. The nearest free koi within reach is drawn up and
    /// comes under the finger; once one has answered it stays the one, so
    /// the hand can lead it about. The shy koi reads the same finger.
    /// `stop` is how close the mouth comes before it hovers: a finger is
    /// nosed at from a little way off, a pellet is taken.
    func callKoi(at point: CGPoint, charge: Float, dt: Float, stop: CGFloat = 22) {
        guard size.width > 0 else { return }
        lastCallAt = time
        callPoint = point
        callHoldUntil = 0
        temptPoint = charge > 0.1 ? point : nil
        if called == nil, charge > 0.15 {
            var best: Koi?
            var bestDist = GoalTuning.callReach
            for k in koi where answers(k) {
                let d = hypot(k.position.x - point.x, k.position.y - point.y)
                if d < bestDist { bestDist = d; best = k }
            }
            called = best
        }
        guard let c = called else { return }
        // Up, and the mouth to the finger. Slow near it: a hover, not a bump.
        c.lead(Koi.Guide(point: point, speed: 30, depth: 0.05, stop: stop, byHead: true))
    }

    /// The finger lifted. The called fish stays up three seconds, mouthing
    /// where the finger was, then remembers it has somewhere to be.
    func releaseCall() {
        temptPoint = nil
        callPoint = nil
        guard called != nil else { return }
        callHoldUntil = time + 3
    }

    var calledKoi: CGPoint? {
        guard let c = called, !c.leaping, c.depth < 0.25 else { return nil }
        return c.headPoint
    }

    func surfacedKoi() -> [CGPoint] {
        koi.filter { !$0.leaping && $0.depth < 0.25 }.map(\.position)
    }

    func shoalCentroids() -> [CGPoint] {
        shoals.compactMap { $0.centroid }
    }

    /// A fast stroke laid a wake. The shoal nearest its start takes it up:
    /// its wander point becomes the far end for five seconds and the fish
    /// nearest the start leads the rest along the line.
    /// The shoal keeps to the water below this line (larger y) until it is
    /// led out through the gate; nil frees it. Set after `configure`.
    func penShoals(below y: CGFloat?) {
        for s in shoals { s.pen(below: y, in: size) }
    }

    func followWake(path: [CGPoint]) {
        guard let start = path.first, path.count >= 2 else { return }
        let taker = shoals.min { a, b in
            let pa = a.centroid ?? start, pb = b.centroid ?? start
            return hypot(pa.x - start.x, pa.y - start.y) < hypot(pb.x - start.x, pb.y - start.y)
        }
        taker?.follow(path: path, now: time)
    }

    /// One koi goes to live under the shape: it lies there, hidden by the
    /// pads or the log drawn over it, until a still pond and a patient
    /// finger tempt it out. Nil makes every fish ordinary again.
    func setShyHome(_ home: Shape?) {
        shyHome = home
        shyOut = false
        shyEdging = false
        shyDisturbedAt = time
        guard let home, let k = koi.first else {
            if let k = shyKoi, k.resting { k.stir(depth: 0.3, rate: 0.5, now: time, in: size) }
            shyKoi = nil
            return
        }
        if k === called { called = nil }
        shyKoi = k
        let angle = Float.random(in: 0...(2 * .pi))
        let inside = CGPoint(x: home.centre.x + CGFloat(cos(angle)) * home.radius * 0.3,
                             y: home.centre.y + CGFloat(sin(angle)) * home.radius * 0.3)
        k.rest(at: inside, depth: 0.6, heading: angle + .pi, in: size)
    }

    var shyKoiOut: Bool { shyOut }

    /// Under ice the koi lie on the bed. Each wakes as the sheet over it
    /// opens (see the koi loop in `update`); clearing the flag wakes them all.
    func sleepKoiUnderIce(_ asleep: Bool) {
        guard asleep != koiAsleep else { return }
        koiAsleep = asleep
        if asleep {
            called = nil
            for k in koi where !k.leaping {
                k.rest(at: nil, depth: 0.95, heading: nil, in: size)
            }
        } else {
            for k in koi where k.resting && !(k === shyKoi && !shyOut) {
                k.stir(depth: 0.15, rate: 0.25, now: time, in: size)
            }
        }
    }

    /// A single tap. On a calm pond the fish far off turn toward the ring's
    /// source, stopping short of it; the near ones are startled by the
    /// controller as before.
    func curious(tap point: CGPoint, calm: Bool) {
        guard calm else { return }
        for k in koi where answers(k) && k !== called && k.guide == nil {
            let dx = k.position.x - point.x, dy = k.position.y - point.y
            let d = hypot(dx, dy)
            guard d > 200 else { continue }
            k.drawToward(point, stoppingShort: 90, now: time)
        }
    }

    /// How long the pond has lain glassy, as 0...1. The moon eases into the
    /// water and the dragonfly, if one is about, lands on a reed.
    func stillness(_ amount: Float) {
        stillAmount = max(0, min(1, amount))
    }

    /// The moon seen in the water: a wide soft disc riding the surface like
    /// a petal, there only when the pond is still. Empty without `moon.png`.
    func moonSprites() -> [Sprite] {
        guard moonAlpha > 0.01, size.width > 0 else { return [] }
        let t = textureSize("moon")
        guard t.width > 1 || t.height > 1 else { return [] }
        let side: CGFloat = 170
        let at = CGPoint(x: size.width * 0.5 + CGFloat(sin(moonPhase)) * 3,
                         y: size.height * 0.36 + CGFloat(cos(moonPhase * 0.8)) * 2)
        return [Sprite("moon", at: at, size: CGSize(width: side, height: side * t.height / max(1, t.width)),
                       mode: .floater, alpha: moonAlpha, tint: [1.0, 0.98, 0.92, 1], z: 0.01)]
    }

    /// The tip of the reed tuft nearest a point: where a dragonfly can land.
    /// The tuft stands on the surface plane at its root and rises its full
    /// drawn height, so the tip is that height over the root.
    private func reedTip(nearest point: CGPoint) -> (point: CGPoint, height: CGFloat)? {
        guard let r = reeds.min(by: {
            hypot($0.position.x - point.x, $0.position.y - point.y) < hypot($1.position.x - point.x, $1.position.y - point.y)
        }) else { return nil }
        let height = r.size * 1.6
        return (CGPoint(x: r.position.x + CGFloat(sin(r.sway)) * height * 0.15, y: r.position.y), height * 0.92)
    }

    /// The per-frame side of the coax: the called fish after the finger
    /// lifts, and the shy koi's small courage.
    private func updateCoax(dt: Float, now: TimeInterval) {
        // A finger the controller stopped reporting counts as lifted.
        if callPoint != nil, now - lastCallAt > 0.25 { releaseCall() }
        if let c = called {
            if c.leaping || c.resting {
                called = nil
            } else if callHoldUntil > 0, now > callHoldUntil {
                c.freeGuide(now: now, in: size)
                called = nil
                callHoldUntil = 0
            }
        }

        // The shy koi. Still in its home, it waits for the water over the
        // home to have been quiet three seconds and a finger held a little
        // way off; then it edges out toward the hand at half a cruise. Any
        // churn over the home sends it back in. Once it is clear of the
        // home it is out for good and swims like the others.
        guard let k = shyKoi, let home = shyHome, !shyOut, !k.leaping else { return }
        let fromHome = hypot(k.position.x - home.centre.x, k.position.y - home.centre.y)
        if fromHome > home.radius + 40 {
            shyOut = true
            shyEdging = false
            k.freeGuide(now: now, in: size)
            return
        }
        let quiet = now - shyDisturbedAt > 3
        var tempted: CGPoint?
        if let f = temptPoint {
            let d = hypot(f.x - home.centre.x, f.y - home.centre.y)
            if d >= 150, d <= 300 { tempted = f }
        }
        if !quiet, shyEdging || !k.resting {
            // Churned: straight back under, and lie still there.
            shyEdging = false
            if fromHome < 12 {
                k.rest(at: nil, depth: 0.6, heading: nil, in: size)
            } else {
                k.lead(Koi.Guide(point: home.centre, speed: 60, depth: 0.6, stop: 10, byHead: false))
            }
            return
        }
        if let f = tempted, quiet {
            if !shyEdging {
                shyEdging = true
                if k.resting { k.stir(depth: 0.32, rate: 0.6, now: now, in: size) }
            }
            k.lead(Koi.Guide(point: f, speed: 14, depth: 0.32, stop: 30, byHead: true))
            return
        }
        if !k.resting {
            // The hand went away: it drifts back to its shelter at a dawdle
            // and lies down again once it is under.
            shyEdging = false
            if fromHome < 14 {
                k.rest(at: nil, depth: 0.6, heading: nil, in: size)
            } else {
                k.lead(Koi.Guide(point: home.centre, speed: 12, depth: 0.5, stop: 10, byHead: false))
            }
        }
    }

    // MARK: - Per frame

    func update(dt: Float, now: TimeInterval) {
        time = now
        events.removeAll(keepingCapacity: true)
        guard size.width > 0 else { return }
        levelAge += dt

        // The camera: a slow breath, plus the phone's tilt, plus a lean toward
        // the last touch that eases off. Everything is smoothed so it flows.
        let t = Float(now)
        var target = SIMD2(sin(t * 0.11) * 4.0, cos(t * 0.083) * 3.0)
        if let g = motion.deviceMotion?.gravity {
            let tilt = SIMD2(Float(g.x), Float(-g.y))
            if tiltRest == nil { tiltRest = tilt }
            target += (tilt - (tiltRest ?? tilt)) * 90.0
        }
        target += leanToward
        leanToward *= exp(-dt * 1.2)
        cameraTarget = target
        camera += (cameraTarget - camera) * min(1, dt * 2.5)

        // Weeds: each strand is a spring. The water's slope at its tip pushes
        // it over, the stem pulls it back, and damping keeps it from twanging.
        for (i, w) in weeds.enumerated() {
            let sample = weedSamples[i]
            let lateral = SIMD2(cos(w.lean), sin(w.lean))
            let push = sample.map { simd_dot($0.slope, lateral) } ?? 0
            let force = push * 380.0 - w.bend * 3.2 - w.bendVel * 1.6
            w.bendVel += force * dt
            w.bend += w.bendVel * dt
            w.bend = max(-0.9, min(0.9, w.bend))
        }
        // Reeds lean the same way: a spring that a gust shoves and the stem
        // pulls straight again.
        for i in reeds.indices {
            let force = -reeds[i].sway * 24 - reeds[i].swayVel * 4.5
            reeds[i].swayVel += force * dt
            reeds[i].sway += reeds[i].swayVel * dt
            reeds[i].sway = max(-0.45, min(0.45, reeds[i].sway))
        }

        for m in mists { m.update(dt: dt, in: size) }
        updateInlet(dt: dt)
        updateDrips(dt: dt, now: now)
        updateLeaps(dt: dt, now: now)

        for c in critters { c.update(dt: dt, now: now, in: size) }
        let water: ((CGPoint) -> Float)? = confineToWater ? depthAt : nil
        for s in shoals { s.update(dt: dt, now: now, in: size, rocks: rocks, koi: koi.map(\.position), water: water) }
        for c in clouds { c.update(dt: dt, in: size) }
        if let f = dragonfly {
            // A still pond: it settles on a reed tip and folds its wings;
            // the first stir of the water and it is off again.
            if stillAmount > 0.6, f.perch == nil, let tip = reedTip(nearest: f.position) {
                f.land(on: tip.point, height: tip.height)
            } else if stillAmount < 0.5, f.perch != nil {
                f.takeOff(in: size)
            }
            f.update(dt: dt, now: now, in: size)
            // It touches the water once before it darts off: a bead of a
            // splat under it and the ring that spreads from it.
            if let p = f.dip {
                f.dip = nil
                splashes.append((p, 4, -0.05))
                splashes.append((p, 11, -0.02))
                events.append(.dip(p))
            }
            if f.done { dragonfly = nil; nextFlyerAt = now + Double.random(in: 25...50) }
        } else if now > nextFlyerAt, let name = art.flyers.first {
            dragonfly = Dragonfly(body: name, size: size, now: now)
        } else if stillAmount > 0.6, !reeds.isEmpty {
            // A glassy pond brings one over sooner, to land.
            nextFlyerAt = min(nextFlyerAt, now + 2)
        }
        // The moon comes and goes on its own ease: touched water loses it
        // over a second and a half, no harder than that.
        moonAlpha += (0.55 * stillAmount - moonAlpha) * min(1, dt * 1.5)
        moonPhase += dt * 0.3
        for m in motes { m.update(dt: dt, in: size) }
        frog?.update(dt: dt, now: now)
        if let f = frog, f.justJumped {
            splashes.append((f.position, 14, -0.30))
            burstDroplets(at: f.position, power: 0.5)
            f.justJumped = false
        }

        // Drops in the air fall back and each one lands as its own small ring.
        for d in droplets {
            d.update(dt: dt)
            if d.landed { splashes.append((d.position, Float.random(in: 2.5...4.5), Float.random(in: -0.05 ... -0.025))) }
        }
        droplets.removeAll { $0.landed }
        // Bubbles rise through the water and pop when they reach the surface.
        for b in bubbles {
            b.update(dt: dt)
            if b.popped { splashes.append((b.position, Float(b.size) * 0.6, -0.02)) }
        }
        bubbles.removeAll { $0.popped }
        newt?.update(dt: dt, now: now, in: size)
        // (The heron's shadow was cut: a flat silhouette sliding over the pond
        // read as a decal, not a bird. It will come back only with wings that beat.)
        // A surfaced koi mouths at the surface now and then: a small ring.
        // The one under a finger mouths at it over and over.
        for k in koi where !k.leaping && k.depth < 0.2 && Float.random(in: 0...1) < dt * (k === called ? 0.9 : 0.18) {
            splashes.append((k.headPoint, 7, -0.09))
            events.append(.mouth(k.headPoint))
        }
        // Air out of the bed. A fish going down stirs the mud it lay on, and
        // the deep middle lets a bubble go on its own every couple of seconds.
        for k in koi where k.justDived {
            k.justDived = false
            for _ in 0..<3 { addBubble(at: k.position) }
        }
        if now > nextBedBubbleAt {
            nextBedBubbleAt = now + Double.random(in: 1.4...2.6)
            let p = CGPoint(x: size.width * CGFloat.random(in: 0.32...0.68),
                            y: size.height * CGFloat.random(in: 0.34...0.66))
            if depthAt(p) > 0.75 { addBubble(at: p) }
        }

        if bloomRate > 0 {
            bloomStage = min(bloomTarget, bloomStage + bloomRate * dt)
            if bloomStage >= bloomTarget { bloomRate = 0 }
        }

        updateCoax(dt: dt, now: now)
        for k in koi where !k.leaping {
            k.iceOver = iceOverAt?(k.position) ?? iceCover
            k.waterAt = water
            // A sleeper wakes the moment the sheet over it opens: it lifts
            // off the bed over a few seconds and swims.
            if koiAsleep, k.resting, k.iceOver < 0.5 {
                k.stir(depth: 0.15, rate: 0.25, now: now, in: size)
            }
            let event = k.update(dt: dt, now: now, in: size, rocks: rocks)
            if let e = event { splashes.append(e) }
        }
        // Snow, or whatever the season lets fall, drifting down all the time.
        if let flake = art.ambientFall {
            petalAccumulator += 1.2 * dt
            while petalAccumulator >= 1, petals.count < 90 {
                petalAccumulator -= 1
                let p = FallingPetal(x: CGFloat.random(in: 0...size.width), y: -20, texture: flake)
                p.scale *= 0.55
                petals.append(p)
            }
            // At the cap the accumulator would climb all level and then dump
            // the backlog the moment a flake dies.
            petalAccumulator = min(petalAccumulator, 1)
        }

        if petalRate > 0 {
            if now > petalUntil { petalRate = 0 }
            petalAccumulator += petalRate * dt
            while petalAccumulator >= 1, petals.count < 80 {
                petalAccumulator -= 1
                petals.append(FallingPetal(x: CGFloat.random(in: 0...size.width),
                                           y: -20, texture: art.petalParticle))
            }
            petalAccumulator = min(petalAccumulator, 1)
        }
        for p in petals {
            p.update(dt: dt)
            if !p.landed, p.y > size.height * CGFloat.random(in: 0.35...0.9) {
                p.land()
                splashes.append((CGPoint(x: p.x, y: p.y), 7, -0.10))
            }
        }
        petals.removeAll { $0.dead }
    }

    // MARK: - Sprites

    /// Under the surface, bottom up: cloud shadows on the bed, weeds, tadpoles,
    /// then koi and their shadows. Each fish carries a spine laid along the
    /// path its head swam; the mesh rows sit on it.
    func submergedSprites() -> (sprites: [Sprite], spines: [SIMD4<Float>]) {
        var out: [Sprite] = []
        var spines: [SIMD4<Float>] = []
        for piece in bedPieces {
            let t = textureSize(piece.texture)
            let long = max(t.width, t.height)
            let sz = CGSize(width: piece.size * t.width / long, height: piece.size * t.height / long)
            // Its shadow lies on the bed a little downhill of the light.
            out.append(Sprite(piece.texture, at: CGPoint(x: piece.position.x + 4, y: piece.position.y + 6), size: sz,
                              rotation: piece.rotation, mode: .shadow, alpha: 0.5, z: -1.0))
            // Stones are bodies now; only the flat scatter stays a cut-out.
            if piece.texture.hasPrefix("stone") { continue }
            let pale = piece.texture.hasPrefix("sand") || piece.texture.hasPrefix("gravel")
            let gravel = piece.texture.hasPrefix("gravel")
            // Sand and gravel sink into the bed's own tone; gravel further,
            // so its outline does not print.
            out.append(Sprite(piece.texture, at: piece.position, size: sz, rotation: piece.rotation,
                              mode: .submerged, alpha: gravel ? 0.7 : (pale ? 0.85 : 1), depth: 0.3 + piece.depth * 0.5,
                              tint: gravel ? [0.52, 0.56, 0.52, 1] : (pale ? [0.62, 0.66, 0.62, 1] : [1, 1, 1, 1]), z: piece.z))
        }
        for c in clouds {
            out.append(Sprite(c.texture, at: CGPoint(x: c.position.x + 30, y: c.position.y + 90),
                              size: CGSize(width: c.width * 1.05, height: c.width * 1.05 * c.aspect),
                              mode: .shadow, alpha: 0.2, z: -1.0))
        }
        // Motes: specks of drifting matter at every depth, each catching a
        // little light. Nothing says "volume" like things floating in it.
        for m in motes {
            out.append(Sprite("mote", at: m.position, size: CGSize(width: m.size, height: m.size),
                              mode: .submerged, alpha: m.alpha, depth: -m.z * 0.7, z: m.z))
        }
        // Air on its way up: paler and a little bigger the nearer the surface.
        for b in bubbles {
            let rise = 1 - b.depth
            let side = b.size * CGFloat(1.6 + 1.0 * rise)
            // Air is the one thing down there that carries its own light, so
            // it is handed a shallower depth than it has and the water hazes
            // it far less than it would a stone.
            out.append(Sprite("bubble", at: b.position, size: CGSize(width: side, height: side),
                              mode: .submerged, alpha: 0.5 + 0.45 * rise, depth: b.depth * 0.5,
                              tint: [1.2, 1.3, 1.4, 1], z: -0.9 + 0.8 * rise))
        }

        if let n = newt {
            out.append(Sprite(n.texture, at: n.position, size: n.spriteSize(textureSize), rotation: n.rotation,
                              mode: .submerged, alpha: 1, depth: 0.7, wave: Float(time) * 5, waveAmp: n.moving ? 0.12 : 0.02, z: -0.95))
        }
        for w in weeds {
            let tw = textureSize(w.texture)
            let width = w.height * tw.width / max(1, tw.height)
            // Its shadow on the bed, then the clump standing on its root; the
            // shader raises it toward the surface.
            out.append(Sprite(w.texture, at: CGPoint(x: w.root.x + 8, y: w.root.y + 10),
                              size: CGSize(width: width, height: w.height * 0.5), rotation: 0,
                              mode: .shadow, alpha: 0.35, z: -1.0))
            out.append(Sprite(w.texture, at: w.root, size: CGSize(width: width, height: w.height),
                              rotation: w.lean, mode: .submerged, alpha: 1, depth: w.bedDepth,
                              wave: w.phase + Float(time) * 0.7, waveAmp: w.bend, weed: true))
        }
        for c in critters where c.under {
            out.append(Sprite(c.texture, at: c.position, size: c.spriteSize(textureSize), rotation: c.rotation,
                              mode: .submerged, alpha: 1, depth: 0.5, z: -0.55))
        }
        for shoal in shoals {
            let t = textureSize(shoal.texture)
            for f in shoal.fish {
                let h = f.length, w = h * t.width / max(1, t.height)
                out.append(Sprite(shoal.texture, at: CGPoint(x: f.position.x + 6, y: f.position.y + 12),
                                  size: CGSize(width: w, height: h), rotation: f.heading - .pi / 2, mode: .shadow,
                                  alpha: 0.35, wave: f.phase, waveAmp: 0.14, z: -1.0))
                out.append(Sprite(shoal.texture, at: f.position, size: CGSize(width: w, height: h),
                                  rotation: f.heading - .pi / 2, mode: .submerged, alpha: 1, depth: shoal.depth,
                                  wave: f.phase, waveAmp: 0.14, z: -0.2 - 0.7 * shoal.depth))
            }
        }
        koiSpines = []
        for k in koi where k.depth < 0.98 && !k.leaping {
            let d = k.depth
            let w = k.width
            let h = w * k.aspect
            let index = spines.count / 13
            // The spine buffer holds so many fish; one past it goes undrawn
            // rather than wearing another fish's spine.
            guard index < Tuning.maxSpines else { continue }
            spines += k.spine(length: h)
            let offset = CGFloat(10 + 26 * d)
            let z = -0.2 - 0.7 * d
            out.append(Sprite(k.texture, at: CGPoint(x: offset * 0.6, y: offset),
                              size: CGSize(width: w, height: h), mode: .shadow,
                              alpha: 0.7 * (1 - d * 0.6), wave: k.phase, waveAmp: k.waveAmp, spine: index, z: -1.0))
            if koiAsBodies {
                koiSpines.append((k, index))
                continue
            }
            out.append(Sprite(k.texture, at: .zero, size: CGSize(width: w, height: h),
                              mode: .submerged, alpha: 1, depth: d,
                              wave: k.phase, waveAmp: k.waveAmp, tint: [1, 1, 1, k.roll], spine: index, z: z))
        }
        return (out, spines)
    }

    /// The koi as bodies: a spindle bent along the spine laid out this frame,
    /// wearing the fish's own painting. `depthScale` is points per pond unit.
    /// Fish under the surface go into the floor; a surfaced one (depth under
    /// 0.1) rides with its back just clear of the water.
    func koiBodies(depthScale: Float, textureIndex: (String) -> UInt32,
                   tailCentre: (String) -> Float) -> (under: [SolidInstance], surface: [SolidInstance]) {
        var under: [SolidInstance] = []
        var surface: [SolidInstance] = []
        for (k, spine) in koiSpines {
            let d = k.depth
            let h = Float(k.width * k.aspect)
            // `radius` is the body's full width: the mesh's profile peaks at
            // half of it. The painted body is only about a third of its
            // painting wide, the rest being the spread fins, so a body given
            // that width comes out a needle. Half the painting's width reads
            // as the fish the shadow underneath it is.
            let radius = Float(k.width) * 0.52
            let lift: Float = d < 0.1 ? radius * 0.15 : -(0.2 + 0.7 * d) * depthScale
            let body = SolidInstance(position: SIMD2(Float(k.position.x), Float(k.position.y)), lift: lift,
                                     yaw: k.phase, roll: k.roll, texture: textureIndex(k.texture),
                                     tilt: SIMD2(k.waveAmp * 0.42, 0), length: h, radius: radius, shape: 5,
                                     alpha: 1, colourA: [0.9, 0.86, 0.78, 1], colourB: [0.9, 0.86, 0.78, 1],
                                     spine: Int32(spine), paintCentre: tailCentre(k.texture))
            if d < 0.1 { surface.append(body) } else { under.append(body) }
        }
        return (under, surface)
    }

    /// The bed's stones as bodies lying on the bed at their depths.
    func bedStoneBodies(depthScale: Float, mossy: Bool) -> [SolidInstance] {
        var out: [SolidInstance] = []
        for piece in bedPieces where piece.texture.hasPrefix("stone") {
            let r = Float(piece.size) * 0.42
            out.append(SolidInstance(position: SIMD2(Float(piece.position.x), Float(piece.position.y)),
                                     lift: -Float(piece.depth) * depthScale + r * 0.3,
                                     yaw: piece.rotation, roll: Float(piece.position.x * 0.19 + piece.position.y * 0.07),
                                     tilt: .zero, length: r * 1.4, radius: r, shape: 2, alpha: 1,
                                     colourA: [0.5, 0.5, 0.48, 1], colourB: mossy ? [0.34, 0.48, 0.3, 1] : [0.5, 0.5, 0.48, 1]))
        }
        return out
    }

    /// Where each strand's tip is on the surface plane, for the water probes.
    func weedTips() -> [CGPoint] {
        weeds.map { w in
            CGPoint(x: w.root.x + CGFloat(cos(w.lean) * w.bend) * w.height * 0.8,
                    y: w.root.y + CGFloat(sin(w.lean) * w.bend) * w.height * 0.8)
        }
    }

    /// The branches seen again in the water: a faint mirror image below the
    /// surface, hazed, where the camera's line of sight to the mirror point falls.
    func reflectionSprites() -> [Sprite] {
        floraSprites().compactMap { s in
            guard s.gpu.pad.y > 0.5 else { return nil }
            var r = s
            r.gpu.pad.y = -s.gpu.pad.y
            r.gpu.mode = SpriteInstance.Mode.submerged.rawValue | (s.gpu.mode & SpriteInstance.flipX)
            r.gpu.alpha = s.gpu.alpha * 0.32
            r.gpu.depth = 0.55
            return r
        }
    }

    /// On the surface: pond skaters, the frog on its pad, reed tufts at the banks.
    func skaterSprites() -> [Sprite] {
        var out = critters.filter { !$0.under }.map { c in
            Sprite(c.texture, at: c.position, size: c.spriteSize(textureSize), rotation: c.rotation,
                   mode: .floater, alpha: 0.95, z: 0)
        }
        if let f = frog {
            let padT = textureSize(f.pad)
            let padW: CGFloat = 64
            out.append(Sprite(f.pad, at: f.padPosition, size: CGSize(width: padW, height: padW * padT.height / max(1, padT.width)),
                              rotation: f.padRotation, mode: .floater, alpha: 1, z: 0))
            if f.onPad {
                let t = textureSize(f.texture)
                let fw: CGFloat = 30
                out.append(Sprite(f.texture, at: f.position, size: CGSize(width: fw, height: fw * t.height / max(1, t.width)),
                                  rotation: f.rotation, alpha: 1, z: 0.08))
            }
        }
        for r in reeds {
            let t = textureSize(r.texture)
            let height = r.size * 1.6
            let width = height * t.width / max(1, t.height)
            let sz = CGSize(width: width, height: height)
            // The shadow: the same tuft laid flat on the water, toward the light's
            // far side, thin and dark.
            out.append(Sprite(r.texture, at: CGPoint(x: r.position.x + 6, y: r.position.y + height * 0.35),
                              size: CGSize(width: width, height: height * 0.55), rotation: 0,
                              mode: .shadow, alpha: 0.3, z: 0))
            out.append(Sprite(r.texture, at: r.position, size: sz, rotation: r.rotation + r.sway, alpha: 1,
                              wave: Float(time) * 0.9 + r.phase, z: 0.07, stands: true))
        }
        return out
    }

    /// The stream's mouth: the rocks it falls over, sat on the bank with its
    /// trickle meeting the water, and the foam it throws into the pond.
    func inletSprites() -> [Sprite] {
        guard let inlet, size.width > 0 else { return [] }
        var out: [Sprite] = []
        let t = textureSize("inlet_rocks")
        let w: CGFloat = 150
        let h = w * t.height / max(1, t.width)
        // The water end of the painting is its foot, so the picture sits
        // above the point the stream runs in at.
        out.append(Sprite("inlet_rocks", at: CGPoint(x: inlet.x + 6, y: inlet.y - h * 0.34),
                          size: CGSize(width: w, height: h), mode: .shadow, alpha: 0.3, z: 0.09))
        out.append(Sprite("inlet_rocks", at: CGPoint(x: inlet.x, y: inlet.y - h * 0.42),
                          size: CGSize(width: w, height: h), alpha: 1, z: 0.1))
        // Foam is cloud art printed pale: the tint is well over one so a grey
        // wisp comes out as white water rather than a grey lump.
        let wisp = art.clouds.first ?? "cloud_1"
        for f in foam {
            out.append(Sprite(wisp, at: f.position, size: CGSize(width: f.size * 1.7, height: f.size),
                              alpha: f.alpha, tint: [2.0, 2.1, 2.2, 1], z: 0.02))
        }
        return out
    }

    /// Mist on the water: wide white-blue wisps, thickest when the pond is
    /// first seen and thinning as the morning warms.
    func mistSprites() -> [Sprite] {
        // A quarter of it is still there after a minute and a half.
        let burn = max(0.25, 1 - levelAge / 90)
        let scale = mistAmount * burn
        guard scale > 0.02 else { return [] }
        return mists.map { m in
            Sprite(m.texture, at: m.position, size: CGSize(width: m.width, height: m.width * m.aspect),
                   mode: .floater, alpha: m.alpha * scale, tint: [0.93, 0.97, 1.0, 1], z: 0.4)
        }
    }

    /// Drops on their way off the branches to the water. Each has its own
    /// dark mark on the water under it, so the eye reads the fall.
    func dripSprites() -> [Sprite] {
        var out: [Sprite] = []
        for d in drips {
            out.append(Sprite("mote", at: d.to, size: CGSize(width: 5, height: 3),
                              mode: .shadow, alpha: 0.2, z: 0.04))
            out.append(Sprite("mote", at: d.position, size: CGSize(width: 5, height: 8), alpha: 0.95,
                              tint: [1.5, 1.7, 1.9, 1], z: 0.55))
        }
        return out
    }

    /// A koi out of the water: its painting arcing over the pond with its
    /// shadow running along underneath it.
    func leapSprites() -> [Sprite] {
        var out: [Sprite] = []
        for l in leaps {
            let t = textureSize(l.texture)
            let h: CGFloat = 130
            let w = h * t.width / max(1, t.height)
            let p = l.position
            let lift = l.lift
            // The shadow stays on the water, and shrinks as the fish climbs.
            let shrink = 1 - 0.3 * lift / max(1, l.height)
            out.append(Sprite(l.texture, at: CGPoint(x: p.x + lift * 0.25, y: p.y + lift * 0.4),
                              size: CGSize(width: w * shrink, height: h * shrink * 0.55),
                              mode: .shadow, alpha: Float(0.5 * shrink), flipX: l.flipped, z: 0.05))
            out.append(Sprite(l.texture, at: CGPoint(x: p.x, y: p.y - lift),
                              size: CGSize(width: w, height: h), alpha: 1, flipX: l.flipped,
                              z: 0.6 + Float(lift) * 0.002))
        }
        return out
    }

    /// In the air: clouds and whatever is flying over.
    func skySprites() -> [Sprite] {
        var out: [Sprite] = clouds.map { c in
            Sprite(c.texture, at: c.position, size: CGSize(width: c.width, height: c.width * c.aspect),
                   alpha: 0.22, tint: [0.92, 0.97, 1.0, 1], z: 2.2)
        }
        if let f = dragonfly { out += f.sprites(textureSize) }

        return out
    }

    /// Over the surface: falling blossom.
    func petalSprites() -> [Sprite] {
        petals.map { p in
            Sprite(p.texture, at: CGPoint(x: p.x, y: p.y), size: CGSize(width: 14 * p.scale, height: 14 * p.scale),
                   rotation: p.rotation, mode: p.landed ? .floater : .plain, alpha: p.alpha,
                   z: p.landed ? 0 : 0.5)
        }
    }

    /// Over the surface: drops of water still in the air. Each is drawn at
    /// its height above the point it will land on, with a small dark mark on
    /// the water beneath it so the eye reads the gap.
    func dropletSprites() -> [Sprite] {
        var out: [Sprite] = []
        for d in droplets {
            let lift = d.lift
            if lift > 6 {
                out.append(Sprite("mote", at: d.position, size: CGSize(width: d.size * 0.7, height: d.size * 0.5),
                                  mode: .shadow, alpha: 0.25, z: 0.05))
            }
            out.append(Sprite("mote", at: CGPoint(x: d.position.x, y: d.position.y - lift),
                              size: CGSize(width: d.size * 0.85, height: d.size * 1.15),
                              alpha: 0.9, tint: [0.90, 0.96, 1.0, 1], z: 0.55 + Float(lift) * 0.002))
        }
        return out
    }

    /// The frame: branches at the top corners and the bank along the bottom.
    func floraSprites() -> [Sprite] {
        guard size.width > 0 else { return [] }
        var out: [Sprite] = []
        let w = size.width
        guard !art.branch.isEmpty else { return out }
        // The stage is kept inside the states this season actually has, and a
        // stage that is not a number is read as the bare one.
        let top = art.branch.count - 1
        let stage = bloomStage.isFinite ? min(Float(top), max(0, bloomStage)) : 0
        let lo = Int(floor(stage)), hi = min(top, lo + 1)
        let t = stage - Float(lo)

        func branch(_ index: Int, alpha: Float) {
            guard alpha > 0.01, index < art.branch.count else { return }
            let name = art.branch[index]
            let side = w * art.branchScale
            let left = CGPoint(x: side * 0.5 - art.branchInset, y: side * 0.5 - art.branchInset)
            out.append(Sprite(name, at: left, size: CGSize(width: side, height: side), alpha: alpha, z: 0.9))
            let small = side * art.branchRightScale
            let right = CGPoint(x: w - small * 0.5 + art.branchInset, y: small * 0.5 + art.branchRightDrop)
            out.append(Sprite(name, at: right, size: CGSize(width: small, height: small), alpha: alpha, flipX: true, z: 0.9))
        }
        branch(lo, alpha: 1)
        if hi != lo { branch(hi, alpha: t) }

        if let bank = art.bank {
            let bw = w * 1.06
            let ts = textureSize(bank)
            let bh = bw * ts.height / max(1, ts.width)
            out.append(Sprite(bank, at: CGPoint(x: w / 2, y: size.height - bh * 0.5 + art.bankSink),
                              size: CGSize(width: bw, height: bh), z: 0.12))
        }
        return out
    }
}

/// A fish that wanders under the surface, rises to show itself, and dives
/// when it feels like it or when it is tapped.
final class Koi {
    let texture: String
    let forward: Float
    let waveAmp: Float
    /// How big the fish is against the one a level has, 1 as won. The plot
    /// grows a fed koi through this; the body, the head and the turn it
    /// can make all scale with it.
    var bodyScale: CGFloat = 1
    var width: CGFloat { 74 * bodyScale }
    let aspect: CGFloat
    /// The water under a point, 0 dry to 1 deep, when the pond has ground
    /// in it the fish must keep off (the plot). Nil in a level's bowl.
    var waterAt: ((CGPoint) -> Float)?
    private(set) var position = CGPoint.zero
    private(set) var heading: Float
    private(set) var depth: Float = 1
    private(set) var phase: Float = 0
    /// How far the fish is banked into its turn, -1...1, eased.
    private(set) var roll: Float = 0
    /// Ice cover over the pond; above a half the fish will not surface.
    var iceOver: Float = 0
    /// The fish is in the air: nothing steers it and nothing draws its body.
    private(set) var leaping = false
    /// Set the frame it goes down, so air can leave the bed under it.
    var justDived = false
    private var target = CGPoint.zero
    private var speed: CGFloat = 34
    private var stateUntil: TimeInterval
    private var depthTarget: Float = 1
    private var depthRate: Float = 0.5
    private var started = false
    /// Where the fish is being led, if it is: a held finger, the shy koi's
    /// way out or back. While set it steers here instead of wandering, and
    /// its own dive and surface timers wait.
    struct Guide {
        var point: CGPoint
        /// Points per second when there is a way to go.
        var speed: CGFloat
        var depth: Float
        /// Within this of the point it slows to a hover.
        var stop: CGFloat
        /// Measure from the mouth rather than the middle: a finger is nosed at.
        var byHead: Bool
    }
    private(set) var guide: Guide?
    /// The fish lies still: on the bed asleep, or under its home shape. A
    /// tiny drift and a slow tail keep it from being a picture.
    private(set) var resting = false
    private var restPoint = CGPoint.zero
    private var restPhase: Float = 0
    /// Where the head has been, newest first, one entry per couple of points.
    private var trail: [CGPoint] = []
    private var trailDistances: [Float] = []

    init(texture: String, forward: Float, seed: Int, waveAmp: Float) {
        self.texture = texture
        self.forward = forward
        self.waveAmp = waveAmp
        self.aspect = 2.9
        heading = Float(seed) * 1.7
        stateUntil = 2 + Double(seed) * 5
    }

    var rotation: Float { heading - forward }

    /// Where the mouth is.
    var headPoint: CGPoint {
        CGPoint(x: position.x + CGFloat(cos(heading)) * width * 1.3, y: position.y + CGFloat(sin(heading)) * width * 1.3)
    }

    /// Returns a splash when the fish breaks the surface.
    func update(dt: Float, now: TimeInterval, in size: CGSize,
                rocks: [(centre: CGPoint, radius: CGFloat)] = []) -> (at: CGPoint, radius: Float, amplitude: Float)? {
        if !started {
            started = true
            place(in: size)
            pickTarget(in: size)
        }
        if resting {
            // Lying still: the depth settles, the body barely moves, the tail
            // idles. Nothing steers and nothing times a dive.
            depth += (depthTarget - depth) * min(1, dt * depthRate)
            restPhase += dt * 0.5
            position = CGPoint(x: restPoint.x + CGFloat(sin(restPhase)) * 2.5,
                               y: restPoint.y + CGFloat(cos(restPhase * 0.7)) * 1.5)
            phase += dt * 0.6
            roll += (0 - roll) * min(1, dt * 2)
            stateUntil = now + 4
            return nil
        }
        if let g = guide {
            // Led: the point is the target and the fish's own timers wait.
            target = g.point
            depthTarget = g.depth
            stateUntil = now + 4
        }
        var splash: (at: CGPoint, radius: Float, amplitude: Float)?
        if now > stateUntil {
            if depth < 0.5 {
                dive(now: now, quick: false)
            } else if iceOver < 0.5 {
                surface(now: now, in: size)
                splash = (position, 9, -0.12)
            } else {
                // Under ice: keep cruising deep, try again later.
                stateUntil = now + 4
            }
        }
        depth += (depthTarget - depth) * min(1, dt * depthRate)

        let from = (guide?.byHead ?? false) ? headPoint : position
        let dx = Float(target.x - from.x), dy = Float(target.y - from.y)
        let reach = hypot(dx, dy)
        if guide == nil, reach < 30 { pickTarget(in: size) }
        var want = atan2(dy, dx)
        // At the point it is led to, the heading holds with a slow sway of
        // the nose rather than hunting after a point it is already on.
        let hovering = guide.map { reach < Float($0.stop) } ?? false
        if hovering { want = heading + sin(Float(now) * 1.1) * 0.25 }
        if Koi.diagnostics, Int(now * 2) != Int((now - Double(dt)) * 2) {
            var d0 = want - heading
            while d0 > .pi { d0 -= 2 * .pi }
            while d0 < -.pi { d0 += 2 * .pi }
            NSLog("[koi %@] pos=(%.0f,%.0f) speed=%.1f diff=%.2f depth=%.2f dist=%.0f", texture, position.x, position.y, Float(speed), d0, depth, hypot(dx, dy))
        }
        // A bank ahead bends the wish away from it, well before it is reached,
        // so the fish sweeps round in open water instead of nosing the edge.
        do {
            // A led fish may be brought near the bank: the finger is on water.
            let margin: Float = guide != nil ? 70 : 170
            let px = Float(position.x), py = Float(position.y)
            let w = Float(size.width), h = Float(size.height)
            var push = SIMD2<Float>(0, 0)
            if px < margin { push.x += (margin - px) / margin }
            if px > w - margin { push.x -= (px - (w - margin)) / margin }
            if py < margin { push.y += (margin - py) / margin }
            if py > h - margin { push.y -= (py - (h - margin)) / margin }
            if simd_length(push) > 0.01 {
                let ahead = SIMD2(cos(heading), sin(heading))
                // Only bend when actually heading toward the bank.
                if simd_dot(ahead, push) < 0 {
                    let wish = simd_normalize(ahead + push * 1.6)
                    want = atan2(wish.y, wish.x)
                }
            }
        }
        // A rock ahead bends the wish to one side, well before it is reached.
        for r in rocks {
            let rx = Float(r.centre.x - position.x), ry = Float(r.centre.y - position.y)
            let dist = hypot(rx, ry)
            let reach = Float(r.radius) + 90
            guard dist < reach else { continue }
            var ahead = atan2(ry, rx) - heading
            while ahead > .pi { ahead -= 2 * .pi }
            while ahead < -.pi { ahead += 2 * .pi }
            guard abs(ahead) < 1.2 else { continue }
            let push = (1 - dist / reach) * 1.4
            want = heading + (ahead >= 0 ? -push : push)
        }
        // The plot: ground ahead bends the wish away from it the way a rock
        // does, the near reading harder than the far one, toward whichever
        // side has more water under it. A fish that has strayed over the
        // earth makes for the nearest water at speed, turning as hard as a
        // fleeing fish may.
        var grounded = false
        if let water = waterAt {
            if water(position) < 0.15 {
                grounded = true
                if let w = nearestWaterPoint(from: position, water: water) {
                    want = atan2(Float(w.y - position.y), Float(w.x - position.x))
                }
                speed = max(speed, 60)
            } else {
                for (reach, push) in [(CGFloat(60), Float(1.3)), (120, 0.7)] {
                    let p = CGPoint(x: position.x + CGFloat(cos(heading)) * reach, y: position.y + CGFloat(sin(heading)) * reach)
                    guard water(p) < 0.25 else { continue }
                    let l = CGPoint(x: position.x + CGFloat(cos(heading - 0.9)) * reach, y: position.y + CGFloat(sin(heading - 0.9)) * reach)
                    let r = CGPoint(x: position.x + CGFloat(cos(heading + 0.9)) * reach, y: position.y + CGFloat(sin(heading + 0.9)) * reach)
                    want = heading + (water(l) >= water(r) ? -push : push)
                    break
                }
            }
        }
        var diff = want - heading
        while diff > .pi { diff -= 2 * .pi }
        while diff < -.pi { diff += 2 * .pi }
        // Real koi turn in wide arcs. The rate is capped so the path the body
        // is laid along never bends tighter than about a body length, and the
        // turn eases in and out rather than snapping to full rate.
        // The path can never bend tighter than the body can follow: the turn
        // radius stays above the fish's width, so the mesh never folds.
        // Fleeing, the fish turns as hard as its body allows and its speed
        // decays back to a cruise; otherwise it turns lazily.
        let fleeing = now < fleeUntil || grounded
        // A point behind the fish and closer than the arc it can turn in lies
        // inside its turning circle: turning now would only orbit it. It
        // swims on straight to open the distance, then comes round head on.
        if guide != nil, !hovering, abs(diff) > 1.3, reach < Float(width) * 1.1 * 2.4 {
            diff = 0
        }
        if let g = guide {
            // Led: slow as the point nears, stop at it. Turning round to a
            // point behind needs way on, so it sweeps round in an arc
            // rather than pivoting on the spot.
            var desired: CGFloat = 0
            if !hovering { desired = min(g.speed, 4 + CGFloat(reach - Float(g.stop)) * 0.5) }
            if abs(diff) > 0.7 { desired = max(desired, 24) }
            let ease = CGFloat(min(1, dt * 1.8))
            speed += (desired - speed) * ease
        }
        if speed > 46 { speed -= CGFloat(dt) * (fleeing ? 20 : 45) }
        // A fish that has to turn hard puts on a little speed to do it, so
        // the turn is a tail-flick sweep rather than a crawl.
        if abs(diff) > 1.0, speed < 40 { speed += CGFloat(dt) * 30 }
        let s = Float(speed) * (depth > 0.9 ? 0.5 : 1) * (1 - 0.15 * min(1, abs(diff)))
        // A led fish creeping up to a finger turns no tighter than its body
        // allows either: the floor on the rate comes off at a crawl.
        let maxRate = min(fleeing ? 1.6 : 0.55, max(guide != nil ? 0.10 : 0.32, s / (Float(width) * 1.1)))
        let wantRate = min(maxRate, abs(diff) * 0.8)
        let turn = max(-wantRate * dt, min(wantRate * dt, diff))
        heading += turn
        let rollTarget = max(-1, min(1, (dt > 0 ? turn / dt : 0) / 0.9))
        roll += (rollTarget - roll) * min(1, dt * 3)
        let tightness = min(1, abs(diff) / 1.2)
        position.x += CGFloat(cos(heading) * s * dt)
        position.y += CGFloat(sin(heading) * s * dt)
        phase += dt * (3.0 + s * 0.09 + tightness * 2.5 + (fleeing ? 6 : 0))
        record()
        return splash
    }

    private func record() {
        if let last = trail.first {
            let step = hypot(position.x - last.x, position.y - last.y)
            guard step >= 1.5 else { return }
            trail.insert(position, at: 0)
            trailDistances.insert(Float(step), at: 0)
        } else {
            straightTrail()
        }
        if trail.count > 400 {
            trail.removeLast(trail.count - 400)
            trailDistances.removeLast(trailDistances.count - 400)
        }
    }

    /// A fresh fish (or one that just reappeared) has a straight body behind it.
    private func straightTrail() {
        trail = []
        trailDistances = []
        let hx = CGFloat(cos(heading)), hy = CGFloat(sin(heading))
        let back = CGVector(dx: -hx * 2, dy: -hy * 2)
        var p = position
        for _ in 0..<200 {
            trail.append(p)
            trailDistances.append(2)
            p = CGPoint(x: p.x + back.dx, y: p.y + back.dy)
        }
    }

    /// 13 spine points for the mesh, tail (row 0) to head (row 12): each
    /// sits the right distance back along the recorded path, so the body
    /// bends wherever the head turned.
    func spine(length: CGFloat) -> [SIMD4<Float>] {
        if trail.isEmpty { straightTrail() }
        var rows: [SIMD4<Float>] = []
        let total = Float(length)
        // The head and the front third of the body are rigid; the bend lives
        // in the rear two thirds, the way a carp actually flexes.
        let headTangent = SIMD2(cos(heading), sin(heading))
        let head = SIMD2(Float(position.x), Float(position.y))
        for row in 0...12 {
            if row >= 9 {
                let back = total * (1 - Float(row) / 12)
                let pos = head - headTangent * back
                rows.append(SIMD4(pos.x, pos.y, headTangent.x, headTangent.y))
                continue
            }
            let back = total * (1 - Float(row) / 12)
            var acc: Float = 0
            var i = 0
            while i < trail.count - 1, acc + trailDistances[i] < back { acc += trailDistances[i]; i += 1 }
            let a = trail[i]
            let b = trail[min(i + 1, trail.count - 1)]
            let seg = max(0.001, trailDistances[min(i, trailDistances.count - 1)])
            let t = min(1, max(0, (back - acc) / seg))
            let ct = CGFloat(t)
            let px = a.x + (b.x - a.x) * ct
            let py = a.y + (b.y - a.y) * ct
            let pos = SIMD2<Float>(Float(px), Float(py))
            // Tangent toward the head: from this point toward the newer sample.
            let newer = trail[max(0, i - 1)]
            var tangent = SIMD2(Float(newer.x - b.x), Float(newer.y - b.y))
            let len = simd_length(tangent)
            tangent = len > 0.001 ? tangent / len : SIMD2(cos(heading), sin(heading))
            rows.append(SIMD4(pos.x, pos.y, tangent.x, tangent.y))
        }
        // Blend the last flexible rows toward the rigid line so there is no
        // kink, then smooth the whole spine twice and take the tangents from
        // neighbouring rows, so the body is one continuous curve.
        for row in stride(from: 8, through: 6, by: -1) {
            let t = Float(9 - row) / 4
            let back = total * (1 - Float(row) / 12)
            let rigid = head - headTangent * back
            rows[row].x = rows[row].x * t + rigid.x * (1 - t)
            rows[row].y = rows[row].y * t + rigid.y * (1 - t)
        }
        for _ in 0..<2 {
            var smoothed = rows
            for row in 1...11 {
                smoothed[row].x = (rows[row - 1].x + 2 * rows[row].x + rows[row + 1].x) * 0.25
                smoothed[row].y = (rows[row - 1].y + 2 * rows[row].y + rows[row + 1].y) * 0.25
            }
            rows = smoothed
        }
        for row in 0...12 {
            let a = rows[max(0, row - 1)], b = rows[min(12, row + 1)]
            var tan = SIMD2(b.x - a.x, b.y - a.y)
            let len = simd_length(tan)
            tan = len > 0.001 ? tan / len : headTangent
            rows[row].z = tan.x
            rows[row].w = tan.y
        }
        if Koi.diagnostics {
            let body = SIMD2(rows[12].x - rows[4].x, rows[12].y - rows[4].y)
            let bodyLen = simd_length(body)
            if bodyLen > 1 {
                let cosA = simd_dot(body / bodyLen, headTangent)
                if cosA < 0.5 {
                    NSLog("[koi] body/heading %.0f deg speed %.1f depth %.2f flee %d trail %d rate", acos(max(-1, min(1, cosA))) * 180 / .pi, Float(speed), depth, fleeUntil > 0 ? 1 : 0, trail.count)
                }
            }
        }
        return rows
    }
    static let diagnostics = ProcessInfo.processInfo.arguments.contains("-diag")

    /// Somewhere in open water, for a fish that has not been placed yet.
    private func place(in size: CGSize) {
        if let w = randomWaterPoint(in: size) { position = w; return }
        position = CGPoint(x: CGFloat.random(in: 80...max(80, size.width - 80)),
                           y: CGFloat.random(in: 140...max(140, size.height - 160)))
    }

    /// A point over water somewhere in the pond, or nil when the pond is a
    /// bowl (no water reading) or nothing turned up in a dozen tries.
    private func randomWaterPoint(in size: CGSize) -> CGPoint? {
        guard let water = waterAt else { return nil }
        for _ in 0..<12 {
            let p = CGPoint(x: CGFloat.random(in: 40...max(40, size.width - 40)),
                            y: CGFloat.random(in: 40...max(40, size.height - 40)))
            if water(p) > 0.35 { return p }
        }
        return nil
    }

    /// Let go here, in the plot: the fish starts at this point a little
    /// under the surface with a straight body, and swims off on its own.
    func release(at p: CGPoint, in size: CGSize, now: TimeInterval) {
        started = true
        resting = false
        guide = nil
        position = p
        heading = Float.random(in: 0...(2 * .pi))
        depth = 0.5
        depthTarget = 0.2
        depthRate = 0.5
        straightTrail()
        pickTarget(in: size)
        stateUntil = now + Double.random(in: 8...14)
    }

    // MARK: Led, resting, curious

    /// Steer to a point (a finger, a shelter) instead of wandering.
    func lead(_ g: Guide) {
        resting = false
        guide = g
    }

    /// Let go: it picks somewhere of its own and cruises off, and its own
    /// timers run again so it dives in its own time.
    func freeGuide(now: TimeInterval, in size: CGSize) {
        guard guide != nil || resting else { return }
        guide = nil
        resting = false
        if !started { started = true; place(in: size) }
        pickTarget(in: size)
        speed = max(speed, 20)
        stateUntil = now + Double.random(in: 6...12)
    }

    /// Lie still here, at this depth. A nil point means where it is (a fish
    /// not yet placed is given a spot first); a nil heading keeps its own.
    func rest(at p: CGPoint?, depth d: Float, heading h: Float?, in size: CGSize) {
        if !started { started = true; place(in: size) }
        resting = true
        guide = nil
        if let p { position = p }
        restPoint = position
        if let h { heading = h }
        depthTarget = d
        depthRate = 0.5
        speed = 0
        roll = 0
        straightTrail()
    }

    /// Up off the bed or out of shelter: it rises toward `depth` over about
    /// 1/rate seconds and starts to swim.
    func stir(depth d: Float, rate: Float, now: TimeInterval, in size: CGSize) {
        resting = false
        guide = nil
        depthTarget = d
        depthRate = rate
        pickTarget(in: size)
        speed = 16
        stateUntil = now + Double.random(in: 8...14)
    }

    /// A ring far off caught its eye: its next target is toward the source,
    /// stopping short of it, at a cruise. A deep fish comes up a little to
    /// look. It cruises on from there as usual.
    func drawToward(_ point: CGPoint, stoppingShort short: CGFloat, now: TimeInterval) {
        guard guide == nil, !resting, !leaping else { return }
        let dx = position.x - point.x, dy = position.y - point.y
        let d = max(1, hypot(dx, dy))
        target = CGPoint(x: point.x + dx / d * short, y: point.y + dy / d * short)
        speed = max(speed, 28)
        if iceOver < 0.5, depthTarget > 0.4 {
            depthTarget = 0.4
            depthRate = 0.35
            stateUntil = max(stateUntil, now + 8)
        }
    }

    private func pickTarget(in size: CGSize) {
        // Somewhere ahead and far: a fish cruises in long arcs, it does not
        // dither or double back. If nothing ahead is open water (it is up
        // against a bank), it sweeps round in a wide arc to the side.
        var best: CGPoint?
        var bestScore: Float = -1
        // In the plot only a point over water will do, and the pond may be
        // small, so a nearer point is allowed and a few more are tried.
        let water = waterAt
        let tries = water == nil ? 16 : 28
        let farEnough: Float = water == nil ? 200 : 80
        for _ in 0..<tries {
            let candidate = water == nil
                ? CGPoint(x: CGFloat.random(in: 90...max(90, size.width - 90)),
                          y: CGFloat.random(in: 150...max(150, size.height - 170)))
                : CGPoint(x: CGFloat.random(in: 40...max(40, size.width - 40)),
                          y: CGFloat.random(in: 40...max(40, size.height - 40)))
            if let water, water(candidate) <= 0.35 { continue }
            let dx = Float(candidate.x - position.x), dy = Float(candidate.y - position.y)
            let dist = hypot(dx, dy)
            var diff = atan2(dy, dx) - heading
            while diff > .pi { diff -= 2 * .pi }
            while diff < -.pi { diff += 2 * .pi }
            guard dist > farEnough, abs(diff) < 1.1 else { continue }
            let score = dist * (1.2 - abs(diff))
            if score > bestScore { bestScore = score; best = candidate }
        }
        if let b = best {
            target = b
        } else if let water, let w = randomWaterPoint(in: size) ?? nearestWaterPoint(from: position, water: water) {
            target = w
        } else {
            let side: Float = position.x < size.width / 2 ? 1 : -1
            let arc = heading + side * 1.2
            let raw = CGPoint(x: position.x + CGFloat(cos(arc)) * 260, y: position.y + CGFloat(sin(arc)) * 260)
            target = CGPoint(x: min(max(raw.x, 90), size.width - 90), y: min(max(raw.y, 150), size.height - 170))
        }
        speed = CGFloat.random(in: 24...40)
    }

    private func surface(now: TimeInterval, in size: CGSize) {
        depthRate = 0.55
        // Reappear somewhere new only if the fish is fully hidden.
        if depth > 0.95 {
            position = randomWaterPoint(in: size)
                ?? CGPoint(x: CGFloat.random(in: 80...max(80, size.width - 80)),
                           y: CGFloat.random(in: 140...max(140, size.height - 160)))
            pickTarget(in: size)
            heading = atan2(Float(target.y - position.y), Float(target.x - position.x))
            straightTrail()
        }
        depthTarget = 0.12
        stateUntil = now + Double.random(in: 10...18)
    }

    func dive(now: TimeInterval, quick: Bool) {
        guide = nil
        resting = false
        depthTarget = 1
        depthRate = quick ? 1.4 : 0.45
        if quick { speed = 70 }
        justDived = true
        stateUntil = now + Double.random(in: quick ? 6...11 : 4...9)
    }

    /// The fish leaves the water. Its painting in the air is the whole of it
    /// until it comes down.
    func beginLeap() {
        leaping = true
        guide = nil
        resting = false
        depth = 0
    }

    /// It lands a body length or two on, goes under, and swims back up to
    /// the surface over the next second.
    func land(at p: CGPoint, heading h: Float, now: TimeInterval, in size: CGSize) {
        leaping = false
        guide = nil
        resting = false
        position = p
        heading = h
        straightTrail()
        depth = 0.8
        depthTarget = 0.12
        depthRate = 0.7
        stateUntil = now + Double.random(in: 9...15)
        pickTarget(in: size)
        speed = 46
    }

    /// A tap nearby: the fish bolts away from it with a burst of speed and
    /// a hard tail beat, then settles back into its cruise.
    private var fleeUntil: TimeInterval = 0
    func startle(from point: CGPoint, now: TimeInterval) {
        let dx = Float(position.x - point.x), dy = Float(position.y - point.y)
        let dist = hypot(dx, dy)
        guard dist < 220, dist > 0.5 else { return }
        let away = atan2(dy, dx) + Float.random(in: -0.35...0.35)
        target = CGPoint(x: position.x + CGFloat(cos(away)) * 320, y: position.y + CGFloat(sin(away)) * 320)
        speed = CGFloat(130 * (1.1 - dist / 260))
        fleeUntil = now + 1.4
        stateUntil = max(stateUntil, now + 6)
    }
}

/// The nearest point with real water under it, rings of sixteen samples
/// widening out from `p`, or nil if none lies within reach. For a fish
/// that has found itself over the earth.
func nearestWaterPoint(from p: CGPoint, water: (CGPoint) -> Float) -> CGPoint? {
    for r in stride(from: CGFloat(30), through: 270, by: 30) {
        for i in 0..<16 {
            let a = CGFloat(i) / 16 * 2 * .pi
            let q = CGPoint(x: p.x + cos(a) * r, y: p.y + sin(a) * r)
            if water(q) > 0.35 { return q }
        }
    }
    return nil
}

/// Blossom drifting down from the branches to land on the water.
final class FallingPetal {
    let texture: String
    var x: CGFloat
    var y: CGFloat
    var rotation: Float
    var scale: CGFloat
    var alpha: Float = 1
    private(set) var landed = false
    private var vx: CGFloat
    private var vy: CGFloat
    private var spin: Float
    private var sway: Float
    private var age: Float = 0
    private var life: Float

    var dead: Bool { alpha <= 0.01 }

    init(x: CGFloat, y: CGFloat, texture: String) {
        self.texture = texture
        self.x = x
        self.y = y
        rotation = Float.random(in: 0...(2 * .pi))
        scale = CGFloat.random(in: 0.8...1.3)
        vx = CGFloat.random(in: -10...14)
        vy = CGFloat.random(in: 22...40)
        spin = Float.random(in: -1.5...1.5)
        sway = Float.random(in: 0...(2 * .pi))
        life = Float.random(in: 9...14)
    }

    func update(dt: Float) {
        age += dt
        if landed {
            alpha = max(0, alpha - dt * 0.25)
            return
        }
        sway += dt * 2.2
        x += (vx + CGFloat(sin(sway)) * 18) * CGFloat(dt)
        y += vy * CGFloat(dt)
        rotation += spin * dt
    }

    func land() {
        landed = true
        vx = 0
        vy = 0
    }

    /// The wind takes it. A petal already on the water stays put.
    func blow(dx: CGFloat, dy: CGFloat) {
        guard !landed else { return }
        vx += dx
        vy += dy
    }
}

/// A drop of water thrown up by a splash. It travels across the pond and
/// falls at the same time, and where it comes down it makes its own ring.
final class Droplet {
    private(set) var position: CGPoint
    private var velocity: CGVector
    /// Height above the surface in points, and the speed it is climbing at.
    private(set) var lift: CGFloat = 0
    private var liftVel: CGFloat
    let size: CGFloat
    private(set) var landed = false

    /// Points per second squared. A drop thrown up at 100 is back in
    /// half a second.
    private static let gravity: CGFloat = 400

    init(at p: CGPoint, velocity: CGVector, up: CGFloat, size: CGFloat) {
        position = p
        self.velocity = velocity
        liftVel = up
        self.size = size
    }

    func blow(dx: CGFloat, dy: CGFloat) {
        velocity.dx += dx
        velocity.dy += dy
    }

    func update(dt: Float) {
        let d = CGFloat(dt)
        position.x += velocity.dx * d
        position.y += velocity.dy * d
        liftVel -= Droplet.gravity * d
        lift += liftVel * d
        if lift <= 0 {
            lift = 0
            landed = true
        }
    }
}

/// A bubble of air leaving the bed and rising to the surface, where it pops.
final class Bubble {
    private(set) var position: CGPoint
    /// 1 at the bed, 0 at the surface.
    private(set) var depth: Float
    private let rate: Float
    let size: CGFloat
    private var phase: Float
    private(set) var popped = false

    init(at p: CGPoint, size: CGFloat) {
        position = p
        depth = Float.random(in: 0.75...1.0)
        // Slow enough to be watched all the way up.
        rate = Float.random(in: 0.55...0.95)
        self.size = size
        phase = Float.random(in: 0...(2 * .pi))
    }

    func update(dt: Float) {
        phase += dt * 5
        depth -= rate * dt
        // A bubble wanders a little as it climbs.
        position.x += CGFloat(sin(phase) * 9) * CGFloat(dt)
        position.y -= CGFloat(dt) * 4
        if depth <= 0 {
            depth = 0
            popped = true
        }
    }
}


/// A bank of mist lying on the water. It drifts across the pond, comes round
/// the other side, and thins as the level warms up.
final class Mist {
    let texture: String
    private(set) var position: CGPoint
    let width: CGFloat
    let aspect: CGFloat
    let alpha: Float
    private let speed: CGFloat
    private var phase: Float

    init(texture: String, size: CGSize) {
        self.texture = texture
        width = size.width * CGFloat.random(in: 0.75...1.3)
        aspect = CGFloat.random(in: 0.24...0.40)
        position = CGPoint(x: CGFloat.random(in: -0.2...1.2) * size.width,
                           y: size.height * CGFloat.random(in: 0.12...0.88))
        alpha = Float.random(in: 0.18...0.35)
        speed = CGFloat.random(in: 3...8) * (Bool.random() ? 1 : -1)
        phase = Float.random(in: 0...(2 * .pi))
    }

    func update(dt: Float, in bounds: CGSize) {
        phase += dt * 0.35
        position.x += speed * CGFloat(dt)
        position.y += CGFloat(sin(phase)) * 4 * CGFloat(dt)
        if position.x - width > bounds.width { position.x = -width }
        if position.x + width < 0 { position.x = bounds.width + width }
    }
}

/// A wisp of foam thrown off the stream's mouth, carried a little way into
/// the pond before it thins away.
final class Foam {
    private(set) var position: CGPoint
    private let drift: CGVector
    let size: CGFloat
    private var age: Float = 0
    private let life: Float = 3.2

    var alpha: Float { 0.3 * max(0, 1 - age / life) }
    var dead: Bool { age >= life }

    init(at p: CGPoint, drift: CGVector, size: CGFloat) {
        position = p
        self.drift = drift
        self.size = size
    }

    func update(dt: Float) {
        age += dt
        position.x += drift.dx * CGFloat(dt)
        position.y += drift.dy * CGFloat(dt)
    }
}

/// A drop of water leaving a branch. It falls faster the further it has
/// come, and rings the water where it lands.
final class Drip {
    private let from: CGPoint
    let to: CGPoint
    private var age: Float = 0
    private let fall: Float = 0.5

    var landed: Bool { age >= fall }
    var position: CGPoint {
        let t = CGFloat(min(1, age / fall))
        let g = t * t
        return CGPoint(x: from.x + (to.x - from.x) * g, y: from.y + (to.y - from.y) * g)
    }

    init(from: CGPoint, to: CGPoint) {
        self.from = from
        self.to = to
    }

    func update(dt: Float) { age += dt }
}

/// A koi in the air. It leaves the water at one point and comes down at
/// another, and while it is up its painting is the whole of the fish.
final class Leap {
    let koi: Koi
    let texture: String
    let from: CGPoint
    let to: CGPoint
    let height: CGFloat
    private var age: Float = 0
    private let span: Float = 0.7

    init(koi: Koi, texture: String, from: CGPoint, to: CGPoint, height: CGFloat) {
        self.koi = koi
        self.texture = texture
        self.from = from
        self.to = to
        self.height = height
    }

    var done: Bool { age >= span }
    /// The painting is drawn nose to the right, so a fish going left is flipped.
    var flipped: Bool { to.x < from.x }
    var heading: Float { atan2(Float(to.y - from.y), Float(to.x - from.x)) }

    var position: CGPoint {
        let t = CGFloat(min(1, age / span))
        return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
    }

    /// Height over the water in points: up, over, and down again.
    var lift: CGFloat { height * CGFloat(sin(Double(min(1, age / span)) * .pi)) }

    func update(dt: Float) { age += dt }
}

/// A strand of pondweed rooted in the bed, bending as a spring.
final class Weed {
    let texture: String
    let root: CGPoint
    let bedDepth: Float
    let height: CGFloat
    let lean: Float
    let phase: Float
    let depth: Float
    var bend: Float = 0
    var bendVel: Float = 0

    init(texture: String, root: CGPoint, bedDepth: Float, height: CGFloat, lean: Float, phase: Float, depth: Float) {
        self.texture = texture
        self.root = root
        self.bedDepth = bedDepth
        self.height = height
        self.lean = lean
        self.phase = phase
        self.depth = depth
    }
}

/// A small creature: a tadpole under the surface or a skater on it. It rests,
/// then darts a short way, then rests again.
final class Critter {
    let texture: String
    let forward: Float
    let size: CGFloat
    let under: Bool
    private(set) var position = CGPoint.zero
    private(set) var heading: Float
    private var speed: Float = 0
    private var restUntil: TimeInterval
    private var started = false
    private var crossing = false

    let slow: Bool
    var moving: Bool { speed > 1 }

    init(texture: String, forward: Float, size: CGFloat, seed: Int, under: Bool, slow: Bool = false) {
        self.texture = texture
        self.forward = forward
        self.size = size
        self.under = under
        self.slow = slow
        heading = Float(seed) * 1.3
        restUntil = Double(seed) * 0.7
    }

    var rotation: Float { heading - forward }

    func spriteSize(_ textureSize: (String) -> CGSize) -> CGSize {
        let t = textureSize(texture)
        let long = max(t.width, t.height)
        return CGSize(width: size * t.width / long, height: size * t.height / long)
    }

    /// Something landed nearby: dart away from it.
    func startle(from point: CGPoint) {
        guard !crossing else { return }
        let dx = Float(position.x - point.x), dy = Float(position.y - point.y)
        let dist = hypot(dx, dy)
        guard dist < 150, dist > 0.5 else { return }
        heading = atan2(dy, dx) + Float.random(in: -0.5...0.5)
        speed = (under ? 70 : 150) * (1.2 - dist / 150)
        restUntil = 0
    }

    func beginCrossing(in bounds: CGSize) {
        crossing = true
        started = true
        let fromLeft = Bool.random()
        position = CGPoint(x: fromLeft ? -40 : bounds.width + 40, y: CGFloat.random(in: 120...max(120, bounds.height * 0.6)))
        heading = fromLeft ? Float.random(in: -0.3...0.3) : Float.pi + Float.random(in: -0.3...0.3)
        speed = 120
    }

    func gone(in bounds: CGSize) -> Bool {
        position.x < -60 || position.x > bounds.width + 60 || position.y < -60 || position.y > bounds.height + 60
    }

    func update(dt: Float, now: TimeInterval, in bounds: CGSize) {
        if !started {
            started = true
            position = CGPoint(x: CGFloat.random(in: 60...max(60, bounds.width - 60)),
                               y: CGFloat.random(in: 140...max(140, bounds.height - 200)))
        }
        if crossing {
            heading += sin(Float(now) * 6) * 0.02
            position.x += CGFloat(cos(heading) * speed * dt)
            position.y += CGFloat(sin(heading) * speed * dt)
            return
        }
        if now > restUntil {
            if speed > 1 {
                speed = 0
                restUntil = now + Double.random(in: 1.2...4.0)
                if restUntil < 1 { restUntil = now + 1.5 }
            } else {
                heading += Float.random(in: -1.4...1.4)
                speed = slow ? Float.random(in: 14...22) : (under ? Float.random(in: 40...70) : Float.random(in: 90...150))
                restUntil = now + (slow ? Double.random(in: 2.5...5) : Double.random(in: 0.25...0.6))
            }
        }
        if speed > 1 {
            var nx = position.x + CGFloat(cos(heading) * speed * dt)
            var ny = position.y + CGFloat(sin(heading) * speed * dt)
            if nx < 40 || nx > bounds.width - 40 { heading = .pi - heading; nx = position.x }
            if ny < 120 || ny > bounds.height - 180 { heading = -heading; ny = position.y }
            position = CGPoint(x: nx, y: ny)
            speed *= exp(-dt * (slow ? 0.3 : 2.2))
        }
    }
}

/// A hazed cloud crossing high over the pond, throwing its shadow on the bed.
final class Cloud {
    let texture: String
    let width: CGFloat
    let aspect: CGFloat
    private(set) var position: CGPoint
    private let speed: CGFloat

    init(texture: String, seed: Int, size: CGSize) {
        self.texture = texture
        width = size.width * CGFloat.random(in: 0.8...1.3)
        aspect = CGFloat.random(in: 0.28...0.36)
        position = CGPoint(x: CGFloat(seed) * size.width * 0.7 - size.width * 0.3,
                           y: size.height * CGFloat.random(in: 0.1...0.8))
        speed = CGFloat.random(in: 5...9)
    }

    func update(dt: Float, in size: CGSize) {
        position.x += speed * CGFloat(dt)
        if position.x - width * 0.6 > size.width {
            position.x = -width * 0.6
            position.y = size.height * CGFloat.random(in: 0.1...0.8)
        }
    }
}


/// A dragonfly: it flies in, hovers over a spot with its wings a blur, darts
/// to another, and leaves. Body and wings are separate pieces; the wings
/// beat about their roots, drawn twice per beat so they smear like the
/// real thing does to the eye.
final class Dragonfly {
    let body: String
    private(set) var position: CGPoint
    private var heading: Float
    private var target: CGPoint
    private var hoverUntil: TimeInterval
    private var hops = 0
    private(set) var done = false
    private var bob: Float = 0
    private let startedAt: TimeInterval
    /// Where it touched the water, once per hover, drained by the garden.
    var dip: CGPoint?
    private var dipped = false
    /// A reed tip it has been asked to settle on, how high that is over the
    /// water, and whether it is sitting there with its wings folded.
    private(set) var perch: CGPoint?
    private var perchHeight: CGFloat = 0
    private(set) var landed = false
    /// 0 flying, 1 sat down: the wings fold and the hover bob dies with it.
    private var settle: Float = 0

    init(body: String, size: CGSize, now: TimeInterval) {
        self.body = body
        let fromLeft = Bool.random()
        position = CGPoint(x: fromLeft ? -50 : size.width + 50, y: CGFloat.random(in: 140...max(140, size.height * 0.55)))
        target = CGPoint(x: CGFloat.random(in: 80...max(80, size.width - 80)), y: CGFloat.random(in: 140...max(140, size.height * 0.6)))
        heading = atan2(Float(target.y - position.y), Float(target.x - position.x))
        hoverUntil = 0
        startedAt = now
    }

    var rotation: Float { heading + .pi / 2 }   // the body image points up

    /// Go and sit on this reed tip.
    func land(on tip: CGPoint, height: CGFloat) {
        perch = tip
        perchHeight = height
        target = tip
        hoverUntil = 0
    }

    /// Up off the reed and on with its round.
    func takeOff(in size: CGSize) {
        guard perch != nil else { return }
        perch = nil
        landed = false
        hoverUntil = 0
        target = CGPoint(x: CGFloat.random(in: 80...max(80, size.width - 80)), y: CGFloat.random(in: 140...max(140, size.height * 0.6)))
    }

    func update(dt: Float, now: TimeInterval, in size: CGSize) {
        bob += dt
        let dx = Float(target.x - position.x), dy = Float(target.y - position.y)
        let dist = hypot(dx, dy)
        settle += ((landed ? 1 : 0) - settle) * min(1, dt * 3)
        if let tip = perch {
            if landed {
                // Sat on the tip, and the tip sways under it a little.
                position = CGPoint(x: tip.x + CGFloat(sin(bob * 0.9)) * 0.6, y: tip.y)
                return
            }
            if dist < 4 {
                landed = true
                position = tip
                return
            }
            // The last of the way in is slow, a settle rather than a dart.
            let want = atan2(dy, dx)
            var diff = want - heading
            while diff > .pi { diff -= 2 * .pi }
            while diff < -.pi { diff += 2 * .pi }
            heading += max(-4 * dt, min(4 * dt, diff))
            let speed = min(200, 14 + dist * 1.6)
            position.x += CGFloat(cos(heading) * speed * dt)
            position.y += CGFloat(sin(heading) * speed * dt)
            return
        }
        if dist < 6 {
            if hoverUntil == 0 {
                hoverUntil = now + Double.random(in: 1.5...3.0)
                dipped = false
            }
            // It drops onto the water for an instant before it goes.
            if !dipped, now > hoverUntil - 0.4 {
                dipped = true
                dip = position
            }
            if now > hoverUntil {
                hops += 1
                hoverUntil = 0
                if hops >= 2 {
                    target = CGPoint(x: position.x < size.width / 2 ? -80 : size.width + 80, y: position.y + CGFloat.random(in: -80...80))
                } else {
                    target = CGPoint(x: CGFloat.random(in: 80...max(80, size.width - 80)), y: CGFloat.random(in: 140...max(140, size.height * 0.6)))
                }
            }
            // Hovering: a tiny drift, the heading holds.
            position.x += CGFloat(sin(bob * 1.7)) * 0.25
            position.y += CGFloat(cos(bob * 1.3)) * 0.2
        } else {
            let want = atan2(dy, dx)
            var diff = want - heading
            while diff > .pi { diff -= 2 * .pi }
            while diff < -.pi { diff += 2 * .pi }
            heading += max(-4 * dt, min(4 * dt, diff))
            // Darts are quick and ease out as the spot nears.
            let speed = min(260, 40 + dist * 2.2)
            position.x += CGFloat(cos(heading) * speed * dt)
            position.y += CGFloat(sin(heading) * speed * dt)
        }
        if hops >= 2, position.x < -60 || position.x > size.width + 60 { done = true }
    }

    func sprites(_ textureSize: (String) -> CGSize) -> [Sprite] {
        let bodyTex = textureSize(body)
        let bodyH: CGFloat = 52
        let bodyW = bodyH * bodyTex.width / max(1, bodyTex.height)
        let wingTex = textureSize("dragonfly_wing")
        let wingL: CGFloat = 34
        let wingH = wingL * wingTex.height / max(1, wingTex.width)
        let hover = CGFloat(sin(bob * 2.1)) * 2.0 * CGFloat(1 - settle)
        let at = CGPoint(x: position.x, y: position.y + hover)
        // Flying it is drawn well over the water; sat on a reed it is at
        // the tip's height, and its shadow falls that much farther off.
        let lift: Float = 0.6 * (1 - settle) + Float(perchHeight) / WaterRenderer.depthScale * settle
        let r = rotation
        let cs = CGFloat(cos(r)), sn = CGFloat(sin(r))
        // Wing roots sit a little below the head on either side of the thorax.
        func place(_ local: CGPoint) -> CGPoint {
            CGPoint(x: at.x + local.x * cs - local.y * sn, y: at.y + local.x * sn + local.y * cs)
        }
        var out: [Sprite] = []
        // Sat down, the wings stop and lie back along the body.
        let beat = sin(bob * 52) * 0.45 * (1 - settle)
        let fold = settle * 0.55
        let shadowOffset = CGPoint(x: 12 * CGFloat(lift / 0.6), y: 36 * CGFloat(lift / 0.6))
        // Shadow of body and wings on the water.
        out.append(Sprite(body, at: CGPoint(x: at.x + shadowOffset.x, y: at.y + shadowOffset.y),
                          size: CGSize(width: bodyW, height: bodyH), rotation: r, mode: .shadow, alpha: 0.45, z: 0))
        for (side, pairY) in [(CGFloat(1), CGFloat(-9)), (CGFloat(-1), CGFloat(-9)), (CGFloat(1), CGFloat(-2)), (CGFloat(-1), CGFloat(-2))] {
            let root = place(CGPoint(x: side * bodyW * 0.18, y: pairY))
            let base: Float = side > 0 ? fold : .pi - fold
            let flap = Float(pairY == -9 ? beat : -beat)
            // Two ghosts per wing for the blur, plus the wing itself. The
            // ghosts fade as the wings come to rest.
            for (k, a) in [(-0.6, 0.25 * (1 - settle)), (0.6, 0.25 * (1 - settle)), (0.0, 0.7 + 0.25 * settle)] {
                guard a > 0.01 else { continue }
                let ang = base + flap * Float(1 + k)
                let centre = CGPoint(x: root.x + CGFloat(cos(r + ang)) * wingL * 0.5, y: root.y + CGFloat(sin(r + ang)) * wingL * 0.5)
                out.append(Sprite("dragonfly_wing", at: centre, size: CGSize(width: wingL, height: wingH),
                                  rotation: r + ang, alpha: Float(a), flipX: side < 0, z: lift))
            }
        }
        out.append(Sprite(body, at: at, size: CGSize(width: bodyW, height: bodyH), rotation: r, alpha: 1, z: lift))
        return out
    }
}


/// A stone, a patch of gravel or sand, lying on the bed at its own depth.
struct BedPiece {
    let texture: String
    let position: CGPoint
    let size: CGFloat
    let rotation: Float
    let z: Float
    let depth: Float
}

/// A tuft of reeds standing in the shallows. A gust leans it over; the stem
/// is a spring that stands it back up.
struct Reed {
    let texture: String
    let position: CGPoint
    let size: CGFloat
    let rotation: Float
    let phase: Float
    var sway: Float = 0
    var swayVel: Float = 0
}

/// A frog on a lily pad near the bank. It turns its head now and then, and
/// a tap nearby sends it into the water; it climbs back out later.
final class Frog {
    let texture: String
    let pad: String
    private(set) var padPosition: CGPoint
    private(set) var padRotation: Float
    private(set) var position: CGPoint
    private(set) var rotation: Float
    private(set) var onPad = true
    var justJumped = false
    private var nextTurnAt: TimeInterval = 0
    private var returnAt: TimeInterval = 0

    init(texture: String, pad: String, size: CGSize) {
        self.texture = texture
        self.pad = pad
        padPosition = CGPoint(x: Bool.random() ? 52 : size.width - 52, y: size.height * CGFloat.random(in: 0.55...0.8))
        padRotation = Float.random(in: 0...(2 * .pi))
        position = CGPoint(x: padPosition.x, y: padPosition.y - 4)
        rotation = Float.random(in: -0.6...0.6)
    }

    func update(dt: Float, now: TimeInterval) {
        if onPad {
            if now > nextTurnAt {
                rotation += Float.random(in: -0.5...0.5)
                nextTurnAt = now + Double.random(in: 3...9)
            }
        } else if now > returnAt {
            onPad = true
            rotation = Float.random(in: -0.6...0.6)
        }
    }

    func startle(from point: CGPoint, now: TimeInterval) {
        guard onPad, hypot(position.x - point.x, position.y - point.y) < 120 else { return }
        onPad = false
        justJumped = true
        returnAt = now + Double.random(in: 8...16)
    }
}

/// A heron passing high over the pond. We only ever see its shadow.
final class Heron {
    let texture = "heron_shadow"
    let width: CGFloat
    let aspect: CGFloat = 0.5
    private(set) var position: CGPoint
    private(set) var rotation: Float
    private let velocity: CGVector
    private(set) var done = false
    private var beat: Float = 0

    init(size: CGSize) {
        width = size.width * 1.1
        let fromLeft = Bool.random()
        position = CGPoint(x: fromLeft ? -size.width * 0.8 : size.width * 1.8, y: CGFloat.random(in: 160...max(160, size.height - 200)))
        let dir: CGFloat = fromLeft ? 1 : -1
        velocity = CGVector(dx: dir * CGFloat.random(in: 110...150), dy: CGFloat.random(in: -25...25))
        rotation = Float(atan2(velocity.dy, velocity.dx)) + (fromLeft ? 0 : .pi) + (fromLeft ? 0 : 0)
    }

    func update(dt: Float, in size: CGSize) {
        position.x += velocity.dx * CGFloat(dt)
        position.y += velocity.dy * CGFloat(dt)
        beat += dt * 3.5
        if position.x < -size.width || position.x > size.width * 2 { done = true }
    }
}


/// A speck drifting in the water column.
/// A shoal of small fish: boids. Each fish keeps near its neighbours, swims
/// the way they swim, keeps its distance, and follows a wander point the
/// whole shoal shares; a tap or a passing koi scatters them, and they close
/// up again. Nothing is scripted, so no two moments look alike.
final class Shoal {
    final class Fish {
        var position: CGPoint
        var velocity: SIMD2<Float>
        var heading: Float
        var phase: Float
        let length: CGFloat
        init(position: CGPoint, velocity: SIMD2<Float>, length: CGFloat, phase: Float) {
            self.position = position
            self.velocity = velocity
            self.heading = atan2(velocity.y, velocity.x)
            self.phase = phase
            self.length = length
        }
    }

    let texture: String
    private(set) var fish: [Fish] = []
    /// How deep the shoal swims, 0 surface to 1 bed.
    let depth: Float
    private var wander: CGPoint
    private var wanderUntil: TimeInterval = 0
    private var fright: Float = 0
    private let cruise: Float
    private let seed: Int
    /// A wake the shoal is streaming along: the line, how far along it the
    /// leader has got, who leads, and until when.
    private var path: [CGPoint] = []
    private var pathIndex = 0
    private var leader: Fish?
    private var followUntil: TimeInterval = 0

    /// The middle of the shoal; nil with no fish.
    var centroid: CGPoint? {
        guard !fish.isEmpty else { return nil }
        var x: CGFloat = 0, y: CGFloat = 0
        for f in fish { x += f.position.x; y += f.position.y }
        return CGPoint(x: x / CGFloat(fish.count), y: y / CGFloat(fish.count))
    }

    /// A wake laid across the water. The far end becomes where the shoal is
    /// going for five seconds, and the fish nearest the start leads the rest
    /// along it point by point; the others keep station on the leader the
    /// way they always do.
    /// Water the shoal keeps to (y beyond this line) until it is led away.
    private var penLine: CGFloat?

    func pen(below y: CGFloat?, in size: CGSize) {
        penLine = y
        guard let y, let c = centroid, c.y < y + 40 else { return }
        // The pond is new: the shoal starts inside its pocket, unseen.
        let centre = CGPoint(x: size.width * CGFloat.random(in: 0.3...0.7),
                             y: min(size.height * 0.85, y + CGFloat.random(in: 120...220)))
        for f in fish {
            f.position = CGPoint(x: centre.x + CGFloat.random(in: -40...40), y: centre.y + CGFloat.random(in: -40...40))
        }
        wander = centre
        wanderUntil = 0
    }

    func follow(path: [CGPoint], now: TimeInterval) {
        guard let start = path.first, let end = path.last, !fish.isEmpty else { return }
        wander = end
        wanderUntil = now + 8
        followUntil = now + 8
        self.path = path
        pathIndex = 0
        leader = fish.min { a, b in
            hypot(a.position.x - start.x, a.position.y - start.y) < hypot(b.position.x - start.x, b.position.y - start.y)
        }
    }

    /// `centre` is where the shoal starts; left nil it starts somewhere in
    /// the middle of the pond.
    init(texture: String, count: Int, size: CGSize, seed: Int, centre start: CGPoint? = nil) {
        self.texture = texture
        self.seed = seed
        depth = [0.35, 0.5, 0.42][seed % 3]
        cruise = [46, 38, 54][seed % 3]
        let centre = start ?? CGPoint(x: size.width * CGFloat.random(in: 0.25...0.75), y: size.height * CGFloat.random(in: 0.25...0.75))
        wander = centre
        let a = Float.random(in: 0...(2 * .pi))
        fish = (0..<count).map { _ in
            Fish(position: CGPoint(x: centre.x + CGFloat.random(in: -40...40), y: centre.y + CGFloat.random(in: -40...40)),
                 velocity: SIMD2(cos(a), sin(a)) * cruise + SIMD2(Float.random(in: -8...8), Float.random(in: -8...8)),
                 length: CGFloat.random(in: 24...36) * [1.0, 0.85, 1.2][seed % 3],
                 phase: Float.random(in: 0...(2 * .pi)))
        }
    }

    func startle(from point: CGPoint) {
        for f in fish {
            let dx = Float(f.position.x - point.x), dy = Float(f.position.y - point.y)
            let d = max(1, (dx * dx + dy * dy).squareRoot())
            guard d < 220 else { continue }
            let away = SIMD2(dx, dy) / d
            f.velocity += away * (1 - d / 220) * 180
        }
        fright = 1
    }

    /// `water` is the pond's depth at a point when there is ground the
    /// shoal must keep off (the plot); nil in a level's bowl.
    func update(dt: Float, now: TimeInterval, in size: CGSize, rocks: [(centre: CGPoint, radius: CGFloat)], koi: [CGPoint],
                water: ((CGPoint) -> Float)? = nil) {
        if now > wanderUntil {
            // Penned, the shoal wanders only its own pocket. Over ground,
            // only a point with water under it will do; failing a dozen
            // tries the shoal keeps to where it is.
            let top = penLine.map { min(0.8, ($0 + 60) / size.height) } ?? 0.18
            var pick: CGPoint?
            for _ in 0..<12 {
                let c = CGPoint(x: size.width * CGFloat.random(in: 0.18...0.82), y: size.height * CGFloat.random(in: top...0.82))
                if let water, water(c) <= 0.35 { continue }
                pick = c
                break
            }
            wander = pick ?? centroid ?? wander
            wanderUntil = now + Double.random(in: 6...14)
        }
        let penned = now >= followUntil ? penLine : nil
        fright *= exp(-dt * 0.9)
        let n = fish.count
        guard n > 0 else { return }
        // The leader, while the wake still holds: it moves on to the next
        // point of the line as it reaches each one, and is done at the end.
        var leading: Fish?
        if now < followUntil, let l = leader {
            while pathIndex < path.count,
                  hypot(l.position.x - path[pathIndex].x, l.position.y - path[pathIndex].y) < 26 {
                pathIndex += 1
            }
            if pathIndex < path.count { leading = l } else { followUntil = 0 }
        }
        let neighbour: Float = 80
        for i in 0..<n {
            let f = fish[i]
            // A fish wants a body length of clear water round it.
            let tooClose = Float(f.length) * 0.95
            var centre = SIMD2<Float>(0, 0), align = SIMD2<Float>(0, 0), apart = SIMD2<Float>(0, 0)
            var count: Float = 0
            let p = SIMD2(Float(f.position.x), Float(f.position.y))
            for j in 0..<n where j != i {
                let g = fish[j]
                let q = SIMD2(Float(g.position.x), Float(g.position.y))
                let d = simd_length(q - p)
                guard d < neighbour else { continue }
                centre += q
                align += g.velocity
                count += 1
                if d < tooClose { apart -= (q - p) / max(0.5, d) * (tooClose - d) }
            }
            var steer = SIMD2<Float>(0, 0)
            let leads = f === leading
            if count > 0 {
                // The leader is pulled less by the others: it is the one
                // going somewhere, and they close on it.
                steer += (centre / count - p) * (leads ? 0.2 : 0.8)
                steer += (align / count - f.velocity) * (leads ? 0.5 : 1.4)
            }
            steer += apart * 22
            if leads {
                // Along the wake, point to point, with real pull.
                let goal = SIMD2(Float(path[pathIndex].x), Float(path[pathIndex].y))
                let to = goal - p
                let d = simd_length(to)
                if d > 0.5 { steer += to / d * 110 }
            } else {
                // The wander point pulls gently; it is where the shoal is going.
                let w = SIMD2(Float(wander.x), Float(wander.y))
                steer += (w - p) * 0.25
            }
            // Banks, stones and the koi are kept clear of.
            let margin: Float = 50
            if p.x < margin { steer.x += (margin - p.x) * 3 }
            if p.y < margin { steer.y += (margin - p.y) * 3 }
            // The pen's line is a bank to a shoal that has not been led out.
            if let pen = penned, p.y < Float(pen) + margin { steer.y += (Float(pen) + margin - p.y) * 3 }
            if p.x > Float(size.width) - margin { steer.x -= (p.x - (Float(size.width) - margin)) * 3 }
            if p.y > Float(size.height) - margin { steer.y -= (p.y - (Float(size.height) - margin)) * 3 }
            for r in rocks {
                let c = SIMD2(Float(r.centre.x), Float(r.centre.y))
                let d = simd_length(p - c), keep = Float(r.radius) + 30
                if d < keep { steer += (p - c) / max(1, d) * (keep - d) * 6 }
            }
            for k in koi {
                let c = SIMD2(Float(k.x), Float(k.y))
                let d = simd_length(p - c)
                if d < 110 { steer += (p - c) / max(1, d) * (110 - d) * 2.5 }
            }
            // The plot: ground ahead is steered round toward whichever side
            // has more water, the near reading harder than the far; a fish
            // over the earth is pulled hard to the nearest water.
            if let water {
                if water(f.position) < 0.15 {
                    if let w = nearestWaterPoint(from: f.position, water: water) {
                        let to = SIMD2(Float(w.x), Float(w.y)) - p
                        let d = simd_length(to)
                        if d > 0.5 { steer += to / d * 320 }
                    }
                } else {
                    let sp = simd_length(f.velocity)
                    let dir = sp > 0.5 ? f.velocity / sp : SIMD2(cos(f.heading), sin(f.heading))
                    for (reach, gain) in [(Float(60), Float(260)), (120, 120)] {
                        let q = CGPoint(x: f.position.x + CGFloat(dir.x * reach), y: f.position.y + CGFloat(dir.y * reach))
                        guard water(q) < 0.25 else { continue }
                        let a = atan2(dir.y, dir.x)
                        let dl = SIMD2(cos(a - 0.9), sin(a - 0.9)), dr = SIMD2(cos(a + 0.9), sin(a + 0.9))
                        let l = CGPoint(x: f.position.x + CGFloat(dl.x * reach), y: f.position.y + CGFloat(dl.y * reach))
                        let r = CGPoint(x: f.position.x + CGFloat(dr.x * reach), y: f.position.y + CGFloat(dr.y * reach))
                        steer += (water(l) >= water(r) ? dl : dr) * gain
                        break
                    }
                }
            }
            f.velocity += steer * dt
            // Hold the cruising speed, faster while frightened, and with a
            // little more on while the shoal is streaming after a wake.
            let want = cruise * (1 + fright * 1.6) * (leads ? 1.35 : (leading != nil ? 1.15 : 1))
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

final class Mote {
    private(set) var position: CGPoint
    let z: Float
    let size: CGFloat
    let alpha: Float
    private var drift: CGVector
    private var phase: Float

    init(size bounds: CGSize) {
        position = CGPoint(x: CGFloat.random(in: 0...bounds.width), y: CGFloat.random(in: 0...bounds.height))
        z = Float.random(in: -0.95...(-0.08))
        size = CGFloat.random(in: 2.5...5.5)
        alpha = Float.random(in: 0.25...0.6)
        drift = CGVector(dx: CGFloat.random(in: -4...4), dy: CGFloat.random(in: -3...3))
        phase = Float.random(in: 0...(2 * .pi))
    }

    func update(dt: Float, in bounds: CGSize) {
        phase += dt * 0.6
        position.x += (drift.dx + CGFloat(sin(phase)) * 3) * CGFloat(dt)
        position.y += (drift.dy + CGFloat(cos(phase * 0.8)) * 2) * CGFloat(dt)
        if position.x < -10 { position.x = bounds.width + 10 }
        if position.x > bounds.width + 10 { position.x = -10 }
        if position.y < -10 { position.y = bounds.height + 10 }
        if position.y > bounds.height + 10 { position.y = -10 }
    }
}
