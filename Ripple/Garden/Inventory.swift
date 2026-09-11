import Foundation
import simd

// ---------------------------------------------------------------------------
// What the player owns: the items won from the catalogue, the petal purse
// and the pity counters behind the draw. Kept in memory for the views and
// written through to ProgressStore on every change, so it mirrors with the
// rest of the progress.
// ---------------------------------------------------------------------------

@MainActor
final class Inventory: ObservableObject {

    static let shared = Inventory()

    /// Everything owned, oldest win first, with the starters in front.
    @Published private(set) var owned: [OwnedItem] = []
    @Published private(set) var ownedIDs: Set<String> = []
    @Published private(set) var petals: Int = 0
    /// Wins since the last rare or better, and since the last super rare.
    @Published private(set) var winsSinceRare: Int = 0
    @Published private(set) var winsSinceGold: Int = 0
    /// The plots along the bank that may be dug: 0 always, the rest bought.
    @Published private(set) var plotsOwned: Set<Int> = [0]
    /// Item id to the tint it wears, for the ones a colourway was bought for.
    @Published private(set) var colourways: [String: String] = [:]

    private let store: ProgressStore

    private init(store: ProgressStore = .shared) {
        self.store = store
        load()
        applyLaunchFlags()
    }

    private func load() {
        var list = store.owned()
        // The starters are owned from the first launch and never recorded,
        // so a reset does not lose them.
        for starter in Catalogue.starters where !list.contains(where: { $0.id == starter.id }) {
            list.insert(OwnedItem(id: starter.id, wonAt: .distantPast, fromLevel: ""), at: 0)
        }
        owned = list
        ownedIDs = Set(list.map(\.id))
        let w = store.wallet()
        petals = w.petals
        winsSinceRare = w.sinceRare
        winsSinceGold = w.sinceGold
        plotsOwned = store.ownedPlots()
        colourways = store.colourways()
    }

    // MARK: - Winning

    /// A level win: draws an item by the odds and the pity counters, pays
    /// the petals, and records both. `replay` is a level already finished
    /// before, which pays less but draws again all the same.
    @discardableResult
    func award(level: String, replay: Bool, using rng: inout some RandomNumberGenerator)
        -> (item: CatalogueItem, rarity: Rarity, petals: Int) {
        let drawn = RewardDraw.draw(owned: ownedIDs.subtracting(Catalogue.starters.map(\.id)),
                                    winsSinceRare: winsSinceRare, winsSinceGold: winsSinceGold,
                                    catalogue: Catalogue.items, random: &rng)
        let item = drawn ?? Catalogue.items[0]
        let rarity = item.rarity
        let pay = (replay ? PetalPay.replay : PetalPay.firstWin) + rarity.petalBonus

        let won = OwnedItem(id: item.id, wonAt: Date(), fromLevel: level)
        if let i = owned.firstIndex(where: { $0.id == item.id }) {
            owned[i].count += 1
        } else {
            owned.append(won)
        }
        ownedIDs.insert(item.id)
        store.addOwned(won)

        switch rarity {
        case .superRare:
            winsSinceRare = 0
            winsSinceGold = 0
        case .rare:
            winsSinceRare = 0
            winsSinceGold += 1
        case .common:
            winsSinceRare += 1
            winsSinceGold += 1
        }
        petals += pay
        saveWallet()
        return (item, rarity, pay)
    }

    /// The same counters as `award` moves, without any inventory: what the
    /// draw check runs.
    static func advance(rare: inout Int, gold: inout Int, after rarity: Rarity) {
        switch rarity {
        case .superRare: rare = 0; gold = 0
        case .rare: rare = 0; gold += 1
        case .common: rare += 1; gold += 1
        }
    }

    // MARK: - Petals

    /// Takes `n` petals if there are enough; false and nothing taken if not.
    func spend(_ n: Int) -> Bool {
        guard n >= 0, petals >= n else { return false }
        petals -= n
        saveWallet()
        return true
    }

    func addPetals(_ n: Int) {
        guard n > 0 else { return }
        petals += n
        saveWallet()
    }

    func owns(_ id: String) -> Bool { ownedIDs.contains(id) }

    func count(of id: String) -> Int { owned.first { $0.id == id }?.count ?? 0 }

    // MARK: - Plots along the bank

    /// How many plots the bank has room for, and what each costs. Plot 0
    /// is free; the price is in petals, never money.
    static let plotCount = 3
    static let plotPrices: [Int] = [0, 120, 300]

    static func plotPrice(_ index: Int) -> Int {
        index >= 0 && index < plotPrices.count ? plotPrices[index] : plotPrices.last ?? 0
    }

    func ownsPlot(_ index: Int) -> Bool { plotsOwned.contains(index) }

    /// The plots owned, in order along the bank.
    var ownedPlotIndices: [Int] { plotsOwned.sorted() }

    /// The next plot that could be bought, or nil when the bank is full.
    var nextPlotIndex: Int? {
        let next = (plotsOwned.max() ?? 0) + 1
        return next < Inventory.plotCount ? next : nil
    }

    /// Pays for a plot and records the deed. False and nothing taken if
    /// the purse is short, the plot is owned, or the bank has no room.
    @discardableResult
    func buyPlot(_ index: Int) -> Bool {
        guard index > 0, index < Inventory.plotCount, !plotsOwned.contains(index) else { return false }
        guard spend(Inventory.plotPrice(index)) else { return false }
        plotsOwned.insert(index)
        store.addPlotDeed(index: index)
        return true
    }

    // MARK: - Colourways

