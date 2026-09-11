import Foundation
import CoreGraphics
import simd

// The contract for the gameplay reinvention (docs/gameplay-spec.md). Every
// agent compiles against this file; nobody changes it. Positions in a
// GoalSpec written in Library are WORLD FRACTIONS (like DebrisPlacement);
// `placed(in:)` turns them into world points once the level is laid out.

/// What a level asks of the player, one entry per idea.
enum GoalKind {
    /// Every piece that is not a seed has been carried onto a bank.
    case clearDebris
    /// The ice sheet is gone (fraction < 0.06).
    case breakIce
    /// The silt haze over the bed has been scoured off at least `clean` of the pond.
    case clearSilt(clean: Float)
    /// The duckweed film covers no more than `cover` of the water.
    case partDuckweed(cover: Float)
    /// `count` seeds have rooted inside the shallows shape.
    case rootSeeds(shallows: Shape, count: Int)
    /// A koi has been called up (surfaced) within `radius` of `at` for 1.5 s.
    case callKoi(at: CGPoint, radius: CGFloat)
    /// A surfaced koi under the bud at `bud` has nudged it open.
    case koiOpensBud(bud: CGPoint)
    /// The shoal's centroid has crossed the gate segment.
    case leadShoal(gate: (CGPoint, CGPoint))
    /// The shy koi living under `home` has left it entirely.
    case temptShyKoi(home: Shape)
    /// A crest above `threshold` has passed the target.
    case wakeTarget(TargetKind, at: CGPoint, threshold: Float)
    /// The bamboo rocker at `at` has knocked `knocks` times.
    case shishiOdoshi(at: CGPoint, knocks: Int)
    /// The chime stones have been rippled in `order` (indices into `stones`).
    case suikinkutsu(stones: [CGPoint], order: [Int])
    /// Water spilling over `lip` (crests above `lipHeight`) has filled the dry `pool`.
    case fillPool(lip: CGPoint, pool: Shape, lipHeight: Float)
    /// The pond has lain glassy for `seconds`.
    case stillness(seconds: Float)
}

struct GoalSpec {
    var kind: GoalKind
    /// The line shown when the level opens ("Call the koi up with a held finger.").
    var text: String
    /// What this goal leaves in the pool when it is met (the hub shows it).
    var wakes: Set<WokeToken> = []

    /// Convert every fraction in the kind to world points.
    func placed(in world: CGSize) -> GoalSpec {
        func pt(_ f: CGPoint) -> CGPoint { CGPoint(x: f.x * world.width, y: f.y * world.height) }
        func shape(_ s: Shape) -> Shape { Shape(centre: pt(s.centre), radius: s.radius * world.height) }
        var out = self
        switch kind {
        case .clearDebris, .breakIce, .clearSilt, .partDuckweed, .stillness:
            break
        case .rootSeeds(let s, let n):
            out.kind = .rootSeeds(shallows: shape(s), count: n)
        case .callKoi(let at, let r):
            out.kind = .callKoi(at: pt(at), radius: r * world.height)
        case .koiOpensBud(let b):
            out.kind = .koiOpensBud(bud: pt(b))
        case .leadShoal(let g):
            out.kind = .leadShoal(gate: (pt(g.0), pt(g.1)))
        case .temptShyKoi(let h):
            out.kind = .temptShyKoi(home: shape(h))
        case .wakeTarget(let k, let at, let t):
            out.kind = .wakeTarget(k, at: pt(at), threshold: t)
        case .shishiOdoshi(let at, let n):
            out.kind = .shishiOdoshi(at: pt(at), knocks: n)
        case .suikinkutsu(let stones, let order):
            out.kind = .suikinkutsu(stones: stones.map(pt), order: order)
        case .fillPool(let lip, let pool, let h):
            out.kind = .fillPool(lip: pt(lip), pool: shape(pool), lipHeight: h)
        }
        return out
    }
}

/// What a finished level leaves alive in its pool on the map.
enum WokeToken: String, Codable, CaseIterable {
    case koi, shoal, bud, seeds, moon, bamboo, chime, clear, pool, shy
}

/// A reading the goals take of the pond each frame. Built by GameController.
struct GoalContext {
    var dt: Float
    var elapsed: Float
    /// Seconds since the last finger touched the water.
    var sinceTouch: Float
    /// Mean |vertical velocity| over the fixed calm probes (0 = glassy).
    var agitation: Float
    var iceFraction: Float          // 0 when there is no ice
    var siltCleaned: Float          // 0...1
    var filmCover: Float            // 0...1, duckweed over the water
    /// Height and vertical velocity of the water at the points a goal asked
    /// for (`GoalProbes`), in the order they were requested.
    var probes: [FieldSample]
    /// Koi that are at the surface (depth < 0.25), by position.
    var surfacedKoi: [CGPoint]
    var shoalCentroids: [CGPoint]
    var shyKoiOut: Bool
    /// Seeds rooted so far (the controller counts them).
    var rootedSeeds: Int
    var remainingDebris: Int
    var bamboo: ShishiOdoshiState?
    var chime: SuikinkutsuState?
    var pool: DryPoolState?
    var targetWoke: Bool
    /// Seconds since a wake was last laid for the shoal to follow.
    var sinceWake: Float = 99
    /// The koi that has answered a held finger and is at the surface, if any.
    var calledKoi: CGPoint? = nil
    /// How much the phone is being moved (0 still, about 1 handled, 2 shaken).
    var handMotion: Float = 0
}

