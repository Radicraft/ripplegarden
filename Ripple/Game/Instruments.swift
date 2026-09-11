import CoreGraphics
import Foundation
import simd

// The instruments of the "move the water" levels (docs/gameplay-spec.md):
// a bamboo rocker on the bank, chime stones in the shallows, a dry pool
// beyond a lip. Each one reads the water at its own points, keeps its own
// state, emits events for the controller to sound and draw, and hands back
// the bodies and sprites that show it. None of them touches the renderer,
// the sound or the haptics directly.

// MARK: - Easing

private func smooth(_ t: Float) -> Float {
    let x = min(max(t, 0), 1)
    return x * x * (3 - 2 * x)
}

/// Gravity: slow to start, fastest at the stop.
private func easeIn(_ t: Float) -> Float {
    let x = min(max(t, 0), 1)
    return x * x
}

private func unit(_ v: SIMD2<Float>) -> SIMD2<Float> {
    let l = simd_length(v)
    return l > 1e-5 ? v / l : SIMD2(1, 0)
}

private func point(_ p: CGPoint, _ d: SIMD2<Float>, _ along: Float) -> CGPoint {
    CGPoint(x: p.x + CGFloat(d.x * along), y: p.y + CGFloat(d.y * along))
}

// MARK: - Shishi-odoshi

/// A bamboo rocker at the water's edge. Its spout hangs out over the pond;
/// every crest that passes under the mouth puts a little water in the
/// tube, and when it is full it tips, knocks on its stone, empties into
/// the pond and swings back to wait for the next.
final class ShishiOdoshi: Instrument {

    // Tuning. Angles are pitch about the fulcrum, positive spout down.
    static let restAngle: Float = -0.25
    static let tippedAngle: Float = 0.55
    static let tipSeconds: Float = 0.45
    /// A pause at the stop while the water runs out, before the swing back.
    static let drainSeconds: Float = 0.15
    static let returnSeconds: Float = 1.2
    /// A crest at the mouth above this height puts water in the tube.
    static let crestThreshold: Float = 0.03
    /// Height above the threshold, times this, per second, into `fill`.
    static let fillGain: Float = 18
    /// The mouth sits this far out over the water from `at`.
    static let spoutReach: Float = 30
    static let tubeLength: Float = 110
    static let tubeRadius: Float = 9
    /// The fulcrum's height over the water plane: the tube rests on its stone.
    static let pivotLift: Float = 34
    static let pivotStoneRadius: Float = 26
    static let strikeStoneRadius: Float = 16

    /// The point on the bank edge the rocker was placed at.
    let at: CGPoint
    /// Unit direction from the bank out over the water: the way the spout points.
    let direction: SIMD2<Float>
    /// Where the tube turns, back on the bank.
    let pivot: CGPoint
    /// The mouth of the spout at rest, over the water.
    let spout: CGPoint

    private(set) var fill: Float = 0
    private(set) var knocks = 0
    /// The current pitch of the tube, `restAngle` when waiting.
    private(set) var tilt: Float = ShishiOdoshi.restAngle

    private enum Phase { case filling, tipping(Float), draining(Float), returning(Float) }
    private var phase: Phase = .filling

    var splashes: [(at: CGPoint, radius: Float, amplitude: Float)] = []

    init(at: CGPoint, bankDirection: SIMD2<Float>) {
        self.at = at
        direction = unit(bankDirection)
        // The spout's arm is the part of the tube ahead of the pivot. The
        // fulcrum sits back on the bank so the mouth lands `spoutReach` out.
        let arm = (1 - SolidMesh.bambooPivot) * ShishiOdoshi.tubeLength * cos(ShishiOdoshi.restAngle)
        pivot = point(at, direction, ShishiOdoshi.spoutReach - arm)
        spout = point(at, direction, ShishiOdoshi.spoutReach)
    }

    var state: ShishiOdoshiState { ShishiOdoshiState(fill: fill, knocks: knocks, tilt: tilt) }

    var probePoints: [CGPoint] { [spout] }