    /// The tints a thing can be bought in, by name, and what each costs.
    /// Independent of the catalogue: any item can wear any of these.
    static let tintNames = ["indigo", "gold", "white", "crimson"]
    static let colourwayPrice = 40

    /// The tint as a multiplier the plot lays over the sprite's own colour.
    /// A name it does not know, or none, is plain white: no change.
    static func tintColour(named name: String?) -> SIMD4<Float> {
        switch name {
        case "indigo": return [0.55, 0.62, 0.98, 1]
        case "gold": return [1.0, 0.84, 0.45, 1]
        case "white": return [1.05, 1.05, 1.02, 1]
        case "crimson": return [1.0, 0.42, 0.40, 1]
        default: return [1, 1, 1, 1]
        }
    }

    /// Buys a tint for an item. A second colourway for the same item costs
    /// again and replaces the first. False and nothing taken if the tint is
    /// not one offered, the item is not owned, or the purse is short.
    @discardableResult
    func buyColourway(item: String, tint: String) -> Bool {
        guard Inventory.tintNames.contains(tint), ownedIDs.contains(item) else { return false }
        guard colourways[item] != tint else { return true }
        guard spend(Inventory.colourwayPrice) else { return false }
        colourways[item] = tint
        store.setColourway(item: item, tint: tint)
        return true
    }

    /// The multiplier the plot puts on an item's sprite: its bought tint,
    /// or white for the item's own colours.
    func tint(for item: String) -> SIMD4<Float> {
        Inventory.tintColour(named: colourways[item])
    }

    private func saveWallet() {
        store.setWallet(petals: petals, sinceRare: winsSinceRare, sinceGold: winsSinceGold)
    }

    // MARK: - Launch flags

    /// `-grantAll` owns every catalogue item with 500 petals; `-grant a,b,c`
    /// owns the ids given; `-drawCheck` runs the seeded draw check and logs
    /// it. All for looking at the garden without playing the year through.
    private func applyLaunchFlags() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-grantAll") {
            grant(Catalogue.items.map(\.id), level: "grant")
            if petals < 500 { addPetals(500 - petals) }
        }
        if let i = args.firstIndex(of: "-grant"), i + 1 < args.count {
            let ids = args[i + 1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            grant(ids, level: "grant")
        }
        #if DEBUG
        if args.contains("-drawCheck") { Inventory.selfCheck() }
        #endif
    }

    /// Owns each id given that is in the catalogue and not owned yet.
    func grant(_ ids: [String], level: String) {
        var added = false
        for id in ids where Catalogue.item(id) != nil && !ownedIDs.contains(id) {
            let won = OwnedItem(id: id, wonAt: Date(), fromLevel: level)
            owned.append(won)
            ownedIDs.insert(id)
            store.addOwned(won)
            added = true
        }
        if added { objectWillChange.send() }
    }

    // MARK: - The draw check

    #if DEBUG
    /// A thousand draws with a seeded generator and an empty collection,
    /// the pity counters moving as `award` moves them. Logs the tier split
    /// (should be near 70 / 25 / 5) and the longest runs without a rare and
    /// without a gold (must be under 6 and 25). Returns true if it passes.
    @discardableResult
    static func selfCheck(seed: UInt64 = 0x5EED_1234, draws: Int = 1000) -> Bool {
        var rng = SeededGenerator(seed: seed)
        var counts: [Rarity: Int] = [.common: 0, .rare: 0, .superRare: 0]
        var sinceRare = 0, sinceGold = 0
        var longestNoRare = 0, longestNoGold = 0
        var runNoRare = 0, runNoGold = 0
        var missing = 0
        for _ in 0..<draws {
            guard let item = RewardDraw.draw(owned: [], winsSinceRare: sinceRare, winsSinceGold: sinceGold,
                                             catalogue: Catalogue.items, random: &rng) else { missing += 1; continue }
            counts[item.rarity, default: 0] += 1
            // A run is the wins before the one that pays: a rare on the
            // sixth win means five without, so "within 6" holds.
            if item.rarity == .common { runNoRare += 1 } else { runNoRare = 0 }
            if item.rarity == .superRare { runNoGold = 0 } else { runNoGold += 1 }
            longestNoRare = max(longestNoRare, runNoRare)
            longestNoGold = max(longestNoGold, runNoGold)
            advance(rare: &sinceRare, gold: &sinceGold, after: item.rarity)
        }
        let n = Double(max(1, draws))
        let c = Double(counts[.common] ?? 0) / n, r = Double(counts[.rare] ?? 0) / n, g = Double(counts[.superRare] ?? 0) / n
        // The pity floors push the split toward rare and gold: over 100k
        // draws the raw odds come out 69.8 / 25.3 / 4.9 and with pity
        // 64.8 / 28.5 / 6.7, so the bands sit around the latter.
        let splitOK = (0.60...0.72).contains(c) && (0.23...0.34).contains(r) && (0.04...0.10).contains(g)
        let pityOK = longestNoRare < RewardDraw.rareWithin && longestNoGold < RewardDraw.goldWithin
        let ok = splitOK && pityOK && missing == 0
        NSLog("Inventory.selfCheck seed %llx: %d draws over %d items: common %.1f%% rare %.1f%% gold %.1f%%; longest run without a rare %d (limit %d), without a gold %d (limit %d); %@",
              seed, draws, Catalogue.items.count, c * 100, r * 100, g * 100,
              longestNoRare, RewardDraw.rareWithin - 1, longestNoGold, RewardDraw.goldWithin - 1, ok ? "PASS" : "FAIL")
        return ok
    }
    #endif
}

/// A small seeded generator (SplitMix64) so a draw can be replayed exactly.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
