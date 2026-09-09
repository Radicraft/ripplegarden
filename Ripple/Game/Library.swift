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

/// What a floating piece is. Petals, leaves and logs are `natural`; the
/// rest is rubbish, and each kind sits on the water its own way: a can is
/// heavy and low, a bottle skates on the smallest ripple, a bag goes
/// wherever the current does. Rubbish never melts or blooms; at the bank
/// it rides up out of the water and stays there.
enum DebrisKind {
    case natural, can, bottle, packet, bag

    var isRubbish: Bool { self != .natural }
    var sprite: String? {
        switch self {
        case .natural: return nil
        case .can: return "rubbish_can"
        case .bottle: return "rubbish_bottle"
        case .packet: return "rubbish_packet"
        case .bag: return "rubbish_bag"
        }
    }
    var radius: CGFloat {
        switch self {
        case .natural: return 0
        case .can: return 30
        case .bottle: return 34
        case .packet: return 28
        case .bag: return 40
        }
    }
    /// Multipliers on the natural piece of the same class: mass, drag, how
    /// hard a slope shoves it, the heavy lift threshold, and how much the
    /// current carries it.
    var mass: Float { switch self { case .natural: return 1; case .can: return 0.6; case .bottle: return 0.6; case .packet: return 0.8; case .bag: return 0.7 } }
    var drag: Float { switch self { case .natural: return 1; case .can: return 1.1; case .bottle: return 0.55; case .packet: return 0.85; case .bag: return 0.8 } }
    var gain: Float { switch self { case .natural: return 1; case .can: return 1; case .bottle: return 1.4; case .packet: return 1.1; case .bag: return 0.9 } }
    var threshold: Float { switch self { case .natural: return 1; case .can: return 0.8; default: return 1 } }
    var currentPush: Float { switch self { case .natural: return 1; case .can: return 0.6; case .bottle: return 1.2; case .packet: return 1.1; case .bag: return 1.8 } }

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
    case tap, hold, swell, current, bounce, ice, target, twin, lens, order, tilt, rubbish