    func update(dt: Float, samples: [FieldSample], events: inout [InstrumentEvent]) {
        splashes.removeAll()
        switch phase {
        case .filling:
            if let s = samples.first {
                let over = s.height - ShishiOdoshi.crestThreshold
                if over > 0 { fill = min(1, fill + over * ShishiOdoshi.fillGain * dt) }
            }
            tilt += (ShishiOdoshi.restAngle - tilt) * min(1, dt * 6)
            if fill >= 1 { phase = .tipping(0) }

        case .tipping(let t):
            let u = t + dt / ShishiOdoshi.tipSeconds
            tilt = ShishiOdoshi.restAngle + (ShishiOdoshi.tippedAngle - ShishiOdoshi.restAngle) * easeIn(u)
            if u >= 1 {
                tilt = ShishiOdoshi.tippedAngle
                knocks += 1
                events.append(.knock(at: spout))
                // The tube empties: one push where it pours, and a few drops
                // round it.
                let mouth = spout
                splashes.append((at: mouth, radius: 12, amplitude: -0.12))
                for k in 0..<3 {
                    let a = Float(k) * 2.1 + 0.6
                    let off = CGPoint(x: mouth.x + CGFloat(cos(a) * (10 + Float(k) * 3)),
                                      y: mouth.y + CGFloat(sin(a) * (10 + Float(k) * 3)))
                    splashes.append((at: off, radius: 5, amplitude: -0.05))
                }
                phase = .draining(0)
            } else {
                phase = .tipping(u)
            }

        case .draining(let t):
            let u = t + dt
            if u >= ShishiOdoshi.drainSeconds { phase = .returning(0) } else { phase = .draining(u) }

        case .returning(let t):
            let u = t + dt / ShishiOdoshi.returnSeconds
            tilt = ShishiOdoshi.tippedAngle + (ShishiOdoshi.restAngle - ShishiOdoshi.tippedAngle) * smooth(u)
            if u >= 1 {
                tilt = ShishiOdoshi.restAngle
                fill = 0
                phase = .filling
            } else {
                phase = .returning(u)
            }
        }
    }

    func solids(depthScale: Float) -> [SolidInstance] {
        let yaw = atan2(direction.y, direction.x)
        // `tilt` on a body is the slope it banks with, scaled by
        // `Tuning.solidBank` in the shader; a slope along the heading pitches
        // the axis, the far end up for a slope that points the same way.
        // Spout down is the far end down, so the slope runs backwards.
        let slope = -tan(tilt) / Tuning.solidBank
        let body: SIMD4<Float> = [0.80, 0.77, 0.46, 1]
        // The cane in `colourA`, the darker node bands in `colourB`.
        let tube = SolidInstance(position: SIMD2(Float(pivot.x), Float(pivot.y)),
                                 lift: ShishiOdoshi.pivotLift, yaw: yaw, roll: 0,
                                 tilt: direction * slope,
                                 length: ShishiOdoshi.tubeLength, radius: ShishiOdoshi.tubeRadius,
                                 shape: 6, alpha: 1, colourA: body, colourB: ShishiOdoshi.nodeColour)
        let rest = stone(at: pivot, radius: ShishiOdoshi.pivotStoneRadius, salt: 1)
        // The striking stone lies just past the mouth, so the lip lands on
        // its near shoulder rather than its middle.
        let strike = stone(at: point(spout, direction, 6), radius: ShishiOdoshi.strikeStoneRadius, salt: 2)
        return [tube, rest, strike]
    }

    static let nodeColour: SIMD4<Float> = [0.52, 0.50, 0.26, 1]

    private func stone(at p: CGPoint, radius: Float, salt: Float) -> SolidInstance {
        SolidInstance(position: SIMD2(Float(p.x), Float(p.y)), lift: radius * 0.3,
                      yaw: Float(p.x * 0.011 + p.y * 0.007) + salt, roll: Float(p.x * 0.13 + p.y * 0.07) + salt * 17,
                      tilt: .zero, length: radius * 1.4, radius: radius, shape: 2, alpha: 1,
                      colourA: [0.52, 0.53, 0.50, 1], colourB: [0.38, 0.50, 0.30, 1])
    }

