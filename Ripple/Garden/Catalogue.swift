import Foundation
import CoreGraphics
import simd

// ---------------------------------------------------------------------------
// The catalogue: everything a level win can give, as plain data. Gate 1 lists
// what we already have paintings for; the pool grows to about 120 at gate 2
// by appending here. Ids are stable kebab-case strings and never change once
// a player can own one, since the inventory records them.
// ---------------------------------------------------------------------------

enum Catalogue {

    /// Everything the draw can give, in catalogue order.
    static let items: [CatalogueItem] = bankPlants + aquaticPlants + stones + wood + koi + shoals
        + creatures + features + toys + sky

    /// Owned from the start and never drawn: the food bowl. Kept apart from
    /// `items` so `RewardDraw` cannot pick it.
    static let starters: [CatalogueItem] = [
        CatalogueItem(id: "food-bowl", name: "Food bowl", category: .feature, rarity: .common,
                      art: .feature(kind: "food-bowl"), placement: .bank, size: 30, sizeRange: 1...1),
    ]

    static func item(_ id: String) -> CatalogueItem? { byID[id] }

    /// Both lists together, for anything that shows what the player owns.
    static var all: [CatalogueItem] { items + starters }

    static func items(of rarity: Rarity) -> [CatalogueItem] { items.filter { $0.rarity == rarity } }
    static func items(in category: ItemCategory) -> [CatalogueItem] { items.filter { $0.category == category } }

    private static let byID: [String: CatalogueItem] = {
        var out: [String: CatalogueItem] = [:]
        for item in items + starters { out[item.id] = item }
        return out
    }()

    /// The painting that stands for an item on the tray and in the reveal.
    /// Sprites and textured solids carry their own; features and fish are
    /// looked up here. Nil means draw the item as its body.
    static func icon(for item: CatalogueItem) -> String? {
        switch item.art {
        case .sprite(let name, _): return name
        case .solid(_, _, _, let texture): return texture
        case .koi(let texture): return texture
        case .shoal(let texture): return texture
        case .feature: return featureIcons[item.id]
        }
    }

    private static let featureIcons: [String: String] = [
        "bamboo-rocker": "bamboo_post",
        "chime-stones": "chime_glow",
        "food-bowl": "food_bowl",
        "paper-boat": "paper_boat_1",
        "sailing-boat": "sail_boat",
        "floating-lantern": "lantern_float",
        "tea-bowl": "tea_bowl",
        "dusk": "moon",
    ]

    // MARK: - Bank plants

    private static func bank(_ id: String, _ name: String, sprite: String, size: CGFloat, range: ClosedRange<CGFloat> = 0.8...1.2,
                             rarity: Rarity = .common, grows: Double = 0, flowers: Bool = false, season: String? = nil) -> CatalogueItem {
        CatalogueItem(id: id, name: name, category: .bankPlant, rarity: rarity,
                      art: .sprite(name: sprite, stands: true), placement: .bank,
                      size: size, sizeRange: range, growDays: grows, shedsPetals: flowers, season: season)
    }

    static let bankPlants: [CatalogueItem] = [
        // Reed clumps, one for each season's air.
        bank("reeds-winter", "Winter reeds", sprite: "reed_w_1", size: 76, range: 0.7...1.3, season: "winter"),
        bank("reeds-spring", "Spring reeds", sprite: "reed_s_1", size: 76, range: 0.7...1.3, season: "spring"),
        bank("reeds-summer", "Summer reeds", sprite: "reed_su_1", size: 76, range: 0.7...1.3, season: "summer"),
        bank("reeds-autumn", "Autumn reeds", sprite: "reed_a_1", size: 76, range: 0.7...1.3, season: "autumn"),
        bank("reeds-winter-tall", "Tall winter reeds", sprite: "reed_w_3", size: 92, range: 0.7...1.3, season: "winter"),
        bank("reeds-spring-tall", "Tall spring reeds", sprite: "reed_s_3", size: 92, range: 0.7...1.3, season: "spring"),
        bank("reeds-summer-tall", "Tall summer reeds", sprite: "reed_su_3", size: 92, range: 0.7...1.3, season: "summer"),
        bank("reeds-autumn-tall", "Tall autumn reeds", sprite: "reed_a_3", size: 92, range: 0.7...1.3, season: "autumn"),
        // Flowering clumps: three days from a sprout, and they shed petals.
        bank("blossom-spring-1", "Spring blossom", sprite: "flower_s_1", size: 46, grows: 3, flowers: true, season: "spring"),
        bank("blossom-spring-2", "Primrose clump", sprite: "flower_s_2", size: 46, grows: 3, flowers: true, season: "spring"),
        bank("blossom-spring-3", "Wild violets", sprite: "flower_s_3", size: 46, grows: 3, flowers: true, season: "spring"),
        bank("blossom-summer-1", "Summer flowers", sprite: "flower_su_1", size: 48, grows: 3, flowers: true, season: "summer"),
        bank("blossom-summer-2", "Meadow clump", sprite: "flower_su_2", size: 48, grows: 3, flowers: true, season: "summer"),
        bank("blossom-summer-3", "Marsh marigold", sprite: "flower_su_3", size: 48, grows: 3, flowers: true, season: "summer"),
        bank("blossom-autumn-1", "Autumn flowers", sprite: "flower_a_1", size: 46, grows: 3, flowers: true, season: "autumn"),
        bank("blossom-autumn-2", "Michaelmas daisies", sprite: "flower_a_2", size: 46, grows: 3, flowers: true, season: "autumn"),
        bank("blossom-autumn-3", "Rust chrysanthemum", sprite: "flower_a_3", size: 46, grows: 3, flowers: true, season: "autumn"),
        bank("blossom-winter-1", "Winter flowers", sprite: "flower_w_1", size: 42, grows: 3, flowers: true, season: "winter"),
        bank("blossom-winter-2", "Snowdrops", sprite: "flower_w_2", size: 42, grows: 3, flowers: true, season: "winter"),
        // The blue iris is the rare one.
        bank("iris-blue", "Blue iris", sprite: "iris_1", size: 62, rarity: .rare, grows: 3, flowers: true, season: "summer"),
        bank("iris-blue-pair", "Blue iris pair", sprite: "iris_2", size: 66, rarity: .rare, grows: 3, flowers: true, season: "summer"),
        bank("bulrush", "Bulrush", sprite: "bulrush_1", size: 84, range: 0.7...1.3, season: "autumn"),
        bank("bulrush-pair", "Bulrush pair", sprite: "bulrush_2", size: 88, range: 0.7...1.3, season: "autumn"),
        bank("fern", "Fern", sprite: "fern_1", size: 44, season: "spring"),
        bank("moss", "Moss cushion", sprite: "moss_1", size: 22, range: 0.7...1.4),
    ]

