import CoreGraphics
import Foundation
import simd

/// Numbers that decide how the water moves what floats on it.
enum GameTuning {

    /// Points of acceleration per unit of slope (height per cell). A crest's
    /// leading face pushes at full strength; its trailing face pulls back at
    /// `trailingPull` of that, so a passing ring leaves a net drift outward,
    /// which is the Stokes drift a real floater gets.
    static let slopeGain: Float = 125000
    static let trailingPull: Float = 0.18

    /// Water height under a heavy piece below which it does not budge. A tap's
    /// ring passes at a few hundredths; a charged swell lifts by tenths.
    static let heavyThreshold: Float = 0.045
    static let heavyGain: Float = 11.0
    static let lightMass: Float = 1.0
    static let heavyMass: Float = 7.0

    /// Velocity decay per second. Petals stop almost as soon as the water
    /// does; stones stop sooner.
    static let lightDrag: Float = 2.6
    static let heavyDrag: Float = 3.0

    /// The edge current, in points per second at full strength, and how fast
    /// a stroke along the edge builds it.
    static let currentMax: Float = 42
    static let currentGainPerPoint: Float = 0.9
    static let currentHalfLife: Float = 7.0
    static let currentPushLight: Float = 1.0
    static let currentPushHeavy: Float = 0.25

    /// Touches starting inside this band count as edge strokes once they move.
    static let edgeBand: CGFloat = 30
    static let edgeStrokeMinTravel: CGFloat = 12

    /// A piece this close to the edge has reached the bank and is cleared.
    static let shoreTop: CGFloat = 20
    static let shoreSide: CGFloat = 20
    static let shoreBottom: CGFloat = 44

    /// Pieces push each other apart so a cluster does not stack into one.
    static let separationStrength: Float = 140

    /// How long the finger must stay before a hold counts as one, for sound.
    static let holdSoundAfter: Float = 0.18
}

/// Something floating on the pond that the water can move.
final class Debris: Identifiable {
    let id: Int
    let cls: DebrisClass
    let sprite: String
    let kind: DebrisKind
    var position: CGPoint
    var velocity = SIMD2<Float>(0, 0)
    var angle: CGFloat
    var spin: CGFloat = 0
    /// Half-size in points, for separation and hit tests.
    var radius: CGFloat
    var scale: CGFloat
    var cleared = false
    /// Drawn alpha, for pieces on their way out.
    var fade: Float = 1
    /// Seconds of life left for something that melts; nil for things that do not.
    var meltsIn: Float? = nil
    var meltTotal: Float = 1
    /// Last known water height under the piece, for the bob.
    var height: Float = 0
    /// When it last knocked against something, so knocks do not chatter.
    var lastKnockAt: Float = -10
    /// Last known surface slope under the piece. A solid body banks with it.
    var slope = SIMD2<Float>(0, 0)
    /// Rotation about the long axis, for a piece drawn as a solid. A can
    /// that drifts sideways rolls; pushed end on, it slides.
    var roll: Float = 0

    init(id: Int, cls: DebrisClass, sprite: String, position: CGPoint, radius: CGFloat, scale: CGFloat, kind: DebrisKind = .natural) {
        self.id = id
        self.cls = cls
        self.sprite = sprite
        self.kind = kind
        self.position = position
        self.radius = radius
        self.scale = scale
        self.angle = CGFloat.random(in: 0...(2 * .pi))
    }

    /// The body this piece is drawn as, if it is not paper. Rubbish knows
    /// from its kind; a heavy natural piece knows from the sprite the season
    /// handed it, so driftwood is a log and a stone is a stone.
    var solid: SolidBody? {
        if let body = kind.solid { return body }
        guard cls == .heavy else { return nil }
        return NaturalSolid.forSprite(sprite)?.body
    }

    var mass: Float { (cls == .light ? GameTuning.lightMass : GameTuning.heavyMass) * kind.mass }
    var drag: Float { (cls == .light ? GameTuning.lightDrag : GameTuning.heavyDrag) * kind.drag }
}

enum DebrisPhysics {