    func sprites(textureSize: (String) -> CGSize) -> [Sprite] { [] }
}

// MARK: - Suikinkutsu

/// Chime stones in the shallows. A crest over a stone sounds its note; the
/// pond hums a phrase and the player ripples the stones in that order. A
/// right note lights its stone; a wrong one lets the phrase be heard again.
final class Suikinkutsu: Instrument {

    // Tuning.
    static let crestThreshold: Float = 0.032
    /// A stone will not sound again inside this.
    static let noteSpacing: Float = 0.6
    /// A stone sounding again this soon after itself is the same ripple,
    /// not a second note: it rings but neither advances nor breaks the phrase.
    static let sameStrike: Float = 1.4
    /// When the pond first hums the phrase.
    static let firstReplay: Float = 1.5
    /// How long after a wrong note the phrase is hummed again.
    static let replayAfterWrong: Float = 1.2
    /// A lit stone settles to this glow while the phrase is in progress.
    static let heldGlow: Float = 0.35
    static let stoneRadius: Float = 20

    let stones: [CGPoint]
    let order: [Int]

    private(set) var played: [Int] = []
    private(set) var complete = false
    private(set) var glow: [Float]

    private var clock: Float = 0
    private var lastSound: [Float]
    private var lastIndex: Int? = nil
    private var lastIndexAt: Float = -10
    private var replayAt: Float? = Suikinkutsu.firstReplay
    /// After a wrong note the lights go out; after the phrase, they all come up.
    private var glowTarget: [Float]

    var splashes: [(at: CGPoint, radius: Float, amplitude: Float)] = []

    init(stones: [CGPoint], order: [Int]) {
        self.stones = stones
        self.order = order.filter { $0 >= 0 && $0 < stones.count }
        glow = [Float](repeating: 0, count: stones.count)
        glowTarget = glow
        lastSound = [Float](repeating: -10, count: stones.count)
        if self.order.isEmpty { complete = true }
    }

    var state: SuikinkutsuState { SuikinkutsuState(played: played, complete: complete, glow: glow) }

    var probePoints: [CGPoint] { stones }

    func update(dt: Float, samples: [FieldSample], events: inout [InstrumentEvent]) {
        clock += dt

        if let t = replayAt, clock >= t {
            replayAt = nil
            events.append(.phraseReplay)
        }

        for (i, s) in samples.enumerated() where i < stones.count {
            guard s.height > Suikinkutsu.crestThreshold,
                  clock - lastSound[i] >= Suikinkutsu.noteSpacing else { continue }
            lastSound[i] = clock
            sound(i, events: &events)
        }

        for i in glow.indices {
            let rate: Float = glowTarget[i] > glow[i] ? 8 : 1.6
            glow[i] += (glowTarget[i] - glow[i]) * min(1, dt * rate)
        }
    }

    private func sound(_ i: Int, events: inout [InstrumentEvent]) {
        let at = stones[i]
        if complete {
            events.append(.note(index: i, at: at, right: true))
            return
        }
        // The same stone ringing again straight after itself is the same
        // ripple coming back over it.
        if lastIndex == i, clock - lastIndexAt < Suikinkutsu.sameStrike {
            lastIndexAt = clock
            events.append(.note(index: i, at: at, right: true))
            return
        }
        lastIndex = i
        lastIndexAt = clock
        if i == order[played.count] {
            events.append(.note(index: i, at: at, right: true))
            played.append(i)
            glow[i] = 1
            glowTarget[i] = Suikinkutsu.heldGlow
            if played.count == order.count {
                complete = true
                glowTarget = [Float](repeating: 1, count: stones.count)
                events.append(.phraseComplete)
            }
        } else {
            events.append(.note(index: i, at: at, right: false))
            played.removeAll()
            glowTarget = [Float](repeating: 0, count: stones.count)
            replayAt = clock + Suikinkutsu.replayAfterWrong
        }
    }

