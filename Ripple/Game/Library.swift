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
    var stones: [String] = ["stone_a_1", "stone_a_2", "stone_a_3", "stone_a_4", "stone_a_5", "stone_a_6", "stone_a_7", "stone_a_8"]
    var gravel: [String] = ["gravel_1", "gravel_2", "gravel_3", "gravel_4"]
    var sand: [String] = ["sand_1", "sand_2", "sand_3"]
    var reeds: [String] = []
    /// Flowering clumps for the bank, planted among the reeds.
    var flowers: [String] = []
    /// Small fish that swim in shoals, one sprite per shoal.
    var shoal: [String] = []
    var frog: (frog: String, pad: String)? = nil
    var newt: String? = nil
    var heron: String? = nil
    /// Chunks of broken ice, for the frozen season.
    var iceFragments: [String] = []
    /// Something falling all the time (snow), as a sprite name.
    var ambientFall: String? = nil
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

/// What a floating piece is. Petals, leaves and logs are `natural`; a seed
/// is a light piece that never clears at a bank and roots in the shallows
/// instead. The can and the bottle are kept for the solids they draw as,
/// though no level places one any more.
enum DebrisKind {
    case natural, seed, can, bottle, packet, bag

    var isRubbish: Bool {
        switch self {
        case .natural, .seed: return false
        default: return true
        }
    }
    var isSeed: Bool { self == .seed }
    var sprite: String? {
        switch self {
        case .natural, .seed: return nil
        case .can: return "rubbish_can"
        case .bottle: return "rubbish_bottle"
        case .packet: return "rubbish_packet"
        case .bag: return "rubbish_bag"
        }
    }
    var radius: CGFloat {
        switch self {
        case .natural: return 0
        case .seed: return 13
        case .can: return 30
        case .bottle: return 34
        case .packet: return 28
        case .bag: return 40
        }
    }
    /// Multipliers on the natural piece of the same class: mass, drag, how
    /// hard a slope shoves it, the heavy lift threshold, and how much the
    /// current carries it. A seed is a little heavier than a petal and
    /// settles sooner, so it can come to rest where it is carried.
    var mass: Float { switch self { case .natural: return 1; case .seed: return 1.3; case .can: return 0.6; case .bottle: return 0.6; case .packet: return 0.8; case .bag: return 0.7 } }
    var drag: Float { switch self { case .natural: return 1; case .seed: return 1.3; case .can: return 1.1; case .bottle: return 0.55; case .packet: return 0.85; case .bag: return 0.8 } }
    var gain: Float { switch self { case .natural: return 1; case .seed: return 0.9; case .can: return 1; case .bottle: return 1.4; case .packet: return 1.1; case .bag: return 0.9 } }
    var threshold: Float { switch self { case .natural, .seed: return 1; case .can: return 0.8; default: return 1 } }
    var currentPush: Float { switch self { case .natural: return 1; case .seed: return 0.9; case .can: return 0.6; case .bottle: return 1.2; case .packet: return 1.1; case .bag: return 1.8 } }

    /// Rubbish drawn as a body rather than a cut-out. Everything else is
    /// paper and returns nil.
    var solid: SolidBody? {
        switch self {
        case .can: return SolidBody(shape: 0, radius: 0.5, length: 1.1)
        case .bottle: return SolidBody(shape: 1, radius: 0.36, length: 1.9)
        default: return nil
        }
    }
}

/// A body drawn as a mesh rather than a cut-out: which shape it is, how fat
/// and how long as fractions of the piece's radius, how far above the water
/// its axis sits as a fraction of its own, and whether it rolls when the
/// water shoves it sideways.
struct SolidBody {
    var shape: UInt32
    var radius: CGFloat
    var length: CGFloat
    var lift: CGFloat = 0.55
    var rolls: Bool = true
}

/// A heavy natural piece is a body too, and which one is written on the
/// sprite the season handed it: driftwood is a log, the stones are stones.
/// The photographic set prefixes its names, so the prefix comes off first.
enum NaturalSolid {
    case log, stone, mossyStone

    static func forSprite(_ name: String) -> NaturalSolid? {
        let n = name.hasPrefix("p_") ? String(name.dropFirst(2)) : name
        if n.hasPrefix("driftwood") { return .log }
        if n.hasPrefix("mossstone") { return .mossyStone }
        if n.hasPrefix("stone") { return .stone }
        return nil
    }