    // MARK: - Aquatic plants

    static let aquaticPlants: [CatalogueItem] = [
        CatalogueItem(id: "lilypad-1", name: "Lily pad", category: .aquaticPlant, rarity: .common,
                      art: .sprite(name: "lilypad_1", stands: false), placement: .shallows,
                      size: 40, sizeRange: 0.7...1.3, growDays: 7, season: "summer"),
        CatalogueItem(id: "lilypad-2", name: "Notched lily pad", category: .aquaticPlant, rarity: .common,
                      art: .sprite(name: "lilypad_2", stands: false), placement: .shallows,
                      size: 38, sizeRange: 0.7...1.3, growDays: 7, season: "summer"),
        CatalogueItem(id: "lilypad-3", name: "Small lily pad", category: .aquaticPlant, rarity: .common,
                      art: .sprite(name: "lilypad_3", stands: false), placement: .shallows,
                      size: 32, sizeRange: 0.7...1.3, growDays: 7, season: "summer"),
        CatalogueItem(id: "lotus", name: "Lotus", category: .aquaticPlant, rarity: .rare,
                      art: .sprite(name: "lotus_1", stands: false), placement: .shallows,
                      size: 50, sizeRange: 0.8...1.3, growDays: 7, shedsPetals: true, season: "summer"),
    ]

    // MARK: - Stones and wood

    private static let stoneGrey: SIMD4<Float> = [0.56, 0.58, 0.60, 1]
    private static let mossGrey: SIMD4<Float> = [0.50, 0.53, 0.52, 1]
    private static let mossGreen: SIMD4<Float> = [0.36, 0.55, 0.30, 1]

    private static func stone(_ id: String, _ name: String, size: CGFloat, mossy: Bool) -> CatalogueItem {
        CatalogueItem(id: id, name: name, category: .stone, rarity: .common,
                      art: .solid(shape: 2, colourA: mossy ? mossGrey : stoneGrey, colourB: mossy ? mossGreen : stoneGrey,
                                  texture: mossy ? "mossstone_1" : "stone_1"),
                      placement: .anywhere, size: size, sizeRange: 0.8...1.2)
    }

    static let stones: [CatalogueItem] = [
        stone("stone-small", "Small stone", size: 28, mossy: false),
        stone("stone-medium", "Stone", size: 40, mossy: false),
        stone("stone-large", "Large stone", size: 56, mossy: false),
        stone("mossy-stone-small", "Small mossy stone", size: 28, mossy: true),
        stone("mossy-stone-medium", "Mossy stone", size: 40, mossy: true),
        stone("mossy-stone-large", "Large mossy stone", size: 56, mossy: true),
    ]

    static let wood: [CatalogueItem] = [
        CatalogueItem(id: "driftwood-log", name: "Driftwood log", category: .wood, rarity: .common,
                      art: .solid(shape: 3, colourA: [0.42, 0.30, 0.20, 1], colourB: [0.78, 0.66, 0.48, 1], texture: "driftwood_1"),
                      placement: .anywhere, size: 96, sizeRange: 0.7...1.3),
    ]

    // MARK: - Fish

    private static func koi(_ id: String, _ name: String, texture: String, rarity: Rarity) -> CatalogueItem {
        CatalogueItem(id: id, name: name, category: .koi, rarity: rarity, art: .koi(texture: texture),
                      placement: .free, size: 74, sizeRange: 0.9...1.1)
    }