    func solids(depthScale: Float) -> [SolidInstance] {
        stones.map { p in
            let r = Suikinkutsu.stoneRadius
            return SolidInstance(position: SIMD2(Float(p.x), Float(p.y)), lift: r * 0.3,
                                 yaw: Float(p.x * 0.013 + p.y * 0.009), roll: Float(p.x * 0.17 + p.y * 0.05),
                                 tilt: .zero, length: r * 1.4, radius: r, shape: 2, alpha: 1,
                                 colourA: [0.50, 0.52, 0.54, 1], colourB: [0.36, 0.50, 0.32, 1])
        }
    }

    /// A soft ring of light over each stone, as bright as its glow, riding
    /// the surface. Agent D's ring when it is in the bundle, a mote scaled
    /// up until then.
    func sprites(textureSize: (String) -> CGSize) -> [Sprite] {
        let ring = textureSize("chime_glow").width > 2
        let name = ring ? "chime_glow" : "mote"
        let size: CGFloat = ring ? 76 : 88
        var out: [Sprite] = []
        for (i, p) in stones.enumerated() where glow[i] > 0.01 {
            out.append(Sprite(name, at: p, size: CGSize(width: size, height: size), mode: .floater,
                              alpha: glow[i] * (ring ? 0.85 : 0.5), tint: [1, 0.97, 0.82, 1], z: 0.03))
        }
        return out
    }
}

// MARK: - Dry pool

/// A dry pool on the bank beyond a lip. Every crest that stands higher than
/// the lip spills into it; enough spills and the pool is full, at which
/// point the controller repaints the depth so the water joins the pond.
final class DryPool: Instrument {

    // Tuning.
    /// Height over the lip, times this, per second, into `fill`. The three
    /// probes are one crest, so the highest of them counts, not their sum.
    static let spillGain: Float = 12
    /// Spills are reported no closer than this.
    static let spillSpacing: Float = 0.4
    /// The probes flank the lip point this far along it.
    static let lipHalfWidth: Float = 25
    /// How much the pool's depth is painted at full: `fill * poolDepth`.
    static let poolDepth: Float = 0.3

    let lip: CGPoint
    let pool: Shape
    let lipHeight: Float
    /// Unit direction from the lip into the pool.
    let direction: SIMD2<Float>

    private(set) var fill: Float = 0
    private(set) var full = false
    private var clock: Float = 0
    private var lastSpill: Float = -10
    private let probes: [CGPoint]

    var splashes: [(at: CGPoint, radius: Float, amplitude: Float)] = []

    init(lip: CGPoint, pool: Shape, lipHeight: Float) {
        self.lip = lip
        self.pool = pool
        self.lipHeight = lipHeight
        direction = unit(SIMD2(Float(pool.centre.x - lip.x), Float(pool.centre.y - lip.y)))
        let across = SIMD2(-direction.y, direction.x)
        probes = [lip, point(lip, across, DryPool.lipHalfWidth), point(lip, across, -DryPool.lipHalfWidth)]
    }

    var state: DryPoolState { DryPoolState(fill: fill, full: full) }

    /// What the depth painter should paint inside `pool` this frame.
    var paintedDepth: Float { fill * DryPool.poolDepth }

    var probePoints: [CGPoint] { probes }

    func update(dt: Float, samples: [FieldSample], events: inout [InstrumentEvent]) {
        clock += dt
        guard !full else { return }
        var best: (over: Float, at: CGPoint)? = nil
        for (i, s) in samples.enumerated() where i < probes.count {
            let over = s.height - lipHeight
            if over > 0, over > (best?.over ?? 0) { best = (over, probes[i]) }
        }
        guard let best else { return }
        fill = min(1, fill + best.over * DryPool.spillGain * dt)
        if clock - lastSpill >= DryPool.spillSpacing {
            lastSpill = clock
            events.append(.spill(at: best.at, amount: min(1, best.over / 0.05)))
        }
        if fill >= 1 {
            full = true
            events.append(.poolFull)
        }
    }

    func solids(depthScale: Float) -> [SolidInstance] { [] }
    func sprites(textureSize: (String) -> CGSize) -> [Sprite] { [] }
}
