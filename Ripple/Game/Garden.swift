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
    /// The bowl depth at a point, 0...1 (1 deep), set by the controller.
    var depthAt: (CGPoint) -> Float = { _ in 1 }
    /// How much of the pond is still under ice, 0...1. The koi stay deep
    /// until the water opens.
    var iceCover: Float = 0

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
        for k in koi { k.startle(from: point, now: time) }
        frog?.startle(from: point, now: time)
        newt?.startle(from: point)
    }

    /// Pixel size of a named texture, for keeping aspect; set by the controller.
    var textureSize: (String) -> CGSize = { _ in CGSize(width: 1, height: 1) }

    func configure(art: ArtSet, size: CGSize, bloomStage: Float) {
        self.art = art
        self.size = size
        self.bloomStage = bloomStage
        bloomTarget = bloomStage
        bloomRate = 0
        petals = []
        petalRate = 0
        koi = (0..<min(2, art.koi.count)).map { i in
            Koi(texture: art.koi[i], forward: art.koiForward[i % art.koiForward.count], seed: i,
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
        buildBed()
        buildShore()
        frog = art.frog.map { Frog(texture: $0.frog, pad: $0.pad, size: size) }
        newt = art.newt.map { Critter(texture: $0, forward: -.pi / 2, size: 34, seed: 3, under: true, slow: true) }
        shoals = art.shoal.enumerated().map { i, name in
            Shoal(texture: name, count: 10 + i * 4, size: size, seed: i)
        }
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
                    p = CGPoint(x: CGFloat.random(in: 10...(w - 10), using: &rng), y: CGFloat.random(in: 60...(h - 40), using: &rng))
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
        for name in art.gravel { drop(name, sizePt: 84, count: 1, rimBias: 0.7) }
        for (i, name) in art.stones.enumerated() {
            drop(name, sizePt: i < 3 ? 78 : 46, count: i < 3 ? 2 : 3, rimBias: 0.85)
        }
        // Draw order: deep and large first, so nearer things overlap.
        bedPieces.sort { $0.z < $1.z }
    }

    /// Reed tufts stand in the shallows at the banks, breaking the surface.
    private func buildShore() {
        reeds = []
        guard !art.reeds.isEmpty else { return }
        var rng = SystemRandomNumberGenerator()
        let w = size.width, h = size.height
        let spots: [CGPoint] = [
            CGPoint(x: 22, y: h * 0.58), CGPoint(x: 34, y: h * 0.84), CGPoint(x: w - 30, y: h * 0.70),
            CGPoint(x: w - 20, y: h * 0.40), CGPoint(x: w * 0.28, y: h - 26), CGPoint(x: w * 0.70, y: h - 34),
            CGPoint(x: w * 0.12, y: 40), CGPoint(x: w * 0.86, y: 52),
        ]
        for (i, spot) in spots.enumerated() {
            let count = Int.random(in: 1...2, using: &rng)
            for k in 0..<count {
                reeds.append(Reed(texture: art.reeds[(i + k) % art.reeds.count],
                                  position: CGPoint(x: spot.x + CGFloat.random(in: -30...30, using: &rng),
                                                    y: spot.y + CGFloat.random(in: -14...14, using: &rng)),
                                  size: CGFloat.random(in: 60...100, using: &rng),
                                  rotation: Float.random(in: -0.4...0.4, using: &rng) - .pi / 2,
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
        koi.first { $0.depth < 0.5 && hypot($0.position.x - point.x, $0.position.y - point.y) < 46 }
    }

    func dive(_ k: Koi) {
        k.dive(now: time, quick: true)
        splashes.append((k.position, 16, -0.32))
    }

    // MARK: - Per frame

    func update(dt: Float, now: TimeInterval) {
        time = now
        guard size.width > 0 else { return }

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

        for c in critters { c.update(dt: dt, now: now, in: size) }
        for s in shoals { s.update(dt: dt, now: now, in: size, rocks: rocks, koi: koi.map(\.position)) }
        for c in clouds { c.update(dt: dt, in: size) }
        if let f = dragonfly {
            f.update(dt: dt, now: now, in: size)
            if f.done { dragonfly = nil; nextFlyerAt = now + Double.random(in: 25...50) }
        } else if now > nextFlyerAt, let name = art.flyers.first {
            dragonfly = Dragonfly(body: name, size: size, now: now)
        }
        for m in motes { m.update(dt: dt, in: size) }
        frog?.update(dt: dt, now: now)
        if let f = frog, f.justJumped {
            splashes.append((f.position, 14, -0.30))
            f.justJumped = false
        }
        newt?.update(dt: dt, now: now, in: size)
        // (The heron's shadow was cut: a flat silhouette sliding over the pond
        // read as a decal, not a bird. It will come back only with wings that beat.)
        // A surfaced koi mouths at the surface now and then: a small ring.
        for k in koi where k.depth < 0.2 && Float.random(in: 0...1) < dt * 0.18 {
            splashes.append((k.headPoint, 7, -0.09))
        }

        if bloomRate > 0 {
            bloomStage = min(bloomTarget, bloomStage + bloomRate * dt)
            if bloomStage >= bloomTarget { bloomRate = 0 }
        }

        for k in koi {
            k.iceOver = iceCover
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
        }

        if petalRate > 0 {
            if now > petalUntil { petalRate = 0 }
            petalAccumulator += petalRate * dt
            while petalAccumulator >= 1, petals.count < 80 {
                petalAccumulator -= 1
                petals.append(FallingPetal(x: CGFloat.random(in: 0...size.width),
                                           y: -20, texture: art.petalParticle))
            }
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
            let pale = piece.texture.hasPrefix("sand") || piece.texture.hasPrefix("gravel")
            out.append(Sprite(piece.texture, at: piece.position, size: sz, rotation: piece.rotation,
                              mode: .submerged, alpha: pale ? 0.85 : 1, depth: 0.3 + piece.depth * 0.5,
                              tint: pale ? [0.62, 0.66, 0.62, 1] : [1, 1, 1, 1], z: piece.z))
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
        for k in koi where k.depth < 0.98 {
            let d = k.depth
            let w = k.width
            let h = w * k.aspect
            let index = spines.count / 13
            spines += k.spine(length: h)
            let offset = CGFloat(10 + 26 * d)
            let z = -0.2 - 0.7 * d
            out.append(Sprite(k.texture, at: CGPoint(x: offset * 0.6, y: offset),
                              size: CGSize(width: w, height: h), mode: .shadow,
                              alpha: 0.7 * (1 - d * 0.6), wave: k.phase, waveAmp: k.waveAmp, spine: index, z: -1.0))
            out.append(Sprite(k.texture, at: .zero, size: CGSize(width: w, height: h),
                              mode: .submerged, alpha: 1, depth: d,
                              wave: k.phase, waveAmp: k.waveAmp, tint: [1, 1, 1, k.roll], spine: index, z: z))
        }
        return (out, spines)
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
            out.append(Sprite(r.texture, at: r.position, size: sz, rotation: r.rotation, alpha: 1,
                              wave: Float(time) * 0.9 + r.phase, z: 0, stands: true))
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

    /// The frame: branches at the top corners and the bank along the bottom.
    func floraSprites() -> [Sprite] {
        guard size.width > 0 else { return [] }
        var out: [Sprite] = []
        let w = size.width
        let stage = bloomStage
        let lo = Int(floor(stage)), hi = min(3, lo + 1)
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
    let width: CGFloat = 74
    let aspect: CGFloat
    private(set) var position = CGPoint.zero
    private(set) var heading: Float
    private(set) var depth: Float = 1
    private(set) var phase: Float = 0
    /// How far the fish is banked into its turn, -1...1, eased.
    private(set) var roll: Float = 0
    /// Ice cover over the pond; above a half the fish will not surface.
    var iceOver: Float = 0
    private var target = CGPoint.zero
    private var speed: CGFloat = 34
    private var stateUntil: TimeInterval
    private var depthTarget: Float = 1
    private var depthRate: Float = 0.5
    private var started = false
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
            position = CGPoint(x: CGFloat.random(in: 80...(size.width - 80)),
                               y: CGFloat.random(in: 140...(size.height - 160)))
            pickTarget(in: size)
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

        let dx = Float(target.x - position.x), dy = Float(target.y - position.y)
        if hypot(dx, dy) < 30 { pickTarget(in: size) }
        var want = atan2(dy, dx)
        if Koi.diagnostics, Int(now * 2) != Int((now - Double(dt)) * 2) {
            var d0 = want - heading
            while d0 > .pi { d0 -= 2 * .pi }
            while d0 < -.pi { d0 += 2 * .pi }
            NSLog("[koi %@] pos=(%.0f,%.0f) speed=%.1f diff=%.2f depth=%.2f dist=%.0f", texture, position.x, position.y, Float(speed), d0, depth, hypot(dx, dy))
        }
        // A bank ahead bends the wish away from it, well before it is reached,
        // so the fish sweeps round in open water instead of nosing the edge.
        do {
            let margin: Float = 170
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
        let fleeing = now < fleeUntil
        if speed > 46 { speed -= CGFloat(dt) * (fleeing ? 20 : 45) }
        // A fish that has to turn hard puts on a little speed to do it, so
        // the turn is a tail-flick sweep rather than a crawl.
        if abs(diff) > 1.0, speed < 40 { speed += CGFloat(dt) * 30 }
        let s = Float(speed) * (depth > 0.9 ? 0.5 : 1) * (1 - 0.15 * min(1, abs(diff)))
        let maxRate = min(fleeing ? 1.6 : 0.55, max(0.32, s / (Float(width) * 1.1)))
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

    private func pickTarget(in size: CGSize) {
        // Somewhere ahead and far: a fish cruises in long arcs, it does not
        // dither or double back. If nothing ahead is open water (it is up
        // against a bank), it sweeps round in a wide arc to the side.
        var best: CGPoint?
        var bestScore: Float = -1
        for _ in 0..<16 {
            let candidate = CGPoint(x: CGFloat.random(in: 90...(size.width - 90)),
                                    y: CGFloat.random(in: 150...(size.height - 170)))
            let dx = Float(candidate.x - position.x), dy = Float(candidate.y - position.y)
            let dist = hypot(dx, dy)
            var diff = atan2(dy, dx) - heading
            while diff > .pi { diff -= 2 * .pi }
            while diff < -.pi { diff += 2 * .pi }
            guard dist > 200, abs(diff) < 1.1 else { continue }
            let score = dist * (1.2 - abs(diff))
            if score > bestScore { bestScore = score; best = candidate }
        }
        if let b = best {
            target = b
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
            position = CGPoint(x: CGFloat.random(in: 80...(size.width - 80)),
                               y: CGFloat.random(in: 140...(size.height - 160)))
            pickTarget(in: size)
            heading = atan2(Float(target.y - position.y), Float(target.x - position.x))
            straightTrail()
        }
        depthTarget = 0.12
        stateUntil = now + Double.random(in: 10...18)
    }

    func dive(now: TimeInterval, quick: Bool) {
        depthTarget = 1
        depthRate = quick ? 1.4 : 0.45
        if quick { speed = 70 }
        stateUntil = now + Double.random(in: quick ? 6...11 : 4...9)
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
        position = CGPoint(x: fromLeft ? -40 : bounds.width + 40, y: CGFloat.random(in: 120...(bounds.height * 0.6)))
        heading = fromLeft ? Float.random(in: -0.3...0.3) : Float.pi + Float.random(in: -0.3...0.3)
        speed = 120
    }

    func gone(in bounds: CGSize) -> Bool {
        position.x < -60 || position.x > bounds.width + 60 || position.y < -60 || position.y > bounds.height + 60
    }

    func update(dt: Float, now: TimeInterval, in bounds: CGSize) {
        if !started {
            started = true
            position = CGPoint(x: CGFloat.random(in: 60...(bounds.width - 60)),
                               y: CGFloat.random(in: 140...(bounds.height - 200)))
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

    init(body: String, size: CGSize, now: TimeInterval) {
        self.body = body
        let fromLeft = Bool.random()
        position = CGPoint(x: fromLeft ? -50 : size.width + 50, y: CGFloat.random(in: 140...(size.height * 0.55)))
        target = CGPoint(x: CGFloat.random(in: 80...(size.width - 80)), y: CGFloat.random(in: 140...(size.height * 0.6)))
        heading = atan2(Float(target.y - position.y), Float(target.x - position.x))
        hoverUntil = 0
        startedAt = now
    }

    var rotation: Float { heading + .pi / 2 }   // the body image points up

    func update(dt: Float, now: TimeInterval, in size: CGSize) {
        bob += dt
        let dx = Float(target.x - position.x), dy = Float(target.y - position.y)
        let dist = hypot(dx, dy)
        if dist < 6 {
            if hoverUntil == 0 { hoverUntil = now + Double.random(in: 1.5...3.0) }
            if now > hoverUntil {
                hops += 1
                hoverUntil = 0
                if hops >= 2 {
                    target = CGPoint(x: position.x < size.width / 2 ? -80 : size.width + 80, y: position.y + CGFloat.random(in: -80...80))
                } else {
                    target = CGPoint(x: CGFloat.random(in: 80...(size.width - 80)), y: CGFloat.random(in: 140...(size.height * 0.6)))
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
        let hover = CGFloat(sin(bob * 2.1)) * 2.0
        let at = CGPoint(x: position.x, y: position.y + hover)
        let r = rotation
        let cs = CGFloat(cos(r)), sn = CGFloat(sin(r))
        // Wing roots sit a little below the head on either side of the thorax.
        func place(_ local: CGPoint) -> CGPoint {
            CGPoint(x: at.x + local.x * cs - local.y * sn, y: at.y + local.x * sn + local.y * cs)
        }
        var out: [Sprite] = []
        let beat = sin(bob * 52) * 0.45
        let shadowOffset = CGPoint(x: 12, y: 36)
        // Shadow of body and wings on the water.
        out.append(Sprite(body, at: CGPoint(x: at.x + shadowOffset.x, y: at.y + shadowOffset.y),
                          size: CGSize(width: bodyW, height: bodyH), rotation: r, mode: .shadow, alpha: 0.45, z: 0))
        for (side, pairY) in [(CGFloat(1), CGFloat(-9)), (CGFloat(-1), CGFloat(-9)), (CGFloat(1), CGFloat(-2)), (CGFloat(-1), CGFloat(-2))] {
            let root = place(CGPoint(x: side * bodyW * 0.18, y: pairY))
            let base: Float = side > 0 ? 0 : .pi
            let flap = Float(pairY == -9 ? beat : -beat)
            // Two ghosts per wing for the blur, plus the wing itself.
            for (k, a) in [(-0.6, 0.25), (0.6, 0.25), (0.0, 0.7)] {
                let ang = base + flap * Float(1 + k)
                let centre = CGPoint(x: root.x + CGFloat(cos(r + ang)) * wingL * 0.5, y: root.y + CGFloat(sin(r + ang)) * wingL * 0.5)
                out.append(Sprite("dragonfly_wing", at: centre, size: CGSize(width: wingL, height: wingH),
                                  rotation: r + ang, alpha: Float(a), flipX: side < 0, z: 0.6))
            }
        }
        out.append(Sprite(body, at: at, size: CGSize(width: bodyW, height: bodyH), rotation: r, alpha: 1, z: 0.6))
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

/// A tuft of reeds standing in the shallows.
struct Reed {
    let texture: String
    let position: CGPoint
    let size: CGFloat
    let rotation: Float
    let phase: Float
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
        position = CGPoint(x: fromLeft ? -size.width * 0.8 : size.width * 1.8, y: CGFloat.random(in: 160...(size.height - 200)))
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

    init(texture: String, count: Int, size: CGSize, seed: Int) {
        self.texture = texture
        self.seed = seed
        depth = [0.35, 0.5, 0.42][seed % 3]
        cruise = [46, 38, 54][seed % 3]
        let centre = CGPoint(x: size.width * CGFloat.random(in: 0.25...0.75), y: size.height * CGFloat.random(in: 0.25...0.75))
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

    func update(dt: Float, now: TimeInterval, in size: CGSize, rocks: [(centre: CGPoint, radius: CGFloat)], koi: [CGPoint]) {
        if now > wanderUntil {
            wander = CGPoint(x: size.width * CGFloat.random(in: 0.18...0.82), y: size.height * CGFloat.random(in: 0.18...0.82))
            wanderUntil = now + Double.random(in: 6...14)
        }
        fright *= exp(-dt * 0.9)
        let n = fish.count
        guard n > 0 else { return }
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
            if count > 0 {
                steer += (centre / count - p) * 0.8
                steer += (align / count - f.velocity) * 1.4
            }
            steer += apart * 22
            // The wander point pulls gently; it is where the shoal is going.
            let w = SIMD2(Float(wander.x), Float(wander.y))
            steer += (w - p) * 0.25
            // Banks, stones and the koi are kept clear of.
            let margin: Float = 50
            if p.x < margin { steer.x += (margin - p.x) * 3 }
            if p.y < margin { steer.y += (margin - p.y) * 3 }
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
            f.velocity += steer * dt
            // Hold the cruising speed, faster while frightened.
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