    var text: String {
        switch self {
        case .tap: return "Tap the water. Ripples carry things to the bank."
        case .ice: return "Tap the ice to crack it. Tap again to break through. Slide to feel it."
        case .hold: return "Hold a finger down. A bigger swell can shift heavy things."
        case .swell: return "Two fingers together sweep a whole cluster."
        case .current: return "Drag along the bank to set a slow current."
        case .bounce: return "Ripples bounce off the stones. A curve of them throws a ripple back."
        case .target: return "Something sleeps among the pads. Only a wave through the gap will wake it."
        case .twin: return "Two ripples arriving together lift what one cannot."
        case .tilt: return "Drag up with two fingers to look across the water."
        case .rubbish: return "Tap behind the rubbish. The ripple pushes it toward the bank."
        case .lens: return "Shallow water slows a ripple and bends it. A wave that crosses a sandbank still arrives tall."
        case .order: return "No water passes a log or a can. Move what is in the way first."
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

    /// What the player is here to do, in one line, worked out from what the
    /// level holds. Shown when the level opens and kept in view.
    var goal: String {
        var parts: [String] = []
        if frozen {
            parts.append(debris.isEmpty ? "Break through the ice." : "Open the ice and free what is under it.")
        }
        let rubbish = debris.filter { $0.kind.isRubbish }.count
        let natural = debris.count - rubbish
        if rubbish > 0 && natural > 0 {
            parts.append("Push the rubbish onto the bank with ripples. Send the loose pieces there too.")
        } else if rubbish > 0 {
            parts.append("Push the rubbish onto the bank with ripples.")
        } else if natural > 0 && !frozen {
            parts.append("Push everything floating onto the banks with ripples.")
        } else if natural > 0 {
            parts.append("Then push the pieces onto the banks.")
        }
        for t in targets {
            switch t.kind {
            case .bud: parts.append("Wake the lily bud with a wave.")
            case .bell: parts.append("Ring the bell with a wave.")
            }
        }
        return parts.joined(separator: " ")
    }

    /// Small numbers in words, so the line that stays on screen reads as a
    /// sentence and not as a scoreboard.
    static func spelled(_ n: Int) -> String {
        let words = ["no", "one", "two", "three", "four", "five", "six", "seven",
                     "eight", "nine", "ten", "eleven", "twelve"]
        return n >= 0 && n < words.count ? words[n] : "\(n)"
    }

    /// What is left, for the line that stays on screen. Plain sentences, and
    /// the count of what is still on the water moves the moment a piece
    /// lands on the bank.
    static func status(remaining debris: [DebrisKind], targetsAsleep: Int, ice: Float) -> String {
        var parts: [String] = []
        if ice > 0.06 { parts.append("Ice covers \(Int((ice * 100).rounded())) percent.") }
        let afloat = debris.count
        if afloat == 1 { parts.append("One piece still afloat.") }
        else if afloat > 1 { parts.append("\(spelled(afloat).capitalized) pieces still afloat.") }
        if targetsAsleep == 1 { parts.append("One still asleep.") }
        else if targetsAsleep > 1 { parts.append("\(spelled(targetsAsleep).capitalized) still asleep.") }
        return parts.isEmpty ? "The pond is clear." : parts.joined(separator: " ")
    }
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
            clouds: ["cloud_1", "cloud_2", "cloud_3", "cloud_4"],
            reeds: ["reed_w_1", "reed_w_2", "reed_w_3", "reed_w_4"],
            iceFragments: ["ice_1", "ice_2", "ice_3", "ice_4", "ice_5", "ice_8", "ice_9", "ice_10"],
            ambientFall: "snow_2"),
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
        weeds: ["weed_c_1", "weed_c_2", "weed_c_3", "weed_c_4"],
        under: ["tadpole_1", "tadpole_2", "tadpole_3", "boatman_1"],
        skaters: ["skater_1", "skater_2"],
        flyers: ["dragonfly_body"],
        clouds: ["cloud_s_1", "cloud_s_2", "cloud_s_3", "cloud_s_4"],
        stones: ["stone_a_1", "stone_a_2", "stone_a_3", "stone_a_4", "stone_a_5", "stone_a_6", "stone_a_7", "stone_a_8"],
        gravel: ["gravel_1", "gravel_2", "gravel_3", "gravel_4"],
        sand: ["sand_1", "sand_2", "sand_3"],
        reeds: ["reed_s_1", "reed_s_2", "reed_s_3", "reed_s_4"],
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
            shoal: ["rudd_1", "minnow_2"],
            frog: ("frog_top", "lilypad_frog"), newt: "newt_1"),
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
            clouds: ["cloud_1", "cloud_2", "cloud_3", "cloud_4"],
            reeds: ["reed_a_1", "reed_a_2", "reed_a_3", "reed_a_4", "bulrush_1", "bulrush_2"],
            shoal: ["stickleback_2"], newt: "newt_1"),
        photographic: nil, rootNote: 392,
        tagline: "Maple on the pond. The year settles.")

    static let seasons: [Season] = [winter, spring, summer, autumn]

    // MARK: - Levels

    /// Six levels per season, the same escalation each time with the
    /// season's own dressing. Level one teaches the tap by itself; two adds a
    /// rock to bounce off; three a heavy piece that needs a held swell; four
    /// a packed cluster that wants two fingers; five shallows that slow the
    /// waves and a current to lean on; six everything at once.
    static let levels: [LevelSpec] = seasons.flatMap { season in
        (1...6).map { designed["\(season.id)-\($0)"] ?? build(season: season, index: $0) }
    }

    // MARK: - Designed levels

    /// Levels laid out by hand, each around one idea. Positions are
    /// fractions of the world; radii are fractions of its height, and the
    /// world is about 2.17 times taller than wide, so a circle of things
    /// needs its x offsets stretched by that.
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

    /// Light pieces from a list of places, each a different cut-out, each
    /// turned its own way.
    private static func strewn(_ points: [CGPoint], from first: Int = 0, kind: DebrisKind = .natural) -> [DebrisPlacement] {
        points.enumerated().map { i, p in
            DebrisPlacement(cls: .light, at: p, variant: first + i, scale: 1,
                            rotation: Float(i) * 0.83, kind: kind)
        }
    }

    // MARK: Winter

    private static func winterLevels(into out: inout [String: LevelSpec]) {

        // Winter one, "the sheet": the pond under one lid of ice. A first tap
        // only cracks a ring; a second inside that ring takes it out, and ice
        // away from open water is solid, so the hole has to be worked outward
        // until the sheet is gone.
        do {
            out["winter-1"] = LevelSpec(id: "winter-1", seasonID: "winter", index: 1, title: "Winter, one",
                                        mosaicCentre: CGPoint(x: 0.5, y: 0.5), mosaicRadius: 0, debris: [],
                                        hint: .ice, bloomTarget: 0.5, frozen: true)
        }

        // Winter two, "under the ice": a can lies frozen in under the sheet.
        // The ice has to be opened over it first, and then a ring passes the
        // can by; only a held swell shifts it.
        do {
            let snow = [CGPoint(x: 0.28, y: 0.30), CGPoint(x: 0.70, y: 0.32),
                        CGPoint(x: 0.32, y: 0.66), CGPoint(x: 0.68, y: 0.62)]
            var debris = strewn(snow)
            debris.append(DebrisPlacement(cls: .heavy, at: CGPoint(x: 0.50, y: 0.46),
                                          variant: 0, scale: 1, rotation: 0.7, kind: .can))
            out["winter-2"] = LevelSpec(id: "winter-2", seasonID: "winter", index: 2, title: "Winter, two",
                                        mosaicCentre: CGPoint(x: 0.5, y: 0.46), mosaicRadius: 0, debris: debris,
                                        hint: .hold, bloomTarget: 1.0, frozen: true)
        }

        // Winter three, "the drift": snow packed into one drift under the ice,
        // and a crisp packet beside it. Single taps only knock the drift into
        // itself; two fingers move the whole of it at once.
        do {
            let drift = [CGPoint(x: 0.36, y: 0.26), CGPoint(x: 0.45, y: 0.24), CGPoint(x: 0.40, y: 0.32),
                         CGPoint(x: 0.48, y: 0.33), CGPoint(x: 0.33, y: 0.35), CGPoint(x: 0.52, y: 0.27),
                         CGPoint(x: 0.43, y: 0.39)]
            var debris = strewn(drift)
            debris.append(DebrisPlacement(cls: .light, at: CGPoint(x: 0.64, y: 0.58),
                                          variant: 0, scale: 1, rotation: 0.5, kind: .packet))
            out["winter-3"] = LevelSpec(id: "winter-3", seasonID: "winter", index: 3, title: "Winter, three",
                                        mosaicCentre: CGPoint(x: 0.44, y: 0.32), mosaicRadius: 0, debris: debris,
                                        hint: .swell, bloomTarget: 1.5, frozen: true)
        }

        // Winter four, "the floe": a slab of ice wedged in the gap between two
        // stones. Taps from opposite sides cancel each other and it sits
        // there; two struck together on the same side drive it through.
        do {
            let stones = [Shape(centre: CGPoint(x: 0.30, y: 0.42), radius: 0.042),
                          Shape(centre: CGPoint(x: 0.70, y: 0.42), radius: 0.042)]
            let snow = [CGPoint(x: 0.22, y: 0.60), CGPoint(x: 0.76, y: 0.64), CGPoint(x: 0.44, y: 0.76),
                        CGPoint(x: 0.58, y: 0.22), CGPoint(x: 0.32, y: 0.20)]
            var debris = strewn(snow)
            debris.append(DebrisPlacement(cls: .heavy, at: CGPoint(x: 0.50, y: 0.42),
                                          variant: 0, scale: 1, rotation: 0.15))
            out["winter-4"] = LevelSpec(id: "winter-4", seasonID: "winter", index: 4, title: "Winter, four",
                                        mosaicCentre: CGPoint(x: 0.5, y: 0.42), mosaicRadius: 0, debris: debris,
                                        rocks: stones, hint: .twin, bloomTarget: 2.0)
        }

        // Winter five, "meltwater": a sandbar right across the pond. A ripple
        // shelves on it and arrives at the far snow too flat to carry
        // anything; a current drawn along the bank crosses the bar unbothered,
        // and the bag goes wherever the current goes.
        do {
            let bar = [Shape(centre: CGPoint(x: 0.32, y: 0.52), radius: 0.12),
                       Shape(centre: CGPoint(x: 0.68, y: 0.52), radius: 0.12)]
            let snow = [CGPoint(x: 0.26, y: 0.24), CGPoint(x: 0.40, y: 0.19), CGPoint(x: 0.62, y: 0.20),
                        CGPoint(x: 0.74, y: 0.26), CGPoint(x: 0.30, y: 0.78), CGPoint(x: 0.70, y: 0.76)]
            var debris = strewn(snow)
            debris.append(DebrisPlacement(cls: .light, at: CGPoint(x: 0.50, y: 0.26),
                                          variant: 0, scale: 1, rotation: 0.9, kind: .bag))
            out["winter-5"] = LevelSpec(id: "winter-5", seasonID: "winter", index: 5, title: "Winter, five",
                                        mosaicCentre: CGPoint(x: 0.5, y: 0.5), mosaicRadius: 0, debris: debris,
                                        shallows: bar, hint: .current, bloomTarget: 2.5)
        }

        // Winter six, "the thaw": a bell hangs under a curve of stones. A tap
        // beside it passes just under the note it needs; the same ripple sent
        // out at the curve comes back doubled and rings it. The can and the
        // bottle are the winter's leftovers.
        do {
            let bell = CGPoint(x: 0.50, y: 0.36)
            let arc = ring(5, centre: bell, radius: 0.15, from: -2.6, to: -0.54).map { Shape(centre: $0, radius: 0.032) }
            let snow = [CGPoint(x: 0.20, y: 0.40), CGPoint(x: 0.80, y: 0.44), CGPoint(x: 0.44, y: 0.80),
                        CGPoint(x: 0.62, y: 0.76), CGPoint(x: 0.24, y: 0.74)]
            var debris = strewn(snow)
            debris.append(DebrisPlacement(cls: .heavy, at: CGPoint(x: 0.30, y: 0.62),
                                          variant: 0, scale: 1, rotation: 0.3, kind: .can))
            debris.append(DebrisPlacement(cls: .light, at: CGPoint(x: 0.70, y: 0.66),
                                          variant: 0, scale: 1, rotation: 1.2, kind: .bottle))
            out["winter-6"] = LevelSpec(id: "winter-6", seasonID: "winter", index: 6, title: "Winter, six",
                                        mosaicCentre: bell, mosaicRadius: 0, debris: debris,
                                        rocks: arc,
                                        targets: [TargetSpec(kind: .bell, at: bell, threshold: 0.044)],
                                        hint: .bounce, bloomTarget: 3.0)
        }
    }

    // MARK: Spring

    private static func springLevels(into out: inout [String: LevelSpec]) {

        // Spring one, "first blossom": petals ring a mossy stone in the middle
        // of the pond. The one place a tap would clear the lot is the stone
        // itself, which takes no ripple at all, so each petal wants a tap on
        // its pond side to send it out to the bank.
        do {
            let stone = CGPoint(x: 0.50, y: 0.46)
            let petals = ring(7, centre: stone, radius: 0.115, from: 0, to: 2 * .pi * 6 / 7)
            out["spring-1"] = LevelSpec(id: "spring-1", seasonID: "spring", index: 1, title: "Spring, one",
                                        mosaicCentre: stone, mosaicRadius: 0, debris: strewn(petals),
                                        rocks: [Shape(centre: stone, radius: 0.05)],
                                        hint: .tap, bloomTarget: 0.5)
        }

        // Spring two, "the stone arc": a can lies at the centre of a curve
        // of stones. A ripple sent out from near the can comes back off the
        // curve and meets itself there, twice the height of the ring that
        // left; that, or a held swell, is what shifts a can.
        do {
            let c = CGPoint(x: 0.5, y: 0.40)
            let arc = ring(5, centre: c, radius: 0.13, from: -2.6, to: -0.54).map { Shape(centre: $0, radius: 0.032) }
            let petals = [CGPoint(x: 0.26, y: 0.58), CGPoint(x: 0.70, y: 0.62), CGPoint(x: 0.42, y: 0.70),
                          CGPoint(x: 0.62, y: 0.50), CGPoint(x: 0.34, y: 0.33)]
            var debris = petals.enumerated().map { i, p in
                DebrisPlacement(cls: .light, at: p, variant: i, scale: 1, rotation: Float(i) * 1.3)
            }
            debris.append(DebrisPlacement(cls: .heavy, at: c, variant: 0, scale: 1, rotation: 0.4, kind: .can))
            out["spring-2"] = LevelSpec(id: "spring-2", seasonID: "spring", index: 2, title: "Spring, two",
                                        mosaicCentre: c, mosaicRadius: 0, debris: debris,
                                        rocks: arc, shallows: [], hint: .bounce, bloomTarget: 1.0)
        }

        // Spring three, "two ripples": a log that one tap's ring will not
        // lift, and a bottle that any ripple skates away. Two rings that
        // meet under the log lift it; so does a held swell.
        do {
            let c = CGPoint(x: 0.5, y: 0.46)
            var debris = [DebrisPlacement(cls: .heavy, at: CGPoint(x: 0.52, y: 0.44), variant: 0, scale: 1, rotation: 0.3),
                          DebrisPlacement(cls: .light, at: CGPoint(x: 0.30, y: 0.62), variant: 0, scale: 1, rotation: 1.1, kind: .bottle)]
            for (i, p) in [CGPoint(x: 0.24, y: 0.36), CGPoint(x: 0.74, y: 0.34), CGPoint(x: 0.66, y: 0.66), CGPoint(x: 0.44, y: 0.30)].enumerated() {
                debris.append(DebrisPlacement(cls: .light, at: p, variant: i + 1, scale: 1, rotation: Float(i) * 0.9))
            }
            out["spring-3"] = LevelSpec(id: "spring-3", seasonID: "spring", index: 3, title: "Spring, three",
                                        mosaicCentre: c, mosaicRadius: 0, debris: debris,
                                        rocks: [Shape(centre: CGPoint(x: 0.78, y: 0.52), radius: 0.045)], shallows: [],
                                        hint: .twin, bloomTarget: 1.5)
        }

        // Spring four, "the raft": blossom packed so tight that a tap dropped
        // into the middle of it sends half the raft out and half of it deeper
        // into the pond. Two fingers take the whole raft one way.
        do {
            let raft = [CGPoint(x: 0.370, y: 0.340), CGPoint(x: 0.440, y: 0.340), CGPoint(x: 0.510, y: 0.340),
                        CGPoint(x: 0.335, y: 0.375), CGPoint(x: 0.405, y: 0.375), CGPoint(x: 0.475, y: 0.375),
                        CGPoint(x: 0.545, y: 0.375), CGPoint(x: 0.370, y: 0.410), CGPoint(x: 0.440, y: 0.410),
                        CGPoint(x: 0.510, y: 0.410)]
            out["spring-4"] = LevelSpec(id: "spring-4", seasonID: "spring", index: 4, title: "Spring, four",
                                        mosaicCentre: CGPoint(x: 0.44, y: 0.375), mosaicRadius: 0, debris: strewn(raft),
                                        rocks: [Shape(centre: CGPoint(x: 0.32, y: 0.56), radius: 0.055)],
                                        hint: .swell, bloomTarget: 2.0)
        }

        // Spring five, "the near bank": stones stand between every piece and
        // the bank it is nearest to, so a ripple that would carry one ashore
        // bounces off the stone and pushes it back out. A current drawn along
        // the pond slides everything past them to the ends instead, and the
        // bag goes furthest of all.
        do {
            let stones = [Shape(centre: CGPoint(x: 0.18, y: 0.36), radius: 0.05),
                          Shape(centre: CGPoint(x: 0.18, y: 0.60), radius: 0.05),
                          Shape(centre: CGPoint(x: 0.82, y: 0.42), radius: 0.05),
                          Shape(centre: CGPoint(x: 0.82, y: 0.66), radius: 0.05)]
            let petals = [CGPoint(x: 0.35, y: 0.34), CGPoint(x: 0.34, y: 0.62), CGPoint(x: 0.66, y: 0.40),
                          CGPoint(x: 0.65, y: 0.58), CGPoint(x: 0.63, y: 0.74)]
            var debris = strewn(petals)
            debris.append(DebrisPlacement(cls: .light, at: CGPoint(x: 0.36, y: 0.48),
                                          variant: 0, scale: 1, rotation: 0.6, kind: .bag))
            // Meltwater runs in at the top-left corner all through the level.
            out["spring-5"] = LevelSpec(id: "spring-5", seasonID: "spring", index: 5, title: "Spring, five",
                                        mosaicCentre: CGPoint(x: 0.5, y: 0.5), mosaicRadius: 0, debris: debris,
                                        rocks: stones, hint: .current, bloomTarget: 2.5,
                                        inlet: CGPoint(x: 0.105, y: 0.105))
        }

        // Spring six, "the bud in the pads": a bud closed inside a ring of
        // pads with one gap facing down the pond, and a curve of stones set
        // below it. Taps on the pads do nothing and the water near the gap is
        // too little; a ripple thrown out at the curve comes back gathered on
        // the bud and opens it.
        do {
            let bud = CGPoint(x: 0.50, y: 0.34)
            var pads = ring(6, centre: bud, radius: 0.070, from: -2.42, to: 2.42).map { Shape(centre: $0, radius: 0.027) }
            pads.removeAll { abs($0.centre.x - bud.x) < 0.02 && $0.centre.y > bud.y }
            let arc = ring(5, centre: bud, radius: 0.17, from: 0.5, to: 2.64).map { Shape(centre: $0, radius: 0.032) }
            let petals = [CGPoint(x: 0.22, y: 0.62), CGPoint(x: 0.34, y: 0.78), CGPoint(x: 0.56, y: 0.82),
                          CGPoint(x: 0.26, y: 0.24), CGPoint(x: 0.74, y: 0.24), CGPoint(x: 0.14, y: 0.50)]
            var debris = strewn(petals)
            debris.append(DebrisPlacement(cls: .heavy, at: CGPoint(x: 0.74, y: 0.68),
                                          variant: 0, scale: 1, rotation: 0.5, kind: .can))
            debris.append(DebrisPlacement(cls: .light, at: CGPoint(x: 0.78, y: 0.56),
                                          variant: 0, scale: 1, rotation: 1.4, kind: .bottle))
            out["spring-6"] = LevelSpec(id: "spring-6", seasonID: "spring", index: 6, title: "Spring, six",
                                        mosaicCentre: bud, mosaicRadius: 0, debris: debris,
                                        rocks: arc, shallows: [], pads: pads,
                                        targets: [TargetSpec(kind: .bud, at: bud, threshold: 0.034)],
                                        hint: .bounce, bloomTarget: 3.0)
        }
    }

    // MARK: Summer

    private static func summerLevels(into out: inout [String: LevelSpec]) {

        // Summer one, "duckweed": pads lie over the water where the hand
        // wants to go, and a finger on a pad presses a leaf, not the pond.
        // The weed has to be moved from the lanes between them.
        do {
            let pads = [Shape(centre: CGPoint(x: 0.34, y: 0.38), radius: 0.033),
                        Shape(centre: CGPoint(x: 0.62, y: 0.34), radius: 0.033),
                        Shape(centre: CGPoint(x: 0.40, y: 0.62), radius: 0.030),
                        Shape(centre: CGPoint(x: 0.66, y: 0.60), radius: 0.033),
                        Shape(centre: CGPoint(x: 0.50, y: 0.50), radius: 0.036)]
            let weed = [CGPoint(x: 0.50, y: 0.36), CGPoint(x: 0.34, y: 0.52), CGPoint(x: 0.64, y: 0.48),
                        CGPoint(x: 0.50, y: 0.66), CGPoint(x: 0.24, y: 0.30), CGPoint(x: 0.76, y: 0.44)]
            out["summer-1"] = LevelSpec(id: "summer-1", seasonID: "summer", index: 1, title: "Summer, one",
                                        mosaicCentre: CGPoint(x: 0.5, y: 0.5), mosaicRadius: 0, debris: strewn(weed),
                                        pads: pads, hint: .tap, bloomTarget: 0.5)
        }

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
            var debris: [DebrisPlacement] = []
            for (i, p) in [CGPoint(x: 0.26, y: 0.70), CGPoint(x: 0.72, y: 0.74), CGPoint(x: 0.36, y: 0.80), CGPoint(x: 0.80, y: 0.46)].enumerated() {
                debris.append(DebrisPlacement(cls: .light, at: p, variant: i, scale: 1, rotation: Float(i) * 0.7))
            }
            out["summer-2"] = LevelSpec(id: "summer-2", seasonID: "summer", index: 2, title: "Summer, two",
                                        mosaicCentre: c, mosaicRadius: 0, debris: debris,
                                        rocks: [], shallows: [bank], pads: pads,
                                        targets: [TargetSpec(kind: .bud, at: c, threshold: 0.036)],
                                        hint: .target, bloomTarget: 1.0)
        }

        // Summer three, "glass": a can among three bottles. The swell that is
        // big enough to move the can throws every bottle across the pond, and
        // a bottle skates on anything, so the bottles want sending ashore
        // first and the can lifting after.
        do {
            let weed = [CGPoint(x: 0.22, y: 0.66), CGPoint(x: 0.78, y: 0.30), CGPoint(x: 0.66, y: 0.74)]
            var debris = strewn(weed)
            for (i, p) in [CGPoint(x: 0.36, y: 0.36), CGPoint(x: 0.62, y: 0.52), CGPoint(x: 0.40, y: 0.58)].enumerated() {
                debris.append(DebrisPlacement(cls: .light, at: p, variant: 0, scale: 1,
                                              rotation: Float(i) * 1.1, kind: .bottle))
            }
            debris.append(DebrisPlacement(cls: .heavy, at: CGPoint(x: 0.50, y: 0.44),
                                          variant: 0, scale: 1, rotation: 0.25, kind: .can))
            out["summer-3"] = LevelSpec(id: "summer-3", seasonID: "summer", index: 3, title: "Summer, three",
                                        mosaicCentre: CGPoint(x: 0.5, y: 0.46), mosaicRadius: 0, debris: debris,
                                        hint: .order, bloomTarget: 1.5, rain: true)
        }

        // Summer four, "round the stones": a bud at the top of the pond with a
        // bar of stone straight below it, so nothing sent up the middle ever
        // arrives. The shallows either side hold a ripple together and bend it
        // inward, and a wave sent up the flank comes round the bar to the bud.
        do {
            let bud = CGPoint(x: 0.50, y: 0.22)
            let bar = [Shape(centre: CGPoint(x: 0.395, y: 0.40), radius: 0.05),
                       Shape(centre: CGPoint(x: 0.605, y: 0.40), radius: 0.05)]
            let banks = [Shape(centre: CGPoint(x: 0.26, y: 0.40), radius: 0.11),
                         Shape(centre: CGPoint(x: 0.74, y: 0.40), radius: 0.11)]
            let weed = [CGPoint(x: 0.24, y: 0.66), CGPoint(x: 0.50, y: 0.72), CGPoint(x: 0.76, y: 0.64),
                        CGPoint(x: 0.20, y: 0.50)]
            var debris = strewn(weed)
            for (i, p) in [CGPoint(x: 0.34, y: 0.80), CGPoint(x: 0.66, y: 0.78)].enumerated() {
                debris.append(DebrisPlacement(cls: .light, at: p, variant: 0, scale: 1,
                                              rotation: Float(i) * 1.5, kind: .bottle))
            }
            out["summer-4"] = LevelSpec(id: "summer-4", seasonID: "summer", index: 4, title: "Summer, four",
                                        mosaicCentre: bud, mosaicRadius: 0, debris: debris,
                                        rocks: bar, shallows: banks,
                                        targets: [TargetSpec(kind: .bud, at: bud, threshold: 0.034)],
                                        hint: .lens, bloomTarget: 2.0)
        }

        // Summer five, "the bag in the pads": pads boxed round a carrier bag
        // on all four sides. Every place a ring could start is a leaf, so the
        // ring never starts. A current runs under the pads as if they were not
        // there, and a bag follows a current harder than anything else does.
        do {
            let pads = [Shape(centre: CGPoint(x: 0.50, y: 0.30), radius: 0.033),
                        Shape(centre: CGPoint(x: 0.50, y: 0.56), radius: 0.033),
                        Shape(centre: CGPoint(x: 0.30, y: 0.42), radius: 0.033),
                        Shape(centre: CGPoint(x: 0.70, y: 0.42), radius: 0.033),
                        Shape(centre: CGPoint(x: 0.24, y: 0.60), radius: 0.030),
                        Shape(centre: CGPoint(x: 0.76, y: 0.26), radius: 0.030)]
            let weed = [CGPoint(x: 0.22, y: 0.24), CGPoint(x: 0.78, y: 0.68), CGPoint(x: 0.40, y: 0.76),
                        CGPoint(x: 0.62, y: 0.20), CGPoint(x: 0.16, y: 0.44)]
            var debris = strewn(weed)
            debris.append(DebrisPlacement(cls: .light, at: CGPoint(x: 0.50, y: 0.42),
                                          variant: 0, scale: 1, rotation: 0.4, kind: .bag))
            debris.append(DebrisPlacement(cls: .light, at: CGPoint(x: 0.26, y: 0.72),
                                          variant: 0, scale: 1, rotation: 1.0, kind: .packet))
            debris.append(DebrisPlacement(cls: .light, at: CGPoint(x: 0.72, y: 0.80),
                                          variant: 0, scale: 1, rotation: 1.9, kind: .bottle))
            out["summer-5"] = LevelSpec(id: "summer-5", seasonID: "summer", index: 5, title: "Summer, five",
                                        mosaicCentre: CGPoint(x: 0.5, y: 0.46), mosaicRadius: 0, debris: debris,
                                        pads: pads, hint: .current, bloomTarget: 2.5)
        }

        // Summer six, "the channel": two lines of pads make a lane up the
        // pond with a can sitting in it and a bell at the far end. The lane
        // keeps a swell together instead of letting it spread, so one hold at
        // the mouth drives the can out and carries on to ring the bell.
        do {
            var pads: [Shape] = []
            for y in [0.34, 0.42, 0.50, 0.58] {
                pads.append(Shape(centre: CGPoint(x: 0.32, y: CGFloat(y)), radius: 0.030))
                pads.append(Shape(centre: CGPoint(x: 0.68, y: CGFloat(y)), radius: 0.030))
            }
            let bell = CGPoint(x: 0.50, y: 0.24)
            let weed = [CGPoint(x: 0.20, y: 0.26), CGPoint(x: 0.80, y: 0.30), CGPoint(x: 0.22, y: 0.66),
                        CGPoint(x: 0.80, y: 0.70), CGPoint(x: 0.50, y: 0.78)]
            var debris = strewn(weed)
            debris.append(DebrisPlacement(cls: .heavy, at: CGPoint(x: 0.50, y: 0.46),
                                          variant: 0, scale: 1, rotation: 0.2, kind: .can))
            for (i, p) in [CGPoint(x: 0.17, y: 0.48), CGPoint(x: 0.84, y: 0.54)].enumerated() {
                debris.append(DebrisPlacement(cls: .light, at: p, variant: 0, scale: 1,
                                              rotation: Float(i) * 1.3, kind: .bottle))
            }
            out["summer-6"] = LevelSpec(id: "summer-6", seasonID: "summer", index: 6, title: "Summer, six",
                                        mosaicCentre: CGPoint(x: 0.5, y: 0.44), mosaicRadius: 0, debris: debris,
                                        pads: pads,
                                        targets: [TargetSpec(kind: .bell, at: bell, threshold: 0.040)],
                                        hint: .hold, bloomTarget: 3.0)
        }
    }

    // MARK: Autumn

    private static func autumnLevels(into out: inout [String: LevelSpec]) {

        // Autumn one, "the drift of leaves": a long line of leaves lying
        // across the pond, longer than any one ripple. A tap dropped into the
        // middle of it sends as many leaves out into the water as it sends
        // ashore, so the line wants working from one end.
        do {
            var leaves: [CGPoint] = []
            for i in 0..<12 {
                let t = CGFloat(i)
                leaves.append(CGPoint(x: 0.20 + 0.0545 * t, y: 0.66 - 0.0327 * t + (i % 2 == 0 ? 0.02 : -0.02)))
            }
            out["autumn-1"] = LevelSpec(id: "autumn-1", seasonID: "autumn", index: 1, title: "Autumn, one",
                                        mosaicCentre: CGPoint(x: 0.5, y: 0.48), mosaicRadius: 0, debris: strewn(leaves),
                                        hint: .tap, bloomTarget: 0.5)
        }

        // Autumn two, "driftwood": a log across the middle of the pond. A
        // tap's ring runs under it and leaves it where it lies; a held swell
        // lifts the water enough to roll it out.
        do {
            let leaves = [CGPoint(x: 0.22, y: 0.28), CGPoint(x: 0.44, y: 0.22), CGPoint(x: 0.70, y: 0.26),
                          CGPoint(x: 0.78, y: 0.52), CGPoint(x: 0.28, y: 0.62), CGPoint(x: 0.56, y: 0.74),
                          CGPoint(x: 0.36, y: 0.80)]
            var debris = strewn(leaves)
            debris.append(DebrisPlacement(cls: .heavy, at: CGPoint(x: 0.50, y: 0.46), variant: 0, scale: 1, rotation: 0))
            out["autumn-2"] = LevelSpec(id: "autumn-2", seasonID: "autumn", index: 2, title: "Autumn, two",
                                        mosaicCentre: CGPoint(x: 0.5, y: 0.46), mosaicRadius: 0, debris: debris,
                                        hint: .hold, bloomTarget: 1.0)
        }

        // Autumn three, "the weir": two logs and two stones close the pond
        // right across, and the leaves are penned above them. No water gets
        // past a log, so the leaves sit in its lee whatever is tapped below.
        // The logs go first, then the leaves follow them out.
        do {
            let stones = [Shape(centre: CGPoint(x: 0.16, y: 0.48), radius: 0.05),
                          Shape(centre: CGPoint(x: 0.84, y: 0.48), radius: 0.05)]
            let leaves = [CGPoint(x: 0.26, y: 0.30), CGPoint(x: 0.40, y: 0.26), CGPoint(x: 0.54, y: 0.30),
                          CGPoint(x: 0.68, y: 0.26), CGPoint(x: 0.34, y: 0.38), CGPoint(x: 0.60, y: 0.38),
                          CGPoint(x: 0.32, y: 0.68), CGPoint(x: 0.66, y: 0.72)]
            var debris = strewn(leaves)
            debris.append(DebrisPlacement(cls: .heavy, at: CGPoint(x: 0.38, y: 0.50), variant: 0, scale: 1, rotation: 0))
            debris.append(DebrisPlacement(cls: .heavy, at: CGPoint(x: 0.60, y: 0.50), variant: 0, scale: 1, rotation: 0))
            out["autumn-3"] = LevelSpec(id: "autumn-3", seasonID: "autumn", index: 3, title: "Autumn, three",
                                        mosaicCentre: CGPoint(x: 0.5, y: 0.44), mosaicRadius: 0, debris: debris,
                                        rocks: stones, hint: .order, bloomTarget: 1.5)
        }

        // Autumn four, "windfall": a raft of leaves pinned between two
        // stones. Tap into it and the leaves knock against the stones and
        // come back; two fingers carry the raft out whole, along the pond
        // rather than across it.
        do {
            var leaves: [CGPoint] = []
            for row in 0..<4 {
                for col in 0..<3 {
                    leaves.append(CGPoint(x: 0.42 + 0.08 * CGFloat(col), y: 0.36 + 0.04 * CGFloat(row)))
                }
            }
            let stones = [Shape(centre: CGPoint(x: 0.24, y: 0.44), radius: 0.055),
                          Shape(centre: CGPoint(x: 0.76, y: 0.44), radius: 0.055)]
            out["autumn-4"] = LevelSpec(id: "autumn-4", seasonID: "autumn", index: 4, title: "Autumn, four",
                                        mosaicCentre: CGPoint(x: 0.5, y: 0.44), mosaicRadius: 0, debris: strewn(leaves),
                                        rocks: stones, hint: .swell, bloomTarget: 2.0)
        }

        // Autumn five, "silt": most of the pond has silted up, and a ripple
        // shelves and dies within a hand's reach of where it started. A
        // current laid along the bank leans the whole pond one way at once
        // and takes the leaves and the bag with it.
        do {
            let banks = [Shape(centre: CGPoint(x: 0.50, y: 0.62), radius: 0.14),
                         Shape(centre: CGPoint(x: 0.30, y: 0.34), radius: 0.10),
                         Shape(centre: CGPoint(x: 0.72, y: 0.38), radius: 0.10)]
            let leaves = [CGPoint(x: 0.20, y: 0.26), CGPoint(x: 0.36, y: 0.20), CGPoint(x: 0.58, y: 0.24),
                          CGPoint(x: 0.76, y: 0.32), CGPoint(x: 0.22, y: 0.50), CGPoint(x: 0.74, y: 0.54),
                          CGPoint(x: 0.34, y: 0.66), CGPoint(x: 0.66, y: 0.72)]
            var debris = strewn(leaves)
            debris.append(DebrisPlacement(cls: .light, at: CGPoint(x: 0.50, y: 0.46),
                                          variant: 0, scale: 1, rotation: 0.8, kind: .bag))
            // The rain has to go somewhere: a stream runs in at the top-left.
            out["autumn-5"] = LevelSpec(id: "autumn-5", seasonID: "autumn", index: 5, title: "Autumn, five",
                                        mosaicCentre: CGPoint(x: 0.5, y: 0.48), mosaicRadius: 0, debris: debris,
                                        shallows: banks, hint: .current, bloomTarget: 2.5, rain: true,
                                        inlet: CGPoint(x: 0.105, y: 0.105))
        }

        // Autumn six, "last light": a bell hangs over open water with nothing
        // near enough to ring it. One ring passes just under the note; two
        // taps struck together on either side meet under the bell and sound
        // it. The log and the bag are the year's last things to tidy.
        do {
            let bell = CGPoint(x: 0.50, y: 0.30)
            let leaves = [CGPoint(x: 0.20, y: 0.22), CGPoint(x: 0.42, y: 0.18), CGPoint(x: 0.72, y: 0.24),
                          CGPoint(x: 0.80, y: 0.46), CGPoint(x: 0.22, y: 0.76), CGPoint(x: 0.56, y: 0.80)]
            var debris = strewn(leaves)
            debris.append(DebrisPlacement(cls: .heavy, at: CGPoint(x: 0.34, y: 0.60), variant: 0, scale: 1, rotation: 0.6))
            debris.append(DebrisPlacement(cls: .light, at: CGPoint(x: 0.68, y: 0.64),
                                          variant: 0, scale: 1, rotation: 1.1, kind: .bag))
            out["autumn-6"] = LevelSpec(id: "autumn-6", seasonID: "autumn", index: 6, title: "Autumn, six",
                                        mosaicCentre: bell, mosaicRadius: 0, debris: debris,
                                        targets: [TargetSpec(kind: .bell, at: bell, threshold: 0.044)],
                                        hint: .twin, bloomTarget: 3.0)
        }
    }

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
            hint = .hold
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
        // Winter: the pond is frozen over. Level one is the sheet alone, to
        // teach the tap; the next two keep it over whatever is on the water.
        let frozen = season.id == "winter" && index <= 3
        if frozen && index == 1 { debris = []; hint = .ice }
        return LevelSpec(id: "\(season.id)-\(index)", seasonID: season.id, index: index, title: title,
                         mosaicCentre: centre, mosaicRadius: 0, debris: debris,
                         rocks: rocks, shallows: shallows, hint: hint,
                         bloomTarget: Float(index) * 0.5, frozen: frozen)
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
