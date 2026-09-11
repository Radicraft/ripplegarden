import Foundation
import CoreGraphics
import simd

// ---------------------------------------------------------------------------
// The catalogue: everything a level win can give, as plain data. Gate 2:
// every painting in Ripple/Art with a place in the pond, about 130 items.
// Ids are stable kebab-case strings and never change once a player can own
// one, since the inventory records them. Add, never rename.
// ---------------------------------------------------------------------------

enum Catalogue {

    /// Everything the draw can give, in catalogue order.
    static let items: [CatalogueItem] = bankPlants + trees + aquaticPlants + stones + wood + koi + shoals
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
        "stone-basin": "stone_basin_tsukubai",
        "dusk": "moon",
        "fireflies": "firefly",
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
        // Gate 2: the other reed paintings, and the new clumps.
        bank("reeds-winter-tuft", "Winter reed tuft", sprite: "reed_w_2", size: 70, range: 0.7...1.3, season: "winter"),
        bank("reeds-spring-tuft", "Spring reed tuft", sprite: "reed_s_2", size: 70, range: 0.7...1.3, season: "spring"),
        bank("reeds-summer-tuft", "Summer reed tuft", sprite: "reed_su_2", size: 70, range: 0.7...1.3, season: "summer"),
        bank("reeds-autumn-tuft", "Autumn reed tuft", sprite: "reed_a_2", size: 70, range: 0.7...1.3, season: "autumn"),
        bank("reeds-winter-spray", "Winter reed spray", sprite: "reed_w_4", size: 84, range: 0.7...1.3, season: "winter"),
        bank("reeds-spring-spray", "Spring reed spray", sprite: "reed_s_4", size: 84, range: 0.7...1.3, season: "spring"),
        bank("reeds-summer-spray", "Summer reed spray", sprite: "reed_su_4", size: 84, range: 0.7...1.3, season: "summer"),
        bank("reeds-autumn-spray", "Autumn reed spray", sprite: "reed_a_4", size: 84, range: 0.7...1.3, season: "autumn"),
        bank("hellebore", "Hellebore", sprite: "flower_w_3", size: 44, grows: 3, flowers: true, season: "winter"),
        bank("winter-jasmine", "Winter jasmine", sprite: "flower_w_4", size: 48, grows: 3, flowers: true, season: "winter"),
        bank("bluebells", "Bluebells", sprite: "flower_s_4", size: 46, grows: 3, flowers: true, season: "spring"),
        bank("kerria", "Kerria", sprite: "flower_s_5", size: 50, grows: 3, flowers: true, season: "spring"),
        bank("magnolia-sprig", "Magnolia sprig", sprite: "flower_s_6", size: 52, grows: 3, flowers: true, season: "spring"),
        bank("hydrangea-blue", "Blue hydrangea", sprite: "flower_su_4", size: 56, rarity: .rare, grows: 3, flowers: true, season: "summer"),
        bank("peony-pink", "Pink peony", sprite: "flower_su_5", size: 56, rarity: .rare, grows: 3, flowers: true, season: "summer"),
        bank("cosmos-orange", "Orange cosmos", sprite: "flower_su_6", size: 50, grows: 3, flowers: true, season: "summer"),
        bank("chrysanthemum-yellow", "Yellow chrysanthemum", sprite: "flower_a_4", size: 48, grows: 3, flowers: true, season: "autumn"),
        bank("toad-lily", "Toad lily", sprite: "flower_a_5", size: 46, rarity: .rare, grows: 3, flowers: true, season: "autumn"),
        bank("nandina-berries", "Nandina berries", sprite: "flower_a_6", size: 52, grows: 3, season: "autumn"),
        bank("grass-tuft", "Grass tuft", sprite: "grass_1", size: 58, range: 0.7...1.3),
        bank("sedge", "Sedge", sprite: "grass_2", size: 56, range: 0.7...1.3),
        bank("horsetail", "Horsetail", sprite: "horsetail_1", size: 64, range: 0.7...1.3, season: "spring"),
        bank("hosta", "Hosta", sprite: "hosta_1", size: 58, season: "summer"),
        bank("bamboo-clump", "Bamboo clump", sprite: "bamboo_clump_1", size: 92, range: 0.7...1.3),
        bank("iris-yellow", "Yellow iris", sprite: "iris_yellow", size: 60, grows: 3, flowers: true, season: "spring"),
        bank("cattail", "Cattail", sprite: "cattail_1", size: 84, range: 0.7...1.3, season: "autumn"),
    ]

    // MARK: - Trees

    /// A fortnight from a sprout to full height. They stand at the bank and
    /// are the biggest things in the pond.
    private static func tree(_ id: String, _ name: String, sprite: String, size: CGFloat, rarity: Rarity = .common,
                             flowers: Bool = false, season: String?) -> CatalogueItem {
        CatalogueItem(id: id, name: name, category: .tree, rarity: rarity,
                      art: .sprite(name: sprite, stands: true), placement: .bank,
                      size: size, sizeRange: 0.8...1.25, growDays: 14, shedsPetals: flowers, season: season)
    }

    static let trees: [CatalogueItem] = [
        tree("maple-red", "Red maple", sprite: "tree_maple_red", size: 200, rarity: .rare, season: "autumn"),
        tree("maple-green", "Green maple", sprite: "tree_maple_green", size: 190, season: "summer"),
        tree("cherry-blossom", "Cherry in blossom", sprite: "tree_cherry_bloom", size: 210, rarity: .rare, flowers: true, season: "spring"),
        tree("willow", "Willow", sprite: "tree_willow", size: 220, rarity: .rare, season: "summer"),
        tree("pine", "Pine", sprite: "tree_pine", size: 200, rarity: .rare, season: "winter"),
        tree("plum-white", "White plum", sprite: "tree_plum_white", size: 190, flowers: true, season: "spring"),
        tree("ginkgo-gold", "Golden ginkgo", sprite: "tree_ginkgo_gold", size: 200, rarity: .rare, season: "autumn"),
        tree("wisteria", "Wisteria", sprite: "tree_wisteria", size: 210, rarity: .superRare, flowers: true, season: "spring"),
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
        aquatic("lily-white", "White water lily", sprite: "lilypad_flower_white", size: 44, flowers: true),
        aquatic("lily-pink", "Pink water lily", sprite: "lilypad_flower_pink", size: 44, rarity: .rare, flowers: true),
        aquatic("lotus-white", "White lotus", sprite: "lotus_white", size: 50, rarity: .rare, flowers: true),
        aquatic("lotus-leaf", "Lotus leaf", sprite: "lotus_leaf", size: 48),
        aquatic("water-hyacinth", "Water hyacinth", sprite: "water_hyacinth", size: 40, flowers: true),
        aquatic("duckweed-patch", "Duckweed patch", sprite: "duckweed_patch", size: 60, range: 0.7...1.5),
        aquatic("arrowhead", "Arrowhead", sprite: "arrowhead_1", size: 54, stands: true),
    ]

    private static func aquatic(_ id: String, _ name: String, sprite: String, size: CGFloat, range: ClosedRange<CGFloat> = 0.8...1.3,
                                rarity: Rarity = .common, flowers: Bool = false, stands: Bool = false) -> CatalogueItem {
        CatalogueItem(id: id, name: name, category: .aquaticPlant, rarity: rarity,
                      art: .sprite(name: sprite, stands: stands), placement: .shallows,
                      size: size, sizeRange: range, growDays: 7, shedsPetals: flowers, season: "summer")
    }

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
        piece("standing-stone", "Standing stone", sprite: "stone_standing_1", size: 48, stands: true, category: .stone),
        piece("standing-stone-low", "Low standing stone", sprite: "stone_standing_2", size: 52, stands: true, category: .stone),
        piece("stepping-stones", "Stepping stones", sprite: "stepping_stones", size: 180, category: .stone),
        piece("stone-bridge", "Stone bridge", sprite: "stone_bridge", size: 190, rarity: .rare, category: .stone),
        piece("rock-pile", "Rock pile", sprite: "rock_pile", size: 64, category: .stone),
    ]

    /// A painted piece of ground furniture: lies flat unless it stands.
    private static func piece(_ id: String, _ name: String, sprite: String, size: CGFloat, range: ClosedRange<CGFloat> = 0.8...1.2,
                              rarity: Rarity = .common, stands: Bool = false, placement: Placement = .anywhere,
                              category: ItemCategory, season: String? = nil) -> CatalogueItem {
        CatalogueItem(id: id, name: name, category: category, rarity: rarity,
                      art: .sprite(name: sprite, stands: stands), placement: placement,
                      size: size, sizeRange: range, season: season)
    }

    static let wood: [CatalogueItem] = [
        CatalogueItem(id: "driftwood-log", name: "Driftwood log", category: .wood, rarity: .common,
                      art: .solid(shape: 3, colourA: [0.42, 0.30, 0.20, 1], colourB: [0.78, 0.66, 0.48, 1], texture: "driftwood_1"),
                      placement: .anywhere, size: 96, sizeRange: 0.7...1.3),
        piece("log-mossy", "Mossy log", sprite: "log_mossy", size: 110, range: 0.7...1.3, category: .wood),
        piece("stump", "Tree stump", sprite: "stump_1", size: 44, placement: .bank, category: .wood),
        piece("wooden-bridge", "Wooden bridge", sprite: "wooden_bridge", size: 200, category: .wood),
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
        koi("koi-kohaku-2", "Kohaku, red head", texture: "n_koi_7", rarity: .common),
        koi("koi-sanke", "Sanke", texture: "n_koi_8", rarity: .common),
        koi("koi-ochiba", "Ochiba", texture: "n_koi_9", rarity: .rare),
        koi("koi-platinum", "Platinum ogon", texture: "n_koi_10", rarity: .rare),
        koi("koi-kin-showa", "Kin showa", texture: "n_koi_11", rarity: .superRare),
        koi("koi-asagi", "Asagi", texture: "n_koi_12", rarity: .rare),
    ]

    private static func shoal(_ id: String, _ name: String, texture: String, season: String?, rarity: Rarity = .common) -> CatalogueItem {
        CatalogueItem(id: id, name: name, category: .shoal, rarity: rarity, art: .shoal(texture: texture),
                      placement: .free, size: 26, sizeRange: 0.9...1.1, season: season)
    }

    static let shoals: [CatalogueItem] = [
        shoal("shoal-minnow", "Minnow shoal", texture: "minnow_1", season: "spring"),
        shoal("shoal-minnow-summer", "Summer minnows", texture: "minnow_2", season: "summer"),
        shoal("shoal-stickleback", "Stickleback shoal", texture: "stickleback_1", season: "spring"),
        shoal("shoal-stickleback-autumn", "Autumn sticklebacks", texture: "stickleback_2", season: "autumn"),
        shoal("shoal-rudd", "Rudd shoal", texture: "rudd_1", season: "summer"),
        shoal("shoal-golden-orfe", "Golden orfe", texture: "shoal_gold_1", season: "summer", rarity: .rare),
        shoal("shoal-silver-dace", "Silver dace", texture: "shoal_silver_1", season: "spring"),
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
        creature("turtle", "Turtle", sprite: "turtle_1", size: 44, rarity: .rare, placement: .water, season: "summer"),
        creature("duck-mandarin", "Mandarin duck", sprite: "duck_1", size: 40, rarity: .superRare, placement: .water, season: "autumn"),
        creature("duck-mallard", "Mallard", sprite: "duck_2", size: 42, placement: .water),
        creature("heron", "Heron", sprite: "heron_standing", size: 48, rarity: .rare, stands: true, placement: .bank),
        creature("snail", "Snail", sprite: "snail_2", size: 20, placement: .anywhere, season: "spring"),
        creature("butterfly-white", "White butterfly", sprite: "butterfly_1", size: 26, season: "spring"),
        creature("butterfly-swallowtail", "Swallowtail", sprite: "butterfly_2", size: 30, rarity: .rare, season: "summer"),
        creature("frog-green", "Green frog", sprite: "frog_2", size: 30, season: "summer"),
    ]

    private static func creature(_ id: String, _ name: String, sprite: String, size: CGFloat, rarity: Rarity = .common,
                                 stands: Bool = false, placement: Placement = .free, season: String? = nil) -> CatalogueItem {
        CatalogueItem(id: id, name: name, category: .creature, rarity: rarity,
                      art: .sprite(name: sprite, stands: stands), placement: placement,
                      size: size, sizeRange: 0.9...1.1, season: season)
    }

    // MARK: - Features

    static let features: [CatalogueItem] = [
        CatalogueItem(id: "bamboo-rocker", name: "Bamboo rocker", category: .feature, rarity: .rare,
                      art: .feature(kind: "bamboo"), placement: .bank, size: 120, sizeRange: 0.9...1.1, season: "spring"),
        CatalogueItem(id: "chime-stones", name: "Chime stones", category: .feature, rarity: .rare,
                      art: .feature(kind: "chime"), placement: .anywhere, size: 70, sizeRange: 0.9...1.1, season: "autumn"),
        piece("stone-lantern", "Stone lantern", sprite: "lantern_stone", size: 60, rarity: .rare, stands: true, placement: .bank, category: .feature),
        piece("paper-lantern-red", "Red paper lantern", sprite: "lantern_paper_red", size: 44, rarity: .rare, stands: true, placement: .bank, category: .feature),
        piece("bird-bath", "Bird bath", sprite: "bird_bath", size: 52, stands: true, placement: .bank, category: .feature),
        piece("torii", "Small torii", sprite: "torii_small", size: 90, rarity: .superRare, stands: true, placement: .bank, category: .feature),
        piece("bench", "Wooden bench", sprite: "bench_wood", size: 90, placement: .bank, category: .feature),
        piece("bucket", "Wooden bucket", sprite: "bucket_wood", size: 34, stands: true, placement: .bank, category: .feature),
        piece("windchime", "Wind chime", sprite: "windchime", size: 40, rarity: .rare, stands: true, placement: .bank, category: .feature),
        piece("tea-house", "Tiny tea house", sprite: "tea_house_tiny", size: 140, rarity: .superRare, stands: true, placement: .bank, category: .feature),
        CatalogueItem(id: "stone-basin", name: "Stone basin", category: .feature, rarity: .rare,
                      art: .feature(kind: "basin"), placement: .anywhere, size: 56, sizeRange: 0.9...1.1),
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
        CatalogueItem(id: "paper-crane", name: "Paper crane", category: .toy, rarity: .common,
                      art: .sprite(name: "crane_paper", stands: false), placement: .water, size: 34, sizeRange: 0.8...1.2),
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
        CatalogueItem(id: "fireflies", name: "Fireflies", category: .atmosphere, rarity: .rare,
                      art: .feature(kind: "fireflies"), placement: .sky, size: 1, sizeRange: 1...1, season: "summer"),
    ]
}
