import CoreGraphics
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

    /// The camera's slow breath, in points. Read by the controller each frame.
    private(set) var drift = SIMD2<Float>(0, 0)
    private var weeds: [Weed] = []
    private var critters: [Critter] = []
    private var clouds: [Cloud] = []
    private var flyer: Critter?
    private var nextFlyerAt: TimeInterval = 0

    init(art: ArtSet) {
        self.art = art
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
                for k in 0..<Int.random(in: 2...4, using: &rng) {
                    let name = art.weeds[(c + k) % art.weeds.count]
                    weeds.append(Weed(texture: name,
                                      root: CGPoint(x: root.x + CGFloat.random(in: -16...16, using: &rng),
                                                    y: root.y + CGFloat.random(in: -10...10, using: &rng)),
                                      height: CGFloat.random(in: 120...200, using: &rng),
                                      lean: Float.random(in: -0.35...0.35, using: &rng),
                                      phase: Float.random(in: 0...(2 * .pi), using: &rng),
                                      depth: Float.random(in: 0.2...0.45, using: &rng)))
                }
            }
        }
        critters = art.under.enumerated().map { i, name in
            Critter(texture: name, forward: [-.pi / 2, .pi, .pi][i % 3], size: 22, seed: i, under: true)
        } + art.skaters.enumerated().map { i, name in
            Critter(texture: name, forward: -.pi / 2, size: 30, seed: i + 10, under: false)
        }
        clouds = art.clouds.enumerated().map { i, name in
            Cloud(texture: name, seed: i, size: size)
        }
        flyer = nil
        nextFlyerAt = time + 12
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

        // The breath: a slow figure of eight a few points across.
        let t = Float(now)
        drift = SIMD2(sin(t * 0.11) * 5.0, cos(t * 0.083) * 4.0)

        for c in critters { c.update(dt: dt, now: now, in: size) }
        for c in clouds { c.update(dt: dt, in: size) }
        if let f = flyer {
            f.update(dt: dt, now: now, in: size)
            if f.gone(in: size) { flyer = nil; nextFlyerAt = now + Double.random(in: 14...30) }
        } else if now > nextFlyerAt, let name = art.flyers.first {
            let f = Critter(texture: name, forward: .pi, size: 46, seed: Int(now) % 7, under: false)
            f.beginCrossing(in: size)
            flyer = f
        }

        if bloomRate > 0 {
            bloomStage = min(bloomTarget, bloomStage + bloomRate * dt)
            if bloomStage >= bloomTarget { bloomRate = 0 }
        }

        for k in koi {
            let event = k.update(dt: dt, now: now, in: size, rocks: rocks)
            if let e = event { splashes.append(e) }
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
        for c in clouds {
            out.append(Sprite(c.texture, at: CGPoint(x: c.position.x + 30, y: c.position.y + 90),
                              size: CGSize(width: c.width * 1.3, height: c.width * 1.3 * c.aspect),
                              mode: .shadow, alpha: 0.45, parallax: 0.35))
        }
        for w in weeds {
            let tw = textureSize(w.texture)
            let width = w.height * tw.width / max(1, tw.height)
            // Rooted at the bottom of the image: the centre sits half a height up.
            let centre = CGPoint(x: w.root.x - CGFloat(sin(w.lean)) * w.height * 0.5,
                                 y: w.root.y - CGFloat(cos(w.lean)) * w.height * 0.5)
            out.append(Sprite(w.texture, at: centre, size: CGSize(width: width, height: w.height),
                              rotation: w.lean, mode: .submerged, alpha: 1, depth: w.depth,
                              wave: w.phase + Float(time) * 0.9, waveAmp: 0.10, parallax: 0.5, weed: true))
        }
        for c in critters where c.under {
            out.append(Sprite(c.texture, at: c.position, size: c.spriteSize(textureSize), rotation: c.rotation,
                              mode: .submerged, alpha: 1, depth: 0.55, parallax: 0.55))
        }
        for k in koi where k.depth < 0.98 {
            let d = k.depth
            let w = k.width
            let h = w * k.aspect
            let index = spines.count / 13
            spines += k.spine(length: h)
            let offset = CGFloat(10 + 26 * d)
            out.append(Sprite(k.texture, at: CGPoint(x: offset * 0.6, y: offset),
                              size: CGSize(width: w, height: h), mode: .shadow,
                              alpha: 0.7 * (1 - d * 0.6), wave: k.phase, waveAmp: k.waveAmp, spine: index))
            out.append(Sprite(k.texture, at: .zero, size: CGSize(width: w, height: h),
                              mode: .submerged, alpha: 1, depth: d,
                              wave: k.phase, waveAmp: k.waveAmp, spine: index, parallax: 0.6))
        }
        return (out, spines)
    }

    /// On the surface: pond skaters.
    func skaterSprites() -> [Sprite] {
        critters.filter { !$0.under }.map { c in
            Sprite(c.texture, at: c.position, size: c.spriteSize(textureSize), rotation: c.rotation,
                   mode: .floater, alpha: 0.95, parallax: 1)
        }
    }

    /// In the air: clouds and whatever is flying over.
    func skySprites() -> [Sprite] {
        var out: [Sprite] = clouds.map { c in
            Sprite(c.texture, at: c.position, size: CGSize(width: c.width, height: c.width * c.aspect),
                   alpha: 0.30, tint: [0.92, 0.97, 1.0, 1], parallax: 2.2)
        }
        if let f = flyer {
            let s = f.spriteSize(textureSize)
            out.append(Sprite(f.texture, at: CGPoint(x: f.position.x + 14, y: f.position.y + 40), size: s,
                              rotation: f.rotation, mode: .shadow, alpha: 0.5, parallax: 1.0))
            out.append(Sprite(f.texture, at: f.position, size: s, rotation: f.rotation, alpha: 1, parallax: 1.5))
        }
        return out
    }

    /// Over the surface: falling blossom.
    func petalSprites() -> [Sprite] {
        petals.map { p in
            Sprite(p.texture, at: CGPoint(x: p.x, y: p.y), size: CGSize(width: 14 * p.scale, height: 14 * p.scale),
                   rotation: p.rotation, mode: p.landed ? .floater : .plain, alpha: p.alpha,
                   parallax: p.landed ? 1 : 1.4)
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
            out.append(Sprite(name, at: left, size: CGSize(width: side, height: side), alpha: alpha, parallax: 1.6))
            let small = side * art.branchRightScale
            let right = CGPoint(x: w - small * 0.5 + art.branchInset, y: small * 0.5 + art.branchRightDrop)
            out.append(Sprite(name, at: right, size: CGSize(width: small, height: small), alpha: alpha, flipX: true, parallax: 1.6))
        }
        branch(lo, alpha: 1)
        if hi != lo { branch(hi, alpha: t) }

        if let bank = art.bank {
            let bw = w * 1.06
            let ts = textureSize(bank)
            let bh = bw * ts.height / max(1, ts.width)
            out.append(Sprite(bank, at: CGPoint(x: w / 2, y: size.height - bh * 0.5 + art.bankSink),
                              size: CGSize(width: bw, height: bh), parallax: 1.3))
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
            } else {
                surface(now: now, in: size)
                splash = (position, 9, -0.12)
            }
        }
        depth += (depthTarget - depth) * min(1, dt * depthRate)

        let dx = Float(target.x - position.x), dy = Float(target.y - position.y)
        if hypot(dx, dy) < 30 { pickTarget(in: size) }
        var want = atan2(dy, dx)
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
        let want_rate = min(0.55, abs(diff) * 0.9)
        let turn = max(-want_rate * dt, min(want_rate * dt, diff))
        heading += turn
        // A fish slows a little into a turn and beats its tail harder.
        let tightness = min(1, abs(diff) / 1.2)
        let s = Float(speed) * (depth > 0.9 ? 0.5 : 1) * (1 - 0.2 * tightness)
        position.x += CGFloat(cos(heading) * s * dt)
        position.y += CGFloat(sin(heading) * s * dt)
        phase += dt * (3.0 + s * 0.09 + tightness * 2.5)
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
        // Rows were built tail-first; the rigid front was appended straight.
        // Smooth the joint: blend the last flexible rows toward the rigid line
        // so there is no kink where the two meet.
        let joint = rows[9]
        for row in stride(from: 8, through: 6, by: -1) {
            let t = Float(9 - row) / 4      // 0.25, 0.5, 0.75
            let back = total * (1 - Float(row) / 12)
            let rigid = head - headTangent * back
            var r = rows[row]
            r.x = r.x * t + rigid.x * (1 - t)
            r.y = r.y * t + rigid.y * (1 - t)
            let tan = simd_normalize(SIMD2(r.z, r.w) * t + headTangent * (1 - t))
            r.z = tan.x; r.w = tan.y
            rows[row] = r
        }
        _ = joint
        return rows
    }

    private func pickTarget(in size: CGSize) {
        // Somewhere ahead-ish and far: a fish cruises, it does not dither.
        for _ in 0..<12 {
            let candidate = CGPoint(x: CGFloat.random(in: 70...(size.width - 70)),
                                    y: CGFloat.random(in: 130...(size.height - 150)))
            let dx = Float(candidate.x - position.x), dy = Float(candidate.y - position.y)
            let dist = hypot(dx, dy)
            var diff = atan2(dy, dx) - heading
            while diff > .pi { diff -= 2 * .pi }
            while diff < -.pi { diff += 2 * .pi }
            if dist > 220, abs(diff) < 1.6 { target = candidate; break }
            target = candidate
        }
        speed = CGFloat.random(in: 24...40)
    }

    private func surface(now: TimeInterval, in size: CGSize) {
        // Reappear somewhere new only if the fish is fully hidden.
        if depth > 0.95 {
            position = CGPoint(x: CGFloat.random(in: 80...(size.width - 80)),
                               y: CGFloat.random(in: 140...(size.height - 160)))
            pickTarget(in: size)
            heading = atan2(Float(target.y - position.y), Float(target.x - position.x))
            straightTrail()
        }
        depthTarget = 0.12
        depthRate = 0.9
        stateUntil = now + Double.random(in: 8...14)
    }

    func dive(now: TimeInterval, quick: Bool) {
        depthTarget = 1
        depthRate = quick ? 3.5 : 0.8
        if quick { speed = 95 }
        stateUntil = now + Double.random(in: quick ? 6...11 : 4...9)
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


/// A strand of pondweed rooted in the bed.
struct Weed {
    let texture: String
    let root: CGPoint
    let height: CGFloat
    let lean: Float
    let phase: Float
    let depth: Float
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

    init(texture: String, forward: Float, size: CGFloat, seed: Int, under: Bool) {
        self.texture = texture
        self.forward = forward
        self.size = size
        self.under = under
        heading = Float(seed) * 1.3
        restUntil = Double(seed) * 0.7
    }

    var rotation: Float { heading - forward }

    func spriteSize(_ textureSize: (String) -> CGSize) -> CGSize {
        let t = textureSize(texture)
        let long = max(t.width, t.height)
        return CGSize(width: size * t.width / long, height: size * t.height / long)
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
            } else {
                heading += Float.random(in: -1.4...1.4)
                speed = under ? Float.random(in: 40...70) : Float.random(in: 90...150)
                restUntil = now + Double.random(in: 0.25...0.6)
            }
        }
        if speed > 1 {
            var nx = position.x + CGFloat(cos(heading) * speed * dt)
            var ny = position.y + CGFloat(sin(heading) * speed * dt)
            if nx < 40 || nx > bounds.width - 40 { heading = .pi - heading; nx = position.x }
            if ny < 120 || ny > bounds.height - 180 { heading = -heading; ny = position.y }
            position = CGPoint(x: nx, y: ny)
            speed *= exp(-dt * 2.2)
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