    /// One step for one piece. `sample` is what the water was doing under it
    /// last frame; `current` is the edge current in points per second.
    static func integrate(_ d: Debris, sample: FieldSample?, current: SIMD2<Float>, dt: Float) {
        var force = SIMD2<Float>(0, 0)

        if let s = sample {
            d.height = s.height
            d.slope = s.slope
            // Downhill is minus the gradient. Gate on the surface rising so the
            // front of a wave shoves harder than its back drags.
            let rising: Float = s.velocity > 0 ? 1.0 : GameTuning.trailingPull
            var push = -s.slope * GameTuning.slopeGain * rising * d.kind.gain
            if d.cls == .heavy {
                // A tap's ring is a few hundredths high and does nothing. A
                // held swell lifts the water under the log by tenths, and only
                // its rising face shoves, so the log moves away from the hand.
                let lift = abs(s.height)
                let threshold = GameTuning.heavyThreshold * d.kind.threshold
                if lift < threshold || s.velocity <= 0 {
                    push = .zero
                } else {
                    push *= min(1, (lift - threshold) / threshold) * GameTuning.heavyGain
                }
            }
            force += push
        }

        let currentPush = (d.cls == .light ? GameTuning.currentPushLight : GameTuning.currentPushHeavy) * d.kind.currentPush
        // The current is a velocity the water carries the piece at, so it acts
        // as a pull toward that velocity rather than a force.
        let target = current * currentPush
        d.velocity += (target - d.velocity) * min(1, dt * 1.5)

        d.velocity += force / d.mass * dt
        d.velocity *= exp(-d.drag * dt)
        // A NaN out of the field would stay one for ever, and a piece with a
        // NaN position never reaches the bank, so the level could not be
        // finished. Put it back to rest instead.
        if !d.velocity.x.isFinite || !d.velocity.y.isFinite { d.velocity = .zero }

        d.position.x += CGFloat(d.velocity.x * dt)
        d.position.y += CGFloat(d.velocity.y * dt)
        if !d.position.x.isFinite { d.position.x = 0 }
        if !d.position.y.isFinite { d.position.y = 0 }

        // A little roll when it moves, in a direction that stays put per piece.
        let speed = simd_length(d.velocity)
        d.spin += (CGFloat(speed) * 0.004 * (d.id % 2 == 0 ? 1 : -1) - d.spin) * CGFloat(min(1, dt * 4))
        d.angle += d.spin * CGFloat(dt) * 60

        // A body rolls on the water the way a barrel rolls on a floor: only
        // the travel across its own axis turns it, so a can shoved end on
        // just slides. A stone does not roll: it is dragged, and its roll
        // slot is the seed of its lumps.
        if let solid = d.solid, solid.rolls {
            let axis = SIMD2<Float>(Float(cos(d.angle)), Float(sin(d.angle)))
            let across = d.velocity.x * -axis.y + d.velocity.y * axis.x
            d.roll += across / Float(max(1, d.radius * solid.radius)) * dt
        }
    }

    /// Told when two pieces meet with some force, so the meeting can sound.
    static var onKnock: ((Debris, Debris, Float) -> Void)?

    /// Keeps pieces from occupying the same spot.
    static func separate(_ all: [Debris], dt: Float) {
        let live = all.filter { !$0.cleared }
        guard live.count > 1 else { return }
        for i in 0..<live.count {
            for j in (i + 1)..<live.count {
                let a = live[i], b = live[j]
                let dx = Float(b.position.x - a.position.x)
                let dy = Float(b.position.y - a.position.y)
                let dist = max(0.001, (dx * dx + dy * dy).squareRoot())
                let minDist = Float(a.radius + b.radius) * 0.78
                guard dist < minDist else { continue }
                let overlap = (minDist - dist) / minDist
                let n = SIMD2(dx, dy) / dist
                // Closing speed along the line between them: a knock if brisk.
                let closing = simd_dot(a.velocity - b.velocity, n)
                if closing > 18 { onKnock?(a, b, closing) }
                let kick = n * overlap * GameTuning.separationStrength * dt
                let total = a.mass + b.mass
                a.velocity -= kick * (b.mass / total) * 2
                b.velocity += kick * (a.mass / total) * 2
            }
        }
    }

    /// True once the piece has reached the bank.
    static func hasReachedShore(_ d: Debris, in size: CGSize) -> Bool {
        d.position.x < GameTuning.shoreSide || d.position.x > size.width - GameTuning.shoreSide ||
        d.position.y < GameTuning.shoreTop || d.position.y > size.height - GameTuning.shoreBottom
    }
}
