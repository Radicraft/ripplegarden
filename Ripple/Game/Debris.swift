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

    /// Below this slope a heavy piece does not budge. A lone tap peaks around
    /// 0.02; a charged swell reaches 0.08 and up.
    static let heavyThreshold: Float = 0.055
    static let lightMass: Float = 1.0
    static let heavyMass: Float = 7.0

    /// Velocity decay per second. Petals stop almost as soon as the water
    /// does; stones stop sooner.
    static let lightDrag: Float = 2.6
    static let heavyDrag: Float = 6.0

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
    var position: CGPoint
    var velocity = SIMD2<Float>(0, 0)
    var angle: CGFloat
    var spin: CGFloat = 0
    /// Half-size in points, for separation and hit tests.
    var radius: CGFloat
    var scale: CGFloat
    var cleared = false
    /// Last known water height under the piece, for the bob.
    var height: Float = 0

    init(id: Int, cls: DebrisClass, sprite: String, position: CGPoint, radius: CGFloat, scale: CGFloat) {
        self.id = id
        self.cls = cls
        self.sprite = sprite
        self.position = position
        self.radius = radius
        self.scale = scale
        self.angle = CGFloat.random(in: 0...(2 * .pi))
    }

    var mass: Float { cls == .light ? GameTuning.lightMass : GameTuning.heavyMass }
    var drag: Float { cls == .light ? GameTuning.lightDrag : GameTuning.heavyDrag }
}

enum DebrisPhysics {

    /// One step for one piece. `sample` is what the water was doing under it
    /// last frame; `current` is the edge current in points per second.
    static func integrate(_ d: Debris, sample: FieldSample?, current: SIMD2<Float>, dt: Float) {
        var force = SIMD2<Float>(0, 0)

        if let s = sample {
            d.height = s.height
            // Downhill is minus the gradient. Gate on the surface rising so the
            // front of a wave shoves harder than its back drags.
            let rising: Float = s.velocity > 0 ? 1.0 : GameTuning.trailingPull
            var push = -s.slope * GameTuning.slopeGain * rising
            let strength = simd_length(s.slope)
            if d.cls == .heavy {
                if strength < GameTuning.heavyThreshold {
                    push = .zero
                } else {
                    // Only the part above the threshold moves the stone.
                    push *= (strength - GameTuning.heavyThreshold) / strength
                }
            }
            force += push
        }

        let currentPush = d.cls == .light ? GameTuning.currentPushLight : GameTuning.currentPushHeavy
        // The current is a velocity the water carries the piece at, so it acts
        // as a pull toward that velocity rather than a force.
        let target = current * currentPush
        d.velocity += (target - d.velocity) * min(1, dt * 1.5)

        d.velocity += force / d.mass * dt
        d.velocity *= exp(-d.drag * dt)

        d.position.x += CGFloat(d.velocity.x * dt)
        d.position.y += CGFloat(d.velocity.y * dt)

        // A little roll when it moves, in a direction that stays put per piece.
        let speed = simd_length(d.velocity)
        d.spin += (CGFloat(speed) * 0.004 * (d.id % 2 == 0 ? 1 : -1) - d.spin) * CGFloat(min(1, dt * 4))
        d.angle += d.spin * CGFloat(dt) * 60
    }

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