    /// The six paintings. n_koi_4 is the plain gold one, the super rare;
    /// the showa (black, orange and white) and the deep crimson kohaku are
    /// the rares.
    static let koi: [CatalogueItem] = [
        koi("koi-orange", "Orange koi", texture: "n_koi_1", rarity: .common),
        koi("koi-kohaku", "Kohaku", texture: "n_koi_2", rarity: .common),
        koi("koi-showa", "Showa koi", texture: "n_koi_3", rarity: .rare),
        koi("koi-golden", "Golden koi", texture: "n_koi_4", rarity: .superRare),
        koi("koi-marbled", "Marbled koi", texture: "n_koi_5", rarity: .common),
        koi("koi-crimson", "Crimson kohaku", texture: "n_koi_6", rarity: .rare),
    ]

    private static func shoal(_ id: String, _ name: String, texture: String, season: String?) -> CatalogueItem {
        CatalogueItem(id: id, name: name, category: .shoal, rarity: .common, art: .shoal(texture: texture),
                      placement: .free, size: 26, sizeRange: 0.9...1.1, season: season)
    }

    static let shoals: [CatalogueItem] = [
        shoal("shoal-minnow", "Minnow shoal", texture: "minnow_1", season: "spring"),
        shoal("shoal-minnow-summer", "Summer minnows", texture: "minnow_2", season: "summer"),
        shoal("shoal-stickleback", "Stickleback shoal", texture: "stickleback_1", season: "spring"),
        shoal("shoal-stickleback-autumn", "Autumn sticklebacks", texture: "stickleback_2", season: "autumn"),
        shoal("shoal-rudd", "Rudd shoal", texture: "rudd_1", season: "summer"),
    ]

    // MARK: - Creatures

    static let creatures: [CatalogueItem] = [
        CatalogueItem(id: "frog", name: "Frog on a pad", category: .creature, rarity: .common,
                      art: .sprite(name: "frog_top", stands: false), placement: .free,
                      size: 30, sizeRange: 0.9...1.1, season: "spring"),
        CatalogueItem(id: "newt", name: "Newt", category: .creature, rarity: .common,
                      art: .sprite(name: "newt_1", stands: false), placement: .free,
                      size: 34, sizeRange: 0.9...1.1, season: "summer"),
        CatalogueItem(id: "dragonfly", name: "Dragonfly", category: .creature, rarity: .common,
                      art: .sprite(name: "dragonfly_1", stands: false), placement: .free,
                      size: 30, sizeRange: 0.9...1.1, season: "summer"),
    ]

    // MARK: - Features

    static let features: [CatalogueItem] = [
        CatalogueItem(id: "bamboo-rocker", name: "Bamboo rocker", category: .feature, rarity: .rare,
                      art: .feature(kind: "bamboo"), placement: .bank, size: 120, sizeRange: 0.9...1.1, season: "spring"),
        CatalogueItem(id: "chime-stones", name: "Chime stones", category: .feature, rarity: .rare,
                      art: .feature(kind: "chime"), placement: .anywhere, size: 70, sizeRange: 0.9...1.1, season: "autumn"),
    ]

    // MARK: - Toys

    static let toys: [CatalogueItem] = [
        CatalogueItem(id: "paper-boat", name: "Paper boat", category: .toy, rarity: .common,
                      art: .feature(kind: "boat"), placement: .water, size: 40, sizeRange: 0.8...1.2),
        CatalogueItem(id: "sailing-boat", name: "Sailing boat", category: .toy, rarity: .superRare,
                      art: .feature(kind: "boat"), placement: .water, size: 56, sizeRange: 0.8...1.2),
        CatalogueItem(id: "floating-lantern", name: "Floating lantern", category: .toy, rarity: .superRare,
                      art: .feature(kind: "lantern"), placement: .water, size: 36, sizeRange: 0.9...1.1),
        CatalogueItem(id: "tea-bowl", name: "Tea bowl", category: .toy, rarity: .rare,
                      art: .feature(kind: "bowl"), placement: .water, size: 32, sizeRange: 0.9...1.1),
    ]

    // MARK: - Sky

    /// One of each, switched on in `PlotState.sky` by the item's id.
    static let sky: [CatalogueItem] = [
        CatalogueItem(id: "moon", name: "The moon", category: .atmosphere, rarity: .superRare,
                      art: .sprite(name: "moon", stands: false), placement: .sky, size: 90, sizeRange: 1...1),
        CatalogueItem(id: "mist", name: "Morning mist", category: .atmosphere, rarity: .common,
                      art: .sprite(name: "mist_1", stands: false), placement: .sky, size: 300, sizeRange: 1...1),
        CatalogueItem(id: "dusk", name: "Dusk", category: .atmosphere, rarity: .rare,
                      art: .feature(kind: "dusk"), placement: .sky, size: 1, sizeRange: 1...1, season: "autumn"),
        CatalogueItem(id: "snow", name: "Falling snow", category: .atmosphere, rarity: .rare,
                      art: .sprite(name: "snow_1", stands: false), placement: .sky, size: 1, sizeRange: 1...1, season: "winter"),
    ]
}
