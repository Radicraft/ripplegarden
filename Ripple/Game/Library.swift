import CoreGraphics
import simd

// ---------------------------------------------------------------------------
// Content. Seasons and levels are plain data so more can be appended after
// launch; nothing assumes four seasons. Positions are unit screen
// coordinates, origin top-left; radii are fractions of the screen height.
// ---------------------------------------------------------------------------

/// One season's pictures, in one of the two looks.
struct ArtSet {
    var branch: [String]          // four bloom states, bare to full
    var branchScale: CGFloat      // width of the big corner branch as a fraction of screen width
    var branchInset: CGFloat = 8  // points the branch base sits outside the corner
    var branchRightScale: CGFloat = 0.74
    var branchRightDrop: CGFloat = 44
    var bank: String?
    var bankSink: CGFloat         // points the bank sits below the bottom edge
    var light: [String]
    var heavy: [String]           // driftwood, stone, mossy stone
    var rock: String
    var koi: [String]
    var koiForward: [Float]       // screen-space angle of the nose at rotation 0
    var koiWaveAmp: Float
    var mosaic: String
    var petalParticle: String
    var floor: FloorLook
    /// Life in and over the pond: rooted weed strands, things under the
    /// surface, things on it, things in the air, and the clouds.
    var weeds: [String] = []
    var under: [String] = []
    var skaters: [String] = []
    var flyers: [String] = []
    var clouds: [String] = []
}

struct Season: Identifiable {
    let id: String
    let name: String
    let order: Int
    let woodblock: ArtSet
    let photographic: ArtSet?
    let rootNote: Float
    /// A line for the path, in the season's voice.
    let tagline: String

    func art(for style: WaterStyle) -> ArtSet {
        style == .photographic ? (photographic ?? woodblock) : woodblock
    }
}

enum DebrisClass {
    case light, heavy
}

struct DebrisPlacement {
    var cls: DebrisClass
    var at: CGPoint
    var variant: Int = 0
    var scale: CGFloat = 1
    var rotation: Float = 0
}

struct Shape {
    var centre: CGPoint
    var radius: CGFloat
}

enum Hint: String {
    case tap, hold, swell, current, bounce

    var text: String {
        switch self {
        case .tap: return "Tap the water. Ripples carry things to the bank."
        case .hold: return "Hold a finger down. A bigger swell can shift heavy things."
        case .swell: return "Two fingers together sweep a whole cluster."
        case .current: return "Drag along the bank to set a slow current."
        case .bounce: return "Ripples bounce off the rock. Use it."
        }
    }
}

struct LevelSpec: Identifiable {
    let id: String
    let seasonID: String
    let index: Int
    let title: String
    let mosaicCentre: CGPoint
    let mosaicRadius: CGFloat
    let debris: [DebrisPlacement]
    var rocks: [Shape] = []
    var shallows: [Shape] = []
    var hint: Hint? = nil
    /// Bloom stage (0...3, fractional) the garden reaches when this level is done.
    var bloomTarget: Float
}

/// A small deterministic generator so a level lays out the same every time.
private struct Seeded {
    private var state: UInt32
    init(_ seed: UInt32) { state = seed &* 2654435761 &+ 1 }
    mutating func next() -> CGFloat {
        state = state &* 1664525 &+ 1013904223
        return CGFloat(state >> 8) / CGFloat(1 << 24)
    }
    mutating func range(_ r: ClosedRange<CGFloat>) -> CGFloat { r.lowerBound + next() * (r.upperBound - r.lowerBound) }
}

enum Library {

    // MARK: - Seasons

    private static let koiForward: [Float] = [.pi / 2]

