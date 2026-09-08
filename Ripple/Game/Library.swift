import CoreGraphics
import simd

// ---------------------------------------------------------------------------
// Content. Seasons and levels are plain data so more can be appended after
// launch without touching the engine; nothing anywhere assumes four seasons.
// Positions are unit screen coordinates: x as a fraction of width, y as a
// fraction of height, origin top-left.
// ---------------------------------------------------------------------------

struct Season: Identifiable, Hashable {
    let id: String
    let name: String
    let order: Int
    let floor: FloorLook
    /// Four bloom states, bare to full.
    let bloomImages: [String]
    let bankImage: String
    let lightDebris: [String]
    let heavyDebris: [String]
    let petalImage: String
    /// The pentatonic root the season's water sings in.
    let rootNote: Float

    static func == (a: Season, b: Season) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum DebrisClass {
    case light, heavy
}

struct DebrisPlacement {
    var cls: DebrisClass
    var at: CGPoint
    var variant: Int = 0
    var scale: CGFloat = 1
}

struct Shape {
    var centre: CGPoint
    /// As a fraction of screen height.
    var radius: CGFloat
}

enum Hint: String {
    case tap, hold, swell, current

    var text: String {
        switch self {
        case .tap: return "Tap the water to send a ripple."
        case .hold: return "Hold a finger down. The longer you hold, the bigger the swell."
        case .swell: return "Two fingers together sweep a whole cluster."
        case .current: return "Drag along the edge to set a slow current."
        }
    }
}

struct LevelSpec: Identifiable {
    let id: String
    let seasonID: String
    let index: Int
    let title: String
    let debris: [DebrisPlacement]
    var obstacles: [Shape] = []
    var shallows: [Shape] = []
    var hint: Hint? = nil
    /// Bloom stage (0...3) the garden reaches when this level is done.
    var bloomTarget: Int
}

enum Library {

    static let spring = Season(
        id: "spring",
        name: "Spring",
        order: 1,
        floor: FloorLook(deep: [0.050, 0.150, 0.120],
                         mid: [0.145, 0.300, 0.230],
                         shallow: [0.330, 0.520, 0.400],
                         waterTint: [0.86, 1.00, 0.94],
                         waterTintStrength: 0.35,
                         mosaicCentre: [0.5, 0.47],
                         mosaicRadius: 0.19,
                         mosaicGhost: 0.04,
                         mosaicImage: "mosaic_spring",
                         sectors: 8),
        bloomImages: ["spring_branch_1", "spring_branch_2", "spring_branch_3", "spring_branch_4"],
        bankImage: "spring_bank",
        lightDebris: ["petal_1", "petal_2", "petal_3"],
        heavyDebris: ["stone_1", "mossstone_1", "driftwood_1"],
        petalImage: "petal_2",
        rootNote: 523.25)

    static let seasons: [Season] = [spring]

    /// Spring, level one: petals on the roundel, nothing else. A single tap
    /// moves a petal, and the level is small enough that nine of them do not
    /// wear out the idea. Teaches nothing but the tap, on purpose.
    static let springOne: LevelSpec = {
        let c = CGPoint(x: 0.5, y: 0.47)
        var placements: [DebrisPlacement] = []
        let ring: [(CGFloat, CGFloat)] = [
            (0.00, 0.00), (0.07, -0.09), (-0.08, -0.06), (0.10, 0.03),
            (-0.09, 0.05), (0.02, 0.11), (-0.03, -0.12), (0.12, -0.02), (-0.12, -0.01),
        ]
        for (i, (dx, dy)) in ring.enumerated() {
            placements.append(DebrisPlacement(cls: .light,
                                              at: CGPoint(x: c.x + dx, y: c.y + dy),
                                              variant: i % 3,
                                              scale: [1.0, 0.9, 1.1][i % 3]))
        }
        return LevelSpec(id: "spring-1", seasonID: "spring", index: 1, title: "Spring, one",
                         debris: placements, hint: .tap, bloomTarget: 3)
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