    /// A log rolls under the water the way a barrel does. A stone sits low
    /// and does not roll at all, so its roll slot carries the seed of its
    /// lumps instead.
    var body: SolidBody {
        switch self {
        case .log: return SolidBody(shape: 3, radius: 0.33, length: 2.1, lift: 0.45)
        case .stone, .mossyStone: return SolidBody(shape: 2, radius: 0.95, length: 1.35, lift: 0.35, rolls: false)
        }
    }
}

struct DebrisPlacement {
    var cls: DebrisClass
    var at: CGPoint
    var variant: Int = 0
    var scale: CGFloat = 1
    var rotation: Float = 0
    var kind: DebrisKind = .natural
}

/// Something on the water that only a big enough crest wakes: a closed
/// lily bud that opens, a bell on a bamboo float that rings. Position is a
/// fraction of the world; `threshold` is water height, where a tap's ring
/// passes at a few hundredths and a held swell lifts by tenths.
enum TargetKind {
    case bud, bell
}

struct TargetSpec {
    var kind: TargetKind
    var at: CGPoint
    var threshold: Float = 0.055
}

struct Shape {
    var centre: CGPoint
    var radius: CGFloat
}

enum Hint: String {
    case tap, hold, swell, bounce, ice, twin, lens, order, tilt
    case call, shoal, shy, seeds, silt, duckweed, leaves, bamboo, chime, pool, still

    var text: String {
        switch self {
        case .tap: return "Tap the water. Ripples carry things to the bank."
        case .ice: return "Tap the ice to crack it, tap inside the cracks to break through. Slide a finger to feel it."
        case .hold: return "Hold a finger on the water. The swell it gathers can shift heavy things."
        case .swell: return "Two fingers drawn together sweep a whole cluster."
        case .bounce: return "Ripples bounce off the stones. A curve of them throws a ripple back."
        case .twin: return "Two taps a little apart. Where their ripples meet they lift what one cannot."
        case .tilt: return "Two fingers drawn slowly up the screen lean the view over. Pinch to zoom."
        case .lens: return "Shallow water slows a ripple and bends it inward. A wave that crosses the sandbank arrives tall."
        case .order: return "No water passes a log, and neither does the shoal. Move the logs first."
        case .call: return "Hold a finger on the water. The koi will come up to it."
        case .shoal: return "A quick stroke lays a wake. The shoal will follow it."
        case .shy: return "Something is hiding. Let the water over it go still, then hold a finger a little way off."
        case .seeds: return "Seeds take root in the shallows. Carry them there."
        case .silt: return "The bed is silted. Every ripple clears a little."
        case .duckweed: return "Sweep the duckweed aside with a stroke. It gathers at the banks."
        case .leaves: return "Leaves are still falling. Two fingers thrown across the water make a gust that sweeps them."
        case .bamboo: return "A swell over the spout fills the bamboo. Full, it tips and knocks."
        case .chime: return "The stones sing when a wave passes. Play them in the order the pond hums."
        case .pool: return "Push the water at the lip with a slow drag, and again as it comes back. Every crest that spills over fills the pool a little."
        case .still: return "Let the water go glassy and wait."
        }
    }
}

struct LevelSpec: Identifiable {
    let id: String
    let seasonID: String
    let index: Int
    let title: String
    /// The level's own short name, shown over the goal when it opens: "The
    /// sheet", "Silt", "Dusk". The title stays as the chapter number.
    var name: String = ""
    /// What the player is here to do, one entry per idea, in the order the
    /// pond wants them. Positions inside are fractions of the world until
    /// the controller places them.
    var goals: [GoalSpec]
    var debris: [DebrisPlacement] = []
    var rocks: [Shape] = []
    var shallows: [Shape] = []
    /// Lily pads: they block ripples like stones and cannot be tapped, but
    /// they lie flat on the water.
    var pads: [Shape] = []
    var targets: [TargetSpec] = []
    var hint: Hint? = nil
    /// Bloom stage (0...3, fractional) the garden reaches when this level is done.
    var bloomTarget: Float
    /// The pond starts frozen over as one sheet.
    var frozen: Bool = false
    /// Rain falls on the pond: drops all over the water, and the rain's air.
    var rain: Bool = false
    /// A stream runs into the pond here, as a fraction of the world, on the
    /// rim. It sends a ripple train and a slow current in. Nil on a still pond.
    var inlet: CGPoint? = nil
    /// Duckweed lies over the water as a film.
    var duckweed: Bool = false
    /// Leaves keep falling onto the water until this many have landed.
    var leaves: Int = 0
    /// The level is played in the last light of the day.
    var dusk: Bool = false
    /// Where the old silt roundel sat. Kept for the floor look, which still
    /// carries the slots; no level has a roundel now.
    var mosaicCentre = CGPoint(x: 0.5, y: 0.5)
    var mosaicRadius: CGFloat = 0