    static let winter = Season(
        id: "winter", name: "Winter", order: 1,
        woodblock: ArtSet(
            branch: ["winter_branch_1", "winter_branch_2", "winter_branch_3", "winter_branch_4"],
            branchScale: 0.72, branchInset: 14, branchRightScale: 0.62, branchRightDrop: 70,
            bank: nil, bankSink: 6,
            light: ["snow_1", "snow_2"],
            heavy: ["ice_1", "ice_2", "stone_1"],
            rock: "stone_1",
            koi: ["n_koi_2", "n_koi_6", "n_koi_4"], koiForward: koiForward, koiWaveAmp: 0.075,
            mosaic: "mosaic_winter", petalParticle: "snow_2",
            floor: FloorLook(deep: [0.05, 0.08, 0.19], mid: [0.10, 0.16, 0.32], shallow: [0.28, 0.34, 0.52],
                             waterTint: [0.86, 0.92, 1.00], waterTintStrength: 0.3,
                             siltColour: [0.58, 0.60, 0.64],
                             mosaicCentre: [0.5, 0.5], mosaicRadius: 0.17, mosaicImage: "mosaic_winter", bedImage: "bed_winter"),
            weeds: ["weed_w_1", "weed_w_2", "weed_w_3", "weed_w_4", "weed_w_5"],
            under: [], skaters: [], flyers: [],
            clouds: ["cloud_1", "cloud_2", "cloud_3", "cloud_4"]),
        photographic: nil, rootNote: 440,
        tagline: "The pond sleeps under ice. Wake it gently.")

    static let springWoodblock = ArtSet(
        branch: ["spring_branch_1", "spring_branch_2", "spring_branch_3", "spring_branch_4"],
        branchScale: 0.72, branchInset: 14, branchRightScale: 0.62, branchRightDrop: 70,
        bank: nil, bankSink: 6,
        light: ["petal_n_1", "petal_n_2", "petal_n_3", "petal_n_4", "petal_n_5", "petal_n_6"],
        heavy: ["driftwood_1", "stone_1", "mossstone_1"],
        rock: "mossstone_1",
        koi: ["n_koi_1", "n_koi_5", "n_koi_3"], koiForward: koiForward, koiWaveAmp: 0.075,
        mosaic: "mosaic_spring", petalParticle: "petal_n_2",
        floor: FloorLook(deep: [0.09, 0.22, 0.26], mid: [0.17, 0.38, 0.39], shallow: [0.32, 0.56, 0.52],
                         waterTint: [0.90, 1.00, 0.96], waterTintStrength: 0.3,
                         siltColour: [0.36, 0.38, 0.33],
                         mosaicCentre: [0.5, 0.5], mosaicRadius: 0.17, mosaicImage: "mosaic_spring",
                         bedImage: "bed_spring"),
        weeds: ["weed_1", "weed_2", "weed_3", "weed_4", "weed_5"],
        under: ["tadpole_1", "tadpole_2", "tadpole_3", "boatman_1"],
        skaters: ["skater_1", "skater_2"],
        flyers: ["dragonfly_body"],
        clouds: ["cloud_1", "cloud_2", "cloud_3", "cloud_4"])

    static let springPhoto = ArtSet(
        branch: ["p_branch_1", "p_branch_2", "p_branch_3", "p_branch_4"],
        branchScale: 1.15, branchInset: 40, branchRightScale: 0.62, branchRightDrop: 120,
        bank: "p_bank_spring", bankSink: 34,
        light: ["p_petal_1"],
        heavy: ["p_driftwood_1", "p_stone_1", "p_mossstone_1"],
        rock: "p_mossstone_1",
        koi: ["p_koi_1", "p_koi_5", "p_koi_2"], koiForward: koiForward, koiWaveAmp: 0.16,
        mosaic: "p_mosaic_spring", petalParticle: "p_petal_1",
        floor: FloorLook(deep: [0.050, 0.150, 0.120], mid: [0.145, 0.300, 0.230], shallow: [0.330, 0.520, 0.400],
                         waterTint: [0.86, 1.00, 0.94], waterTintStrength: 0.35,
                         siltColour: [0.42, 0.40, 0.30],
                         mosaicCentre: [0.5, 0.5], mosaicRadius: 0.17, mosaicImage: "p_mosaic_spring"))

    static let spring = Season(id: "spring", name: "Spring", order: 2,
                               woodblock: springWoodblock, photographic: springPhoto, rootNote: 523.25,
                               tagline: "Blossom on the water. Every ripple wakes a little more.")