struct ShishiOdoshiState { var fill: Float; var knocks: Int; var tilt: Float }
struct SuikinkutsuState { var played: [Int]; var complete: Bool; var glow: [Float] }
struct DryPoolState { var fill: Float; var full: Bool }

/// Instruments read the water at their own points; the controller probes
/// these each frame and hands the samples back.
protocol Instrument: AnyObject {
    /// World points to probe this frame.
    var probePoints: [CGPoint] { get }
    /// Advance with the samples for those points (same order).
    func update(dt: Float, samples: [FieldSample], events: inout [InstrumentEvent])
    /// What to draw: solids and sprites, world points.
    func solids(depthScale: Float) -> [SolidInstance]
    func sprites(textureSize: (String) -> CGSize) -> [Sprite]
    /// Splats the instrument makes on the water this frame (a knock's spill).
    var splashes: [(at: CGPoint, radius: Float, amplitude: Float)] { get set }
}

enum InstrumentEvent {
    case knock(at: CGPoint)
    case note(index: Int, at: CGPoint, right: Bool)
    case phraseComplete
    case phraseReplay
    case spill(at: CGPoint, amount: Float)
    case poolFull
}

// MARK: - Life and coax (Garden adopts; the class's own methods override these)

protocol LifeCoax: AnyObject {
    /// A charged hold at `at`: the nearest koi within 260 pt rises and comes.
    func callKoi(at: CGPoint, charge: Float, dt: Float)
    /// The finger lifted: the called koi stays up 3 s then cruises off.
    func releaseCall()
    /// A koi at the surface within `radius` of `point`, if any.
    func koiSurfacedNear(_ point: CGPoint, radius: CGFloat) -> CGPoint?
    /// Every koi currently at the surface (depth < 0.25).
    func surfacedKoi() -> [CGPoint]
    /// Centroid of each shoal.
    func shoalCentroids() -> [CGPoint]
    /// A fast stroke laid a wake along `path` (world points, start to end).
    func followWake(path: [CGPoint])
    /// One koi becomes shy and lives under this shape until tempted out.
    func setShyHome(_ home: Shape?)
    /// The shy koi has left its home entirely.
    var shyKoiOut: Bool { get }
    /// Koi rest on the bed while ice covers them; they wake as it opens.
    func sleepKoiUnderIce(_ asleep: Bool)
    /// A single tap on calm water: koi far away turn curious toward it.
    func curious(tap: CGPoint, calm: Bool)
    /// 0 = busy, 1 = the pond has lain glassy long enough: moon and dragonfly.
    func stillness(_ amount: Float)
    /// The koi that answers a hold, for the bud nudge.
    var calledKoi: CGPoint? { get }
}

extension LifeCoax {
    func callKoi(at: CGPoint, charge: Float, dt: Float) {}
    func releaseCall() {}
    func koiSurfacedNear(_ point: CGPoint, radius: CGFloat) -> CGPoint? {
        surfacedKoi().first { hypot($0.x - point.x, $0.y - point.y) < radius }
    }
    func surfacedKoi() -> [CGPoint] { [] }
    func shoalCentroids() -> [CGPoint] { [] }
    func followWake(path: [CGPoint]) {}
    func setShyHome(_ home: Shape?) {}
    var shyKoiOut: Bool { false }
    func sleepKoiUnderIce(_ asleep: Bool) {}
    func curious(tap: CGPoint, calm: Bool) {}
    func stillness(_ amount: Float) {}
    var calledKoi: CGPoint? { nil }
}

extension Garden: LifeCoax {}

// MARK: - Materials (WaterRenderer adopts; the class's own methods override these)

protocol Materials: AnyObject {
    /// Duckweed film over the water: on/off (a level with none costs nothing).
    func setFilm(on: Bool)
    /// Fraction of the water under duckweed, 0...1, updated every few frames.
    var filmCover: Float { get }
    /// Silt haze over the whole bed (no mosaic): the region is every water cell.
    func setSilt(wholePond: Bool)
    /// Paint the depth map again from `depthPainter` without resetting the water.
    func repaintDepth()
}

extension Materials {
    func setFilm(on: Bool) {}
    var filmCover: Float { 0 }
    func setSilt(wholePond: Bool) {}
    func repaintDepth() {}
}

extension WaterRenderer: Materials {}

// MARK: - Tuning shared by the goals

enum GoalTuning {
    /// Agitation (mean |v| over the calm probes) below which the pond is glassy.
    static let calmThreshold: Float = 0.004
    /// Seconds without a touch before stillness can begin to count.
    static let calmAfterTouch: Float = 2.0
    /// A koi counts as called when it has been up within the radius this long.
    static let callHold: Float = 1.5
    /// Reach of a held finger for calling a koi, points.
    static let callReach: CGFloat = 420
    /// A seed roots after resting this long in the shallows.
    static let rootAfter: Float = 1.5
    /// A near miss trembles a target above this fraction of its threshold.
    static let trembleFraction: Float = 0.6
    /// Hand motion above this keeps stillness from gathering.
    static let stillHand: Float = 0.12
}
