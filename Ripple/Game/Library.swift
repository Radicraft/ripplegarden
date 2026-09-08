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
    var bankAspect: CGFloat       // height / width of the bank image
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
}

struct Season: Identifiable {
    let id: String
    let name: String
    let order: Int
    let photographic: ArtSet
    let woodblock: ArtSet
    let rootNote: Float

    func art(for style: WaterStyle) -> ArtSet {
        style == .woodblock ? woodblock : photographic
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
        case .tap: return "Tap the water. Ripples wash the silt away."
        case .hold: return "Hold a finger down. A bigger swell can shift heavy things."
        case .swell: return "Two fingers together sweep a whole cluster."
        case .current: return "Drag along the edge to set a slow current."
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
    var bloomTarget: Int
}

enum Library {

    static let springPhoto = ArtSet(
        branch: ["p_branch_1", "p_branch_2", "p_branch_3", "p_branch_4"],
        branchScale: 1.15, branchInset: 40, branchRightScale: 0.62, branchRightDrop: 120,
        bank: "p_bank_spring", bankAspect: 753.0 / 1536.0, bankSink: 34,
        light: ["p_petal_1"],
        heavy: ["p_driftwood_1", "p_stone_1", "p_mossstone_1"],
        rock: "p_mossstone_1",
        koi: ["p_koi_1", "p_koi_5", "p_koi_2"],
        koiForward: [.pi / 2],
        koiWaveAmp: 0.16,
        mosaic: "p_mosaic_spring",
        petalParticle: "p_petal_1",
        floor: FloorLook(deep: [0.050, 0.150, 0.120], mid: [0.145, 0.300, 0.230], shallow: [0.330, 0.520, 0.400],
                         waterTint: [0.86, 1.00, 0.94], waterTintStrength: 0.35,
                         siltColour: [0.42, 0.40, 0.30],
                         mosaicCentre: [0.5, 0.5], mosaicRadius: 0.17, mosaicImage: "p_mosaic_spring"))

    static let springWoodblock = ArtSet(
        branch: ["spring_branch_1", "spring_branch_2", "spring_branch_3", "spring_branch_4"],
        branchScale: 0.66,
        bank: "spring_bank", bankAspect: 628.0 / 1536.0, bankSink: 6,
        light: ["petal_1", "petal_2", "petal_3"],
        heavy: ["driftwood_1", "stone_1", "mossstone_1"],
        rock: "mossstone_1",
        koi: ["koi_1", "koi_2"],
        koiForward: [-3 * .pi / 4, -.pi / 4],
        koiWaveAmp: 0.05,
        mosaic: "mosaic_spring",
        petalParticle: "petal_2",
        floor: FloorLook(deep: [0.07, 0.17, 0.21], mid: [0.13, 0.31, 0.33], shallow: [0.26, 0.49, 0.47],
                         waterTint: [0.88, 1.00, 0.97], waterTintStrength: 0.3,
                         siltColour: [0.36, 0.38, 0.33],
                         mosaicCentre: [0.5, 0.5], mosaicRadius: 0.17, mosaicImage: "mosaic_spring"))

    static let spring = Season(id: "spring", name: "Spring", order: 1,
                               photographic: springPhoto, woodblock: springWoodblock, rootNote: 523.25)

    static let seasons: [Season] = [spring]

    /// Spring, level one. Petals lie on a silted roundel; a mossy rock sits
    /// at its shoulder so waves from the right bounce back across the tile;
    /// a piece of driftwood lies over the top of the tile and only a held
    /// swell will shift it. Taps teach themselves; the rock and the log teach
    /// the other two ideas.
    static let springOne: LevelSpec = {
        let c = CGPoint(x: 0.5, y: 0.5)
        var placements: [DebrisPlacement] = []
        let ring: [(CGFloat, CGFloat)] = [
            (0.00, 0.02), (0.07, -0.05), (-0.08, -0.03), (0.09, 0.05),
            (-0.09, 0.06), (0.02, 0.11), (-0.03, -0.10),
        ]
        for (i, (dx, dy)) in ring.enumerated() {
            placements.append(DebrisPlacement(cls: .light, at: CGPoint(x: c.x + dx, y: c.y + dy),
                                              variant: i, scale: [1.0, 0.85, 1.15][i % 3]))
        }
        placements.append(DebrisPlacement(cls: .heavy, at: CGPoint(x: c.x - 0.02, y: c.y - 0.13),
                                          variant: 0, scale: 1.0, rotation: 0.25))
        return LevelSpec(id: "spring-1", seasonID: "spring", index: 1, title: "Spring, one",
                         mosaicCentre: c, mosaicRadius: 0.17, debris: placements,
                         rocks: [Shape(centre: CGPoint(x: 0.76, y: 0.35), radius: 0.055)],
                         hint: .tap, bloomTarget: 3)
    }()

    static let levels: [LevelSpec] = [springOne]

    static func season(for level: LevelSpec) -> Season {
        seasons.first { $0.id == level.seasonID } ?? spring
    }

    static func level(after level: LevelSpec) -> LevelSpec? {
        guard let i = levels.firstIndex(where: { $0.id == level.id }), i + 1 < levels.count else { return nil }
        return levels[i + 1]
    }
}