    static let summer = Season(
        id: "summer", name: "Summer", order: 3,
        woodblock: ArtSet(
            branch: ["summer_branch_1", "summer_branch_2", "summer_branch_3", "summer_branch_4"],
            branchScale: 0.72, branchInset: 14, branchRightScale: 0.62, branchRightDrop: 70,
            bank: nil, bankSink: 6,
            light: ["duckweed_1", "lilypad_3", "lilypad_2"],
            heavy: ["driftwood_1", "mossstone_1", "lilypad_1"],
            rock: "mossstone_1",
            koi: ["n_koi_3", "n_koi_1", "n_koi_6"], koiForward: koiForward, koiWaveAmp: 0.075,
            mosaic: "mosaic_summer", petalParticle: "petal_2",
            floor: FloorLook(deep: [0.03, 0.19, 0.21], mid: [0.07, 0.34, 0.36], shallow: [0.36, 0.55, 0.44],
                             waterTint: [0.92, 1.00, 0.90], waterTintStrength: 0.3,
                             siltColour: [0.40, 0.42, 0.30],
                             mosaicCentre: [0.5, 0.5], mosaicRadius: 0.17, mosaicImage: "mosaic_summer", bedImage: "bed_summer"),
            weeds: ["weed_s_1", "weed_s_2", "weed_s_3", "weed_s_4", "weed_s_5"],
            under: ["tadpole_2", "boatman_1", "tadpole_3"], skaters: ["skater_1", "skater_2"], flyers: ["dragonfly_body"],
            clouds: ["cloud_1", "cloud_2", "cloud_3", "cloud_4"]),
        photographic: nil, rootNote: 587.33,
        tagline: "Lotus and long light. The koi are bold now.")

    static let autumn = Season(
        id: "autumn", name: "Autumn", order: 4,
        woodblock: ArtSet(
            branch: ["autumn_branch_1", "autumn_branch_2", "autumn_branch_3", "autumn_branch_4"],
            branchScale: 0.72, branchInset: 14, branchRightScale: 0.62, branchRightDrop: 70,
            bank: nil, bankSink: 6,
            light: ["leaf_1", "leaf_2", "leaf_3"],
            heavy: ["driftwood_1", "stone_1", "mossstone_1"],
            rock: "mossstone_1",
            koi: ["n_koi_5", "n_koi_4", "n_koi_2"], koiForward: koiForward, koiWaveAmp: 0.075,
            mosaic: "mosaic_autumn", petalParticle: "leaf_2",
            floor: FloorLook(deep: [0.04, 0.13, 0.15], mid: [0.09, 0.26, 0.28], shallow: [0.38, 0.44, 0.30],
                             waterTint: [1.00, 0.94, 0.80], waterTintStrength: 0.35,
                             siltColour: [0.46, 0.38, 0.24],
                             mosaicCentre: [0.5, 0.5], mosaicRadius: 0.17, mosaicImage: "mosaic_autumn", bedImage: "bed_autumn"),
            weeds: ["weed_a_1", "weed_a_2", "weed_a_3", "weed_a_4", "weed_a_5"],
            under: ["boatman_1"], skaters: ["skater_2"], flyers: [],
            clouds: ["cloud_1", "cloud_2", "cloud_3", "cloud_4"]),
        photographic: nil, rootNote: 392,
        tagline: "Maple on the pond. The year settles.")

    static let seasons: [Season] = [winter, spring, summer, autumn]

    // MARK: - Levels

    /// Six levels per season, the same escalation each time with the
    /// season's own dressing. Level one teaches the tap by itself; two adds a
    /// rock to bounce off; three a heavy piece that needs a held swell; four
    /// a packed cluster that wants two fingers; five shallows that slow the
    /// waves and a current to lean on; six everything at once.
    static let levels: [LevelSpec] = seasons.flatMap { season in (1...6).map { build(season: season, index: $0) } }

    static let springOne: LevelSpec = levels.first { $0.id == "spring-1" }!

