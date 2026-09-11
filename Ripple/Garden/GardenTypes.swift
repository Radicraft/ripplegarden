import Foundation
import CoreGraphics
import simd

// The contract for the player's own pond (docs/garden-spec.md). Every agent
// compiles against this file; nobody changes it.

/// How rare a thing is, and the colour that says so.
enum Rarity: String, Codable, CaseIterable {
    case common, rare, superRare

    /// The ring of light, the words, the chord: white, indigo, gold.
    var colour: SIMD4<Float> {
        switch self {
        case .common: return [0.96, 0.95, 0.92, 1]
        case .rare: return [0.24, 0.35, 0.60, 1]
        case .superRare: return [0.85, 0.64, 0.25, 1]
        }
    }
    var name: String {
        switch self {
        case .common: return "Common"
        case .rare: return "Rare"
        case .superRare: return "Super rare"
        }
    }
    /// Petals a win of this tier adds on top of the level's own.
    var petalBonus: Int { switch self { case .common: return 0; case .rare: return 6; case .superRare: return 20 } }
}

enum ItemCategory: String, Codable, CaseIterable {
    case bankPlant, tree, aquaticPlant, stone, wood, koi, shoal, creature, feature, toy, atmosphere
}

/// Where a thing may be put down in the plot.
enum Placement: String, Codable {
    /// Dry ground within reach of the waterline; it stands up from its root.
    case bank
    /// Open water deeper than the shallows.
    case water
    /// Water over the shelf, lily depth.
    case shallows
    /// Ground or water; it splashes and rests if dropped on water.
    case anywhere
    /// Released, not placed: fish, creatures.
    case free
    /// Not an object at all: the moon, the mist, dusk. One of each, switched on.
    case sky
}

/// How a thing is drawn in the plot.
enum ItemArt: Codable, Equatable {
    /// A painted cut-out: `stands` rises from its root, else it lies flat on the water.
    case sprite(name: String, stands: Bool)
    /// A body: shape as `SolidInstance.shape` (2 stone, 3 log, 4 disc, 6 bamboo, 7 sail).
    case solid(shape: UInt32, colourA: SIMD4<Float>, colourB: SIMD4<Float>, texture: String?)
    /// Live fish from the season art sets.
    case koi(texture: String)
    case shoal(texture: String)
    /// A feature with its own behaviour (bamboo rocker, chime stones, basin, lantern, boat, bowl).
    case feature(kind: String)
}

struct CatalogueItem: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let category: ItemCategory
    let rarity: Rarity
    let art: ItemArt
    let placement: Placement
    /// Points across at full size, and the range the pinch allows.
    var size: CGFloat
    var sizeRange: ClosedRange<CGFloat> = 0.8...1.2
    /// Real days to full size from a sprout; 0 = placed full grown.
    var growDays: Double = 0
    /// It flowers: a petal now and then, to be picked up.
    var shedsPetals: Bool = false
    /// The season whose air it belongs to, for the reveal's colour of petals.
    var season: String? = nil
}

/// What the player owns.
struct OwnedItem: Codable, Identifiable, Equatable {
    var id: String            // the catalogue id
    var wonAt: Date
    var fromLevel: String
    var count: Int = 1
}

/// One thing put down in the plot.
struct PlacedItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var item: String          // catalogue id
    var position: CGPoint     // world points in the plot
    var rotation: Float = 0
    var scale: CGFloat = 1
    var plantedAt: Date = Date()
    /// Fish: how big it has grown, 1 = as won.
    var size: CGFloat = 1
    var fedAt: Date? = nil
}

/// The plot as saved.
struct PlotState: Codable, Equatable {
    /// Dug depth 0...255 per cell, row-major, `digWidth` x `digHeight` cells of 2 pt.
    var dig: Data = Data()
    var digWidth: Int = 0
    var digHeight: Int = 0
    /// How full the hollow is, 0...1.
    var water: Float = 0
    var sluiceOpen: Bool = false
    var placed: [PlacedItem] = []
    /// Petals lying on the water waiting to be picked, as world points.
    var petals: [CGPoint] = []
    var lastVisit: Date = Date()
    /// Sky things switched on: "moon", "mist", "dusk", "snow", "fireflies".
    var sky: Set<String> = []
}

/// The draw: which item a win gives.
struct RewardDraw {
    static let rareWithin = 6
    static let goldWithin = 25
    static let odds: [Rarity: Double] = [.common: 0.70, .rare: 0.25, .superRare: 0.05]

    /// Picks a tier by the odds and the pity counters, then an item of that
    /// tier the player does not own (falling back down the tiers, then to
    /// any item at all so a full collection still gets a petal bonus).
    static func draw(owned: Set<String>, winsSinceRare: Int, winsSinceGold: Int,
                     catalogue: [CatalogueItem], random: inout some RandomNumberGenerator) -> CatalogueItem? {
        var tier: Rarity
        let r = Double.random(in: 0..<1, using: &random)
        if winsSinceGold >= goldWithin - 1 { tier = .superRare }
        else if winsSinceRare >= rareWithin - 1 { tier = .rare }
        else if r < odds[.superRare]! { tier = .superRare }
        else if r < odds[.superRare]! + odds[.rare]! { tier = .rare }
        else { tier = .common }
        let order: [Rarity] = tier == .superRare ? [.superRare, .rare, .common]
                            : tier == .rare ? [.rare, .common, .superRare] : [.common, .rare, .superRare]
        for t in order {
            let pool = catalogue.filter { $0.rarity == t && !owned.contains($0.id) }
            if let pick = pool.randomElement(using: &random) { return pick }
        }
        return catalogue.randomElement(using: &random)
    }
}

/// Petals paid by a win.
enum PetalPay {
    static let firstWin = 12
    static let replay = 6
}

/// Tunings shared by the plot.
enum PlotTuning {
    static let cellPoints: CGFloat = 2
    static let brushRadius: CGFloat = 34
    static let digPerPass: Float = 0.08
    /// Seconds for the sluice to fill an empty hollow.
    static let fillSeconds: Float = 90
    /// Real minutes per petal per flowering plant.
    static let petalMinutes: Double = 20
    static let maxFloatingPetals = 40
    /// Real hours between feedings that count.
    static let feedHours: Double = 4
    static let growPerFeed: CGFloat = 0.02
    static let koiMaxSize: CGFloat = 1.3
}