    /// The line shown when the level opens: every goal's own line, in order.
    var goal: String { goals.map(\.text).joined(separator: " ") }

    func has(_ test: (GoalKind) -> Bool) -> Bool { goals.contains { test($0.kind) } }
    var wantsSilt: Bool { has { if case .clearSilt = $0 { return true }; return false } }
    var wantsFilm: Bool { duckweed || has { if case .partDuckweed = $0 { return true }; return false } }
    var wantsKoi: Bool {
        has {
            switch $0 {
            case .callKoi, .koiOpensBud, .temptShyKoi: return true
            default: return false
            }
        }
    }
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
            clouds: ["cloud_1", "cloud_2", "cloud_3", "cloud_4"],
            reeds: ["reed_w_1", "reed_w_2", "reed_w_3", "reed_w_4"],
            flowers: ["flower_w_1", "flower_w_2"],
            shoal: ["minnow_1"],
            iceFragments: ["ice_1", "ice_2", "ice_3", "ice_5", "ice_9", "ice_10"],
            ambientFall: "snow_2"),
        photographic: nil, rootNote: 440,
        tagline: "The pond sleeps under ice. Wake it gently.")

    static let springWoodblock = ArtSet(
        // Buds from the first level: the bare branch reads as winter still.
        branch: ["spring_branch_2", "spring_branch_3", "spring_branch_4", "spring_branch_4"],
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
        weeds: ["weed_c_1", "weed_c_2", "weed_c_3", "weed_c_4"],
        under: ["tadpole_1", "tadpole_2", "tadpole_3", "boatman_1"],
        skaters: ["skater_1", "skater_2"],
        flyers: ["dragonfly_body"],
        clouds: ["cloud_s_1", "cloud_s_2", "cloud_s_3", "cloud_s_4"],
        stones: ["stone_a_1", "stone_a_2", "stone_a_3", "stone_a_4", "stone_a_5", "stone_a_6", "stone_a_7", "stone_a_8"],
        gravel: ["gravel_1", "gravel_2", "gravel_3", "gravel_4"],
        sand: ["sand_1", "sand_2", "sand_3"],
        reeds: ["reed_s_1", "reed_s_2", "reed_s_3", "reed_s_4"],
        flowers: ["flower_s_1", "flower_s_2", "flower_s_3", "fern_1"],
        shoal: ["minnow_1", "stickleback_1"],
        frog: ("frog_top", "lilypad_frog"),
        newt: "newt_1",
        heron: "heron_shadow")

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
            clouds: ["cloud_1", "cloud_2", "cloud_3", "cloud_4"],
            reeds: ["reed_su_1", "reed_su_2", "reed_su_3", "reed_su_4", "iris_1", "iris_2"],
            flowers: ["flower_su_1", "flower_su_2", "flower_su_3", "fern_1"],
            shoal: ["rudd_1", "minnow_2"],
            frog: ("frog_top", "lilypad_frog"), newt: "newt_1"),
        photographic: nil, rootNote: 587.33,
        tagline: "Lotus and long light. The koi are bold now.")

    static let autumn = Season(
        id: "autumn", name: "Autumn", order: 4,
        woodblock: ArtSet(
            // The first painting is summer green, so the year starts turned:
            // yellow, then orange, then red.
            branch: ["autumn_branch_2", "autumn_branch_3", "autumn_branch_4", "autumn_branch_4"],
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
            clouds: ["cloud_1", "cloud_2", "cloud_3", "cloud_4"],
            reeds: ["reed_a_1", "reed_a_2", "reed_a_3", "reed_a_4", "bulrush_1", "bulrush_2"],
            flowers: ["flower_a_1", "flower_a_2", "flower_a_3"],
            shoal: ["stickleback_2"], newt: "newt_1"),
        photographic: nil, rootNote: 392,
        tagline: "Maple on the pond. The year settles.")

    static let seasons: [Season] = [winter, spring, summer, autumn]

    // MARK: - Levels

    /// Six levels per season, each around one idea that lives in the water
    /// and its life. Winter is ice and waking; spring is silt and tending;
    /// summer is duckweed and the lens; autumn is leaves and moving water.
    static let levels: [LevelSpec] = seasons.flatMap { season in
        (1...6).compactMap { designed["\(season.id)-\($0)"] }
    }

    // MARK: - Designed levels

    /// Levels laid out by hand. Positions are fractions of the world; radii
    /// are fractions of its height, and the world is about 2.17 times
    /// taller than wide, so a circle of things needs its x offsets
    /// stretched by that.
    private static let tall: CGFloat = 2.17

    private static func ring(_ n: Int, centre c: CGPoint, radius r: CGFloat, from a0: CGFloat, to a1: CGFloat) -> [CGPoint] {
        (0..<n).map { k in
            let a = a0 + (a1 - a0) * CGFloat(k) / CGFloat(max(1, n - 1))
            return CGPoint(x: c.x + cos(a) * r * tall, y: c.y + sin(a) * r)
        }
    }

    static let designed: [String: LevelSpec] = {
        var out: [String: LevelSpec] = [:]
        winterLevels(into: &out)
        springLevels(into: &out)
        summerLevels(into: &out)
        autumnLevels(into: &out)
        return out
    }()

    /// One goal with its opening line and what it leaves alive in the pool.
    private static func goal(_ kind: GoalKind, _ text: String, wakes: WokeToken...) -> GoalSpec {
        GoalSpec(kind: kind, text: text, wakes: Set(wakes))
    }

    /// Seeds strewn over a few places, each turned its own way.
    private static func seeds(_ points: [CGPoint]) -> [DebrisPlacement] {
        points.enumerated().map { i, p in
            DebrisPlacement(cls: .light, at: p, variant: i, scale: 1, rotation: Float(i) * 0.83, kind: .seed)
        }
    }

    /// A log lying on the water, drawn as a body.
    private static func log(at p: CGPoint, rotation: Float = 0) -> DebrisPlacement {
        DebrisPlacement(cls: .heavy, at: p, variant: 0, scale: 1, rotation: rotation)
    }

    /// Two rocks either side of a channel at `y`, and the gate between them.
    private static func channel(y: CGFloat, x0: CGFloat = 0.30, x1: CGFloat = 0.70, radius: CGFloat = 0.05)
        -> (rocks: [Shape], gate: (CGPoint, CGPoint)) {
        let rocks = [Shape(centre: CGPoint(x: x0, y: y), radius: radius),
                     Shape(centre: CGPoint(x: x1, y: y), radius: radius)]
        // The gate runs from the inner edge of one rock to the other.
        let inset = radius * tall * 1.2
        return (rocks, (CGPoint(x: x0 + inset, y: y), CGPoint(x: x1 - inset, y: y)))
    }

    private static let callLine = "Call the koi up with a held finger."
    private static let shoalLine = "Lead the shoal through the gap."

    // MARK: Winter

    private static func winterLevels(into out: inout [String: LevelSpec]) {

        // Winter one, "the sheet": the pond under one lid of ice. A first tap
        // only cracks a ring; a second inside that ring takes it out, and ice
        // away from open water is solid, so the hole has to be worked outward
        // until the sheet is gone.
        out["winter-1"] = LevelSpec(id: "winter-1", seasonID: "winter", index: 1, title: "Winter, one", name: "The sheet",
                                    goals: [goal(.breakIce, "Break through the ice.", wakes: .clear)],
                                    hint: .ice, bloomTarget: 0.5, frozen: true)

        // Winter two, "the sleeper": a koi lies on the bed in the middle of
        // the pond, asleep under the sheet. Open the ice over it and it
        // stirs; a held finger on the open water brings it up.
        out["winter-2"] = LevelSpec(id: "winter-2", seasonID: "winter", index: 2, title: "Winter, two", name: "Under the ice",
                                    goals: [goal(.callKoi(at: CGPoint(x: 0.5, y: 0.5), radius: 0.06), callLine, wakes: .koi)],
                                    hint: .call, bloomTarget: 1.0, frozen: true)

        // Winter three, "the pocket": two rocks narrow the pond to a channel
        // and the shoal is penned on one side of it under the ice. Open a
        // lane and lay a wake through the gap; the shoal streams after it.
        do {
            let c = channel(y: 0.45)
            out["winter-3"] = LevelSpec(id: "winter-3", seasonID: "winter", index: 3, title: "Winter, three", name: "The pocket",
                                        goals: [goal(.leadShoal(gate: c.gate), shoalLine, wakes: .shoal)],
                                        rocks: c.rocks, hint: .shoal, bloomTarget: 1.5, frozen: true)
        }

        // Winter four, "the bell under the ice": a bell on its float, frozen
        // in. Open the sheet over it, then send a wave tall enough to ring it.
        do {
            let bell = CGPoint(x: 0.5, y: 0.36)
            out["winter-4"] = LevelSpec(id: "winter-4", seasonID: "winter", index: 4, title: "Winter, four", name: "The bell",
                                        goals: [goal(.wakeTarget(.bell, at: bell, threshold: 0.05), "Ring the bell with a wave.", wakes: .chime)],
                                        targets: [TargetSpec(kind: .bell, at: bell, threshold: 0.05)],
                                        hint: .hold, bloomTarget: 2.0, frozen: true)
        }

        // Winter five, "the thaw": open water for the first time, and nothing
        // to do but leave it alone. Glassy for seven seconds and the moon
        // comes up in it.
        out["winter-5"] = LevelSpec(id: "winter-5", seasonID: "winter", index: 5, title: "Winter, five", name: "Thaw",
                                    goals: [goal(.stillness(seconds: 7), "Let the pond go still.", wakes: .moon)],
                                    hint: .still, bloomTarget: 2.5)

        // Winter six, "waking": the sheet again, with the koi asleep below
        // the channel and the shoal penned above it. Both want bringing out.
        do {
            let c = channel(y: 0.40)
            out["winter-6"] = LevelSpec(id: "winter-6", seasonID: "winter", index: 6, title: "Winter, six", name: "The whole pond",
                                        goals: [goal(.callKoi(at: CGPoint(x: 0.5, y: 0.64), radius: 0.06), callLine, wakes: .koi),
                                                goal(.leadShoal(gate: c.gate), shoalLine, wakes: .shoal)],
                                        rocks: c.rocks, hint: .call, bloomTarget: 3.0, frozen: true)
        }
    }

    // MARK: Spring

    private static func springLevels(into out: inout [String: LevelSpec]) {

        // Spring one, "silt": the whole bed is clouded. Every ripple scours a
        // little of it off; the pond is clear when nine tenths of it is.
        out["spring-1"] = LevelSpec(id: "spring-1", seasonID: "spring", index: 1, title: "Spring, one", name: "Silt",
                                    goals: [goal(.clearSilt(clean: 0.9), "Clear the silt from the bed.", wakes: .clear)],
                                    hint: .silt, bloomTarget: 0.5)

        // Spring two, "seeds": three lotus seeds float at the foot of the
        // pond and a shallows lies at its head. A seed that rests in the
        // shallows takes root; the ripples have to carry them there.
        do {
            let bed = Shape(centre: CGPoint(x: 0.5, y: 0.22), radius: 0.09)
            out["spring-2"] = LevelSpec(id: "spring-2", seasonID: "spring", index: 2, title: "Spring, two", name: "Seeds",
                                        goals: [goal(.rootSeeds(shallows: bed, count: 3), "Carry the seeds to the shallows.", wakes: .seeds)],
                                        debris: seeds([CGPoint(x: 0.34, y: 0.72), CGPoint(x: 0.52, y: 0.80), CGPoint(x: 0.68, y: 0.70)]),
                                        shallows: [bed], hint: .seeds, bloomTarget: 1.0)
        }

        // Spring three, "the bud": a closed bud on the water. No crest opens
        // it; a koi called up beneath it nudges it open.
        do {
            let bud = CGPoint(x: 0.5, y: 0.36)
            out["spring-3"] = LevelSpec(id: "spring-3", seasonID: "spring", index: 3, title: "Spring, three", name: "The bud",
                                        goals: [goal(.koiOpensBud(bud: bud), "Call the koi up beneath the bud.", wakes: .bud, .koi)],
                                        targets: [TargetSpec(kind: .bud, at: bud, threshold: 0.125)],
                                        hint: .call, bloomTarget: 1.5)
        }

        // Spring four, "the log": a log lies across the channel between two
        // rocks. One tap's ring runs under it; two rings that meet lift it.
        // With the channel open the shoal can be led through.
        do {
            let c = channel(y: 0.46, x0: 0.22, x1: 0.78)
            out["spring-4"] = LevelSpec(id: "spring-4", seasonID: "spring", index: 4, title: "Spring, four", name: "The log",
                                        goals: [goal(.clearDebris, "Move the log out of the channel.", wakes: .clear),
                                                goal(.leadShoal(gate: c.gate), shoalLine, wakes: .shoal)],
                                        debris: [log(at: CGPoint(x: 0.5, y: 0.46), rotation: 0)],
                                        rocks: c.rocks, hint: .twin, bloomTarget: 2.0)
        }

        // Spring five, "the shishi-odoshi": a bamboo rocker on the top bank.
        // A crest over its spout fills it; full, it tips and knocks on its
        // stone. Three knocks.
        out["spring-5"] = LevelSpec(id: "spring-5", seasonID: "spring", index: 5, title: "Spring, five", name: "Shishi-odoshi",
                                    goals: [goal(.shishiOdoshi(at: CGPoint(x: 0.5, y: 0.06), knocks: 3),
                                                 "Fill the bamboo until it knocks three times.", wakes: .bamboo)],
                                    hint: .bamboo, bloomTarget: 2.5)

        // Spring six, "tending": silt over the bed, seeds to carry to the
        // shallows, and a koi to call up once the water is clear enough to
        // see it.
        do {
            let bed = Shape(centre: CGPoint(x: 0.5, y: 0.20), radius: 0.09)
            out["spring-6"] = LevelSpec(id: "spring-6", seasonID: "spring", index: 6, title: "Spring, six", name: "The garden wakes",
                                        goals: [goal(.clearSilt(clean: 0.9), "Clear the silt from the bed.", wakes: .clear),
                                                goal(.rootSeeds(shallows: bed, count: 3), "Carry the seeds to the shallows.", wakes: .seeds),
                                                goal(.callKoi(at: CGPoint(x: 0.5, y: 0.52), radius: 0.06), callLine, wakes: .koi)],
                                        debris: seeds([CGPoint(x: 0.30, y: 0.74), CGPoint(x: 0.50, y: 0.82), CGPoint(x: 0.70, y: 0.72)]),
                                        shallows: [bed], hint: .silt, bloomTarget: 3.0)
        }
    }

    // MARK: Summer

    private static func summerLevels(into out: inout [String: LevelSpec]) {

        // Summer one, "duckweed": a film of weed over the whole pond. Wakes
        // and swells part it; it drifts to the banks and stays there.
        out["summer-1"] = LevelSpec(id: "summer-1", seasonID: "summer", index: 1, title: "Summer, one", name: "Duckweed",
                                    goals: [goal(.partDuckweed(cover: 0.12), "Part the duckweed.", wakes: .clear)],
                                    hint: .duckweed, bloomTarget: 0.5, duckweed: true)

        // Summer two, "the lens": a lily bud sleeps inside a ring of pads
        // with one gap facing down the pond. Below the gap a sandbank
        // shallows the water; a ripple crossing it slows in the middle and
        // bends inward, so a tap from the right spot lands a crest through
        // the gap on the bud. Taps on the pads do nothing.
        do {
            let c = CGPoint(x: 0.5, y: 0.34)
            var pads = ring(6, centre: c, radius: 0.072, from: -2.62 + 0.2, to: 2.62 - 0.2).map { Shape(centre: $0, radius: 0.027) }
            pads.removeAll { abs($0.centre.x - c.x) < 0.02 && $0.centre.y > c.y }   // keep the gap open below
            let bank = Shape(centre: CGPoint(x: 0.5, y: 0.56), radius: 0.10)
            out["summer-2"] = LevelSpec(id: "summer-2", seasonID: "summer", index: 2, title: "Summer, two", name: "The lens",
                                        goals: [goal(.wakeTarget(.bud, at: c, threshold: 0.05), "Wake the lily bud with a wave.", wakes: .bud)],
                                        shallows: [bank], pads: pads,
                                        targets: [TargetSpec(kind: .bud, at: c, threshold: 0.05)],
                                        hint: .lens, bloomTarget: 1.0)
        }

        // Summer three, "the pad gap": a ring of pads with one gap at the
        // bottom. The shoal goes where a wake leads it, and only through
        // the gap.
        do {
            let c = CGPoint(x: 0.5, y: 0.44)
            let pads = ring(8, centre: c, radius: 0.085, from: .pi / 2 + 0.55, to: .pi / 2 + 2 * .pi - 0.55)
                .map { Shape(centre: $0, radius: 0.030) }
            let gate = (CGPoint(x: 0.42, y: 0.51), CGPoint(x: 0.58, y: 0.51))
            out["summer-3"] = LevelSpec(id: "summer-3", seasonID: "summer", index: 3, title: "Summer, three", name: "The gap",
                                        goals: [goal(.leadShoal(gate: gate), shoalLine, wakes: .shoal)],
                                        pads: pads, hint: .shoal, bloomTarget: 1.5)
        }

        // Summer four, "the suikinkutsu": five stones in an arc in the
        // shallows at the head of the pond. A crest over a stone sounds a
        // note; the pond hums the phrase, and the stones want playing in
        // that order.
        do {
            let bed = Shape(centre: CGPoint(x: 0.5, y: 0.22), radius: 0.16)
            let stones = ring(5, centre: CGPoint(x: 0.5, y: 0.27), radius: 0.11, from: -2.7, to: -0.44)
            out["summer-4"] = LevelSpec(id: "summer-4", seasonID: "summer", index: 4, title: "Summer, four", name: "Suikinkutsu",
                                        goals: [goal(.suikinkutsu(stones: stones, order: [0, 2, 1, 3, 4]),
                                                     "Play the stones in the order the pond hums.", wakes: .chime)],
                                        shallows: [bed], hint: .chime, bloomTarget: 2.0)
        }

        // Summer five, "the shy koi": a clump of pads in the middle with a
        // koi hiding under them, and duckweed over everything. It only comes
        // out to a finger held a little way off over water that has been
        // still a while.
        do {
            let c = CGPoint(x: 0.5, y: 0.42)
            var pads = ring(6, centre: c, radius: 0.045, from: 0, to: 2 * .pi * 5 / 6).map { Shape(centre: $0, radius: 0.030) }
            pads.append(Shape(centre: c, radius: 0.034))
            out["summer-5"] = LevelSpec(id: "summer-5", seasonID: "summer", index: 5, title: "Summer, five", name: "The shy koi",
                                        goals: [goal(.temptShyKoi(home: Shape(centre: c, radius: 0.11)), "Tempt the shy koi out.", wakes: .shy)],
                                        pads: pads, hint: .shy, bloomTarget: 2.5, duckweed: true)
        }

        // Summer six, "high summer": rain on the duckweed, a bud in its ring
        // of pads at the head of the pond, and the shoal to lead through the
        // channel below.
        do {
            let bud = CGPoint(x: 0.5, y: 0.28)
            var pads = ring(6, centre: bud, radius: 0.072, from: -2.42, to: 2.42).map { Shape(centre: $0, radius: 0.027) }
            pads.removeAll { abs($0.centre.x - bud.x) < 0.02 && $0.centre.y > bud.y }
            let c = channel(y: 0.62)
            out["summer-6"] = LevelSpec(id: "summer-6", seasonID: "summer", index: 6, title: "Summer, six", name: "Summer rain",
                                        goals: [goal(.partDuckweed(cover: 0.12), "Part the duckweed.", wakes: .clear),
                                                goal(.wakeTarget(.bud, at: bud, threshold: 0.05), "Wake the lily bud with a wave.", wakes: .bud),
                                                goal(.leadShoal(gate: c.gate), shoalLine, wakes: .shoal)],
                                        rocks: c.rocks, pads: pads,
                                        targets: [TargetSpec(kind: .bud, at: bud, threshold: 0.05)],
                                        hint: .duckweed, bloomTarget: 3.0, rain: true, duckweed: true)
        }
    }

    // MARK: Autumn

    private static func autumnLevels(into out: inout [String: LevelSpec]) {

        // Autumn one, "the leaves that fall": leaves keep coming down on the
        // water for a while. A gust sweeps them; they cluster and clog. The
        // pond is done when the ones that fell are all at the banks.
        out["autumn-1"] = LevelSpec(id: "autumn-1", seasonID: "autumn", index: 1, title: "Autumn, one", name: "Falling leaves",
                                    goals: [goal(.clearDebris, "Send the fallen leaves to the banks.", wakes: .clear)],
                                    hint: .leaves, bloomTarget: 0.5, leaves: 12)

        // Autumn two, "the dry pool": a walled hollow in the top bank, dry,
        // with a low sill toward the pond. Rocking the pond in rhythm builds
        // a wave that spills over the sill; every spill fills the pool a
        // little, and full, it joins the pond.
        out["autumn-2"] = LevelSpec(id: "autumn-2", seasonID: "autumn", index: 2, title: "Autumn, two", name: "The dry pool",
                                    goals: [goal(.fillPool(lip: CGPoint(x: 0.5, y: 0.145),
                                                           pool: Shape(centre: CGPoint(x: 0.5, y: 0.08), radius: 0.05),
                                                           lipHeight: 0.03), "Fill the dry pool.", wakes: .pool)],
                                    hint: .pool, bloomTarget: 1.0)

        // Autumn three, "the weir": two logs and two stones close the pond
        // right across. No water gets past a log, and neither does the
        // shoal. The logs go first, then the shoal follows a wake through.
        do {
            let c = channel(y: 0.48, x0: 0.16, x1: 0.84)
            out["autumn-3"] = LevelSpec(id: "autumn-3", seasonID: "autumn", index: 3, title: "Autumn, three", name: "The weir",
                                        goals: [goal(.clearDebris, "Move the logs out of the way.", wakes: .clear),
                                                goal(.leadShoal(gate: c.gate), shoalLine, wakes: .shoal)],
                                        debris: [log(at: CGPoint(x: 0.38, y: 0.50)), log(at: CGPoint(x: 0.60, y: 0.50))],
                                        rocks: c.rocks, hint: .order, bloomTarget: 1.5)
        }

        // Autumn four, "under the log": leaves falling, gusts to sweep them,
        // and a koi hiding under a log in the middle of the pond. Still
        // water over the log and a patient finger tempt it out.
        do {
            let home = CGPoint(x: 0.5, y: 0.46)
            out["autumn-4"] = LevelSpec(id: "autumn-4", seasonID: "autumn", index: 4, title: "Autumn, four", name: "Under the log",
                                        goals: [goal(.temptShyKoi(home: Shape(centre: home, radius: 0.06)), "Tempt the shy koi out.", wakes: .shy)],
                                        debris: [log(at: home, rotation: 0.2)],
                                        hint: .shy, bloomTarget: 2.0, leaves: 8)
        }

        // Autumn five, "the stream": rain on the pond, a stream running in
        // at the top-left corner, and the leaves still coming down. The
        // current takes them one way; the rest is the player's.
        out["autumn-5"] = LevelSpec(id: "autumn-5", seasonID: "autumn", index: 5, title: "Autumn, five", name: "The inlet",
                                    goals: [goal(.clearDebris, "Send the fallen leaves to the banks.", wakes: .clear)],
                                    shallows: [Shape(centre: CGPoint(x: 0.72, y: 0.40), radius: 0.10)],
                                    hint: .leaves, bloomTarget: 2.5, rain: true,
                                    inlet: CGPoint(x: 0.105, y: 0.105), leaves: 10)

        // Autumn six, "last light": the still pond at dusk. Eight seconds of
        // glass, the moon in the water, and the year is done.
        out["autumn-6"] = LevelSpec(id: "autumn-6", seasonID: "autumn", index: 6, title: "Autumn, six", name: "Dusk",
                                    goals: [goal(.stillness(seconds: 8), "Let the pond go still.", wakes: .moon)],
                                    hint: .still, bloomTarget: 3.0, dusk: true)
    }

    static let springOne: LevelSpec = levels.first { $0.id == "spring-1" }!

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