    private static func build(season: Season, index: Int) -> LevelSpec {
        var rng = Seeded(UInt32(season.order * 100 + index))
        let titles = ["one", "two", "three", "four", "five", "six"]
        let title = "\(season.name), \(titles[index - 1])"

        // The roundel wanders a little from level to level.
        let centre = CGPoint(x: 0.5 + rng.range(-0.06...0.06), y: 0.48 + rng.range(-0.05...0.05))
        let radius: CGFloat = [0.17, 0.165, 0.17, 0.18, 0.16, 0.185][index - 1]

        func scatter(_ n: Int, cls: DebrisClass, spread: CGFloat, avoid: [CGPoint] = []) -> [DebrisPlacement] {
            var out: [DebrisPlacement] = []
            var tries = 0
            while out.count < n, tries < 400 {
                tries += 1
                // Radii are fractions of the height; the screen is about 2.17
                // times taller than wide, so a circle needs the x stretched.
                let tall: CGFloat = 2.17
                let a = rng.range(0...(2 * .pi))
                let r = radius * spread * rng.range(0.15...1.0)
                let p = CGPoint(x: centre.x + cos(a) * r * tall, y: centre.y + sin(a) * r)
                let minGap: CGFloat = cls == .light ? 0.045 : 0.09
                let clash = (out.map(\.at) + avoid).contains { hypot(($0.x - p.x) / tall, $0.y - p.y) < minGap }
                if clash { continue }
                out.append(DebrisPlacement(cls: cls, at: p, variant: out.count,
                                           scale: cls == .light ? rng.range(0.85...1.15) : rng.range(0.9...1.1),
                                           rotation: Float(rng.range(0...(2 * .pi)))))
            }
            return out
        }

        let shoulder = CGPoint(x: centre.x + 0.26, y: centre.y - 0.15)
        let farSide = CGPoint(x: centre.x - 0.26, y: centre.y + 0.13)
        var debris: [DebrisPlacement] = []
        var rocks: [Shape] = []
        var shallows: [Shape] = []
        var hint: Hint? = nil

        switch index {
        case 1:
            debris = scatter(7, cls: .light, spread: 0.85)
            hint = .tap
        case 2:
            debris = scatter(8, cls: .light, spread: 0.9)
            rocks = [Shape(centre: shoulder, radius: 0.055)]
            hint = .bounce
        case 3:
            let heavy = scatter(1, cls: .heavy, spread: 0.7)
            debris = heavy + scatter(6, cls: .light, spread: 0.9, avoid: heavy.map(\.at))
            rocks = [Shape(centre: shoulder, radius: 0.05)]
            hint = .tap
        case 4:
            debris = scatter(15, cls: .light, spread: 0.7)
            rocks = [Shape(centre: farSide, radius: 0.05)]
            hint = .swell
        case 5:
            let heavy = scatter(2, cls: .heavy, spread: 0.75)
            debris = heavy + scatter(7, cls: .light, spread: 0.9, avoid: heavy.map(\.at))
            shallows = [Shape(centre: centre, radius: radius * 1.9)]
            hint = .current
        default:
            let heavy = scatter(2, cls: .heavy, spread: 0.8)
            debris = heavy + scatter(11, cls: .light, spread: 0.95, avoid: heavy.map(\.at))
            rocks = [Shape(centre: shoulder, radius: 0.05), Shape(centre: farSide, radius: 0.045)]
            shallows = [Shape(centre: CGPoint(x: centre.x + 0.1, y: centre.y + 0.22), radius: 0.16)]
            hint = nil
        }

        // Tidying, not uncovering: the roundel is gone. Pieces are strewn over
        // the pond and the level is done when the water is clear of them.
        if index == 1 {
            debris = (0..<8).map { i in
                DebrisPlacement(cls: .light,
                                at: CGPoint(x: rng.range(0.16...0.84), y: rng.range(0.24...0.72)),
                                variant: i, scale: rng.range(0.85...1.15), rotation: Float(rng.range(0...(2 * .pi))))
            }
        }
        return LevelSpec(id: "\(season.id)-\(index)", seasonID: season.id, index: index, title: title,
                         mosaicCentre: centre, mosaicRadius: 0, debris: debris,
                         rocks: rocks, shallows: shallows, hint: hint,
                         bloomTarget: Float(index) * 0.5)
    }

    static func season(for level: LevelSpec) -> Season {
        seasons.first { $0.id == level.seasonID } ?? spring
    }

    static func season(id: String) -> Season? {
        seasons.first { $0.id == id }
    }

    static func level(id: String) -> LevelSpec? {
        levels.first { $0.id == id }
    }

    static func levels(in season: Season) -> [LevelSpec] {
        levels.filter { $0.seasonID == season.id }
    }

    static func level(after level: LevelSpec) -> LevelSpec? {
        guard let i = levels.firstIndex(where: { $0.id == level.id }), i + 1 < levels.count else { return nil }
        return levels[i + 1]
    }
}
