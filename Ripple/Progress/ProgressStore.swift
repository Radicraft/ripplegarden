import Foundation
import SwiftData
import SwiftUI

/// A finished level. No score, no stars, just that it was done and when.
@Model
final class LevelRecord {
    var levelID: String = ""
    var seasonID: String = ""
    var completedAt: Date = Date()
    /// What finishing it left alive in its pool, as `WokeToken` raw values.
    /// Optional so a record made before the pools could wake still mirrors.
    var woke: [String]? = nil

    init(levelID: String, seasonID: String) {
        self.levelID = levelID
        self.seasonID = seasonID
    }
}

/// How far a season's garden has bloomed.
@Model
final class GardenRecord {
    var seasonID: String = ""
    var bloomStage: Double = 0

    init(seasonID: String, bloomStage: Double) {
        self.seasonID = seasonID
        self.bloomStage = bloomStage
    }
}

/// One thing the player owns from the garden catalogue. A record per win,
/// so a second copy of a common is a second record and `count` stays 1
/// unless a store merges them; readers sum by item id.
@Model
final class OwnedRecord {
    var itemID: String = ""
    var wonAt: Date = Date()
    var fromLevel: String = ""
    var count: Int = 1

    init(itemID: String, wonAt: Date, fromLevel: String, count: Int = 1) {
        self.itemID = itemID
        self.wonAt = wonAt
        self.fromLevel = fromLevel
        self.count = count
    }
}

/// The petal purse and the pity counters. Meant as one row; if a sync ever
/// leaves two, the reader takes the richest one.
@Model
final class WalletRecord {
    var petals: Int = 0
    var winsSinceRare: Int = 0
    var winsSinceGold: Int = 0

    init(petals: Int = 0, winsSinceRare: Int = 0, winsSinceGold: Int = 0) {
        self.petals = petals
        self.winsSinceRare = winsSinceRare
        self.winsSinceGold = winsSinceGold
    }
}

/// A plot of the player's own pond, its `PlotState` as JSON. One row per
/// plot index; more plots come at gate 3.
@Model
final class PlotRecord {
    var plotIndex: Int = 0
    var json: Data? = nil
    var savedAt: Date = Date()

    init(plotIndex: Int, json: Data) {
        self.plotIndex = plotIndex
        self.json = json
        self.savedAt = Date()
    }
}

/// The petals a woken pool on the map has grown and not yet had picked.
/// One row per level; if a sync leaves two, the reader takes the one
/// with the most petals and the later clock.
@Model
final class PoolPetalsRecord {
    var levelID: String = ""
    var count: Int = 0
    /// When the count last stepped, so growth carries on from there.
    var lastGrownAt: Date = Date()
    var lastCollected: Date? = nil

    init(levelID: String, count: Int, lastGrownAt: Date, lastCollected: Date?) {
        self.levelID = levelID
        self.count = count
        self.lastGrownAt = lastGrownAt
        self.lastCollected = lastCollected
    }
}

/// A plot along the bank the player has paid for. Plot 0 is never
/// recorded: it is free. A row per plot, so two devices that both bought
/// one merge to the union.
@Model
final class PlotDeedRecord {
    var plotIndex: Int = 0
    var dugAt: Date = Date()

    init(plotIndex: Int) {
        self.plotIndex = plotIndex
        self.dugAt = Date()
    }
}

/// A tint bought for one catalogue item. The latest row per item wins.
@Model
final class ColourwayRecord {
    var itemID: String = ""
    var tint: String = ""
    var boughtAt: Date = Date()

    init(itemID: String, tint: String) {
        self.itemID = itemID
        self.tint = tint
        self.boughtAt = Date()
    }
}

/// Progress lives in SwiftData and mirrors through the player's private
/// CloudKit database, so a level finished on one device is finished on all
/// of them. Every property has a default and nothing is unique, which is what
/// CloudKit mirroring requires. If the container cannot be opened with
/// CloudKit (no entitlement yet, or no account), it falls back to local, and
/// then to memory, rather than refusing to start.
@MainActor
final class ProgressStore: ObservableObject {

    static let shared = ProgressStore()

    /// Nil only if every attempt at a store failed, which would take a
    /// broken schema. The game then runs with no memory rather than dying.
    let container: ModelContainer?
    private var context: ModelContext? { container?.mainContext }
    /// Bumped on every write so the path redraws.
    @Published private(set) var version = 0

    private init() {
        let schema = Schema([LevelRecord.self, GardenRecord.self,
                             OwnedRecord.self, WalletRecord.self, PlotRecord.self,
                             PoolPetalsRecord.self, PlotDeedRecord.self, ColourwayRecord.self])
        let reset = ProcessInfo.processInfo.arguments.contains("-resetProgress")

        // CloudKit mirroring does not throw when the entitlement is missing;
        // it traps on a background queue a moment after launch. So the
        // entitlement is checked first: Simulator builds and Debug device
        // builds (signed with the plain team profile) get a local store.
        var attempts: [ModelConfiguration] = []
        if Entitlements.hasCloudKit {
            attempts.append(ModelConfiguration("Progress", schema: schema,
                                               cloudKitDatabase: .private("iCloud.com.radicraft.ripple")))
        }
        attempts.append(ModelConfiguration("Progress", schema: schema, cloudKitDatabase: .none))
        attempts.append(ModelConfiguration("Memory", schema: schema, isStoredInMemoryOnly: true))

        var made: ModelContainer?
        for config in attempts {
            if let c = try? ModelContainer(for: schema, configurations: [config]) {
                made = c
                break
            }
        }
        container = made
        guard let context else { return }

        if reset {
            try? context.delete(model: LevelRecord.self)
            try? context.delete(model: GardenRecord.self)
            try? context.delete(model: OwnedRecord.self)
            try? context.delete(model: WalletRecord.self)
            try? context.delete(model: PlotRecord.self)
            try? context.delete(model: PoolPetalsRecord.self)
            try? context.delete(model: PlotDeedRecord.self)
            try? context.delete(model: ColourwayRecord.self)
            try? context.save()
            UserDefaults.standard.removeObject(forKey: ProgressStore.tutorialKey)
        }
        // `-unlockAll` opens every level for testing, and wakes each pool
        // the way its level will once the goals land, so the map can be
        // seen alive without playing the year through.
        if ProcessInfo.processInfo.arguments.contains("-unlockAll") {
            for l in Library.levels where !isComplete(levelID: l.id) {
                context.insert(LevelRecord(levelID: l.id, seasonID: l.seasonID))
            }
            try? context.save()
            for l in Library.levels {
                markWoke(levelID: l.id, tokens: ProgressStore.rehearsalTokens(for: l))
            }
        }
        // The garden's flags live in Inventory, which reads this store, so
        // it is woken a turn later rather than from inside this init.
        let gardenFlags = ["-grantAll", "-grant", "-drawCheck"]
        if ProcessInfo.processInfo.arguments.contains(where: gardenFlags.contains) {
            DispatchQueue.main.async { _ = Inventory.shared }
        }
    }

    // MARK: - The first walk

    private static let tutorialKey = "tutorial.done"

    /// Whether the first walk through the game has been made. Kept in
    /// defaults rather than a record: it is one bit about this device's
    /// player, and the schema stays as it is. Off until the walk is done.
    var tutorialDone: Bool {
        get { UserDefaults.standard.bool(forKey: ProgressStore.tutorialKey) }
        set { UserDefaults.standard.set(newValue, forKey: ProgressStore.tutorialKey) }
    }

    /// The tokens the roster in docs/gameplay-spec.md gives each level, for
    /// `-unlockAll` only. Play records the real ones from the goals.
    private static func rehearsalTokens(for level: LevelSpec) -> Set<WokeToken> {
        guard let season = Library.season(id: level.seasonID),
              let i = Library.levels(in: season).firstIndex(where: { $0.id == level.id }) else { return [] }
        let roster: [[Set<WokeToken>]] = [
            [[.clear], [.koi], [.shoal], [.bud], [.moon], [.koi, .shoal]],
            [[.clear], [.seeds], [.koi, .bud], [.shoal], [.bamboo], [.clear, .seeds, .koi]],
            [[.clear], [.bud], [.shoal], [.chime], [.shy, .koi], [.bud, .shoal]],
            [[.clear], [.pool], [.shoal], [.shy, .koi], [.clear], [.moon]],
        ]
        let s = season.order - 1
        guard s >= 0, s < roster.count, i < roster[s].count else { return [.clear] }
        return roster[s][i]
    }

    // MARK: - What a pool has been woken into

    /// Everything finishing this level has ever left alive in its pool. The
    /// union over every record, since a level synced from two devices can
    /// have two.
    func woke(levelID: String) -> Set<WokeToken> {
        guard let context else { return [] }
        let descriptor = FetchDescriptor<LevelRecord>(predicate: #Predicate { $0.levelID == levelID })
        var out: Set<WokeToken> = []
        for record in (try? context.fetch(descriptor)) ?? [] {
            for raw in record.woke ?? [] {
                if let t = WokeToken(rawValue: raw) { out.insert(t) }
            }
        }
        return out
    }

    /// Add what a finished level woke to what its pool already has. Nothing
    /// is ever taken away: what you woke stays. A level with no record yet
    /// gets one, since a pool that has woken has been played through.
    func markWoke(levelID: String, tokens: Set<WokeToken>) {
        guard let context else { return }
        let had = woke(levelID: levelID)
        let all = had.union(tokens)
        let descriptor = FetchDescriptor<LevelRecord>(predicate: #Predicate { $0.levelID == levelID })
        let records = (try? context.fetch(descriptor)) ?? []
        guard all != had || records.isEmpty else { return }
        let raw = WokeToken.allCases.filter { all.contains($0) }.map(\.rawValue)
        if let record = records.first {
            record.woke = raw
        } else if let level = Library.levels.first(where: { $0.id == levelID }) {
            let record = LevelRecord(levelID: levelID, seasonID: level.seasonID)
            record.woke = raw
            context.insert(record)
        } else {
            return
        }
        try? context.save()
        version += 1
    }

    func isComplete(levelID: String) -> Bool {
        guard let context else { return false }
        let descriptor = FetchDescriptor<LevelRecord>(predicate: #Predicate { $0.levelID == levelID })
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    func completedCount(seasonID: String) -> Int {
        guard let context else { return 0 }
        let descriptor = FetchDescriptor<LevelRecord>(predicate: #Predicate { $0.seasonID == seasonID })
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    func bloomStage(for seasonID: String) -> Float {
        guard let context else { return 0 }
        let descriptor = FetchDescriptor<GardenRecord>(predicate: #Predicate { $0.seasonID == seasonID })
        return Float((try? context.fetch(descriptor))?.map(\.bloomStage).max() ?? 0)
    }

    /// A season opens when the one before it is finished.
    func isUnlocked(season: Season) -> Bool {
        guard let previous = Library.seasons.first(where: { $0.order == season.order - 1 }) else { return true }
        return Library.levels(in: previous).allSatisfy { isComplete(levelID: $0.id) }
    }

    func isUnlocked(level: LevelSpec) -> Bool {
        guard let season = Library.season(id: level.seasonID), isUnlocked(season: season) else { return false }
        let siblings = Library.levels(in: season)
        guard let i = siblings.firstIndex(where: { $0.id == level.id }) else { return false }
        return i == 0 || isComplete(levelID: siblings[i - 1].id)
    }

    func markComplete(levelID: String, seasonID: String, bloomStage: Float) {
        guard let context else { return }
        if !isComplete(levelID: levelID) {
            context.insert(LevelRecord(levelID: levelID, seasonID: seasonID))
        }
        let descriptor = FetchDescriptor<GardenRecord>(predicate: #Predicate { $0.seasonID == seasonID })
        if let record = (try? context.fetch(descriptor))?.first {
            record.bloomStage = max(record.bloomStage, Double(bloomStage))
        } else {
            context.insert(GardenRecord(seasonID: seasonID, bloomStage: Double(bloomStage)))
        }
        try? context.save()
        version += 1
    }
    // MARK: - The garden: what is owned, the purse, the plot

    /// Everything owned, oldest win first. Records synced from two devices
    /// for the same item are merged by summing their counts.
    func owned() -> [OwnedItem] {
        guard let context else { return [] }
        var descriptor = FetchDescriptor<OwnedRecord>()
        descriptor.sortBy = [SortDescriptor(\.wonAt)]
        var out: [OwnedItem] = []
        var index: [String: Int] = [:]
        for r in (try? context.fetch(descriptor)) ?? [] {
            if let i = index[r.itemID] {
                out[i].count += max(1, r.count)
            } else {
                index[r.itemID] = out.count
                out.append(OwnedItem(id: r.itemID, wonAt: r.wonAt, fromLevel: r.fromLevel, count: max(1, r.count)))
            }
        }
        return out
    }

    /// A win: a new record for the item, even if one is already owned.
    func addOwned(_ item: OwnedItem) {
        guard let context else { return }
        context.insert(OwnedRecord(itemID: item.id, wonAt: item.wonAt, fromLevel: item.fromLevel, count: max(1, item.count)))
        try? context.save()
        version += 1
    }

    /// Takes every owned record away; `-resetProgress` and the grant flags.
    func clearOwned() {
        guard let context else { return }
        try? context.delete(model: OwnedRecord.self)
        try? context.save()
        version += 1
    }

    private func walletRecord() -> WalletRecord? {
        guard let context else { return nil }
        let rows = (try? context.fetch(FetchDescriptor<WalletRecord>())) ?? []
        return rows.max { $0.petals < $1.petals }
    }

    func wallet() -> (petals: Int, sinceRare: Int, sinceGold: Int) {
        guard let w = walletRecord() else { return (0, 0, 0) }
        return (w.petals, w.winsSinceRare, w.winsSinceGold)
    }

    func setWallet(petals: Int, sinceRare: Int, sinceGold: Int) {
        guard let context else { return }
        if let w = walletRecord() {
            w.petals = petals
            w.winsSinceRare = sinceRare
            w.winsSinceGold = sinceGold
        } else {
            context.insert(WalletRecord(petals: petals, winsSinceRare: sinceRare, winsSinceGold: sinceGold))
        }
        try? context.save()
        version += 1
    }

    /// The saved plot, or nil if it has never been dug.
    func plot(index: Int) -> PlotState? {
        guard let context else { return nil }
        let descriptor = FetchDescriptor<PlotRecord>(predicate: #Predicate { $0.plotIndex == index })
        let rows = (try? context.fetch(descriptor)) ?? []
        guard let row = rows.max(by: { $0.savedAt < $1.savedAt }), let data = row.json else { return nil }
        return try? JSONDecoder().decode(PlotState.self, from: data)
    }

    func savePlot(_ state: PlotState, index: Int) {
        guard let context, let data = try? JSONEncoder().encode(state) else { return }
        let descriptor = FetchDescriptor<PlotRecord>(predicate: #Predicate { $0.plotIndex == index })
        let rows = (try? context.fetch(descriptor)) ?? []
        if let row = rows.max(by: { $0.savedAt < $1.savedAt }) {
            row.json = data
            row.savedAt = Date()
            for extra in rows where extra !== row { context.delete(extra) }
        } else {
            context.insert(PlotRecord(plotIndex: index, json: data))
        }
        try? context.save()
    }

    // MARK: - The living map, the plots along the bank, the colourways

    /// What a woken pool has grown, or nil if it has never grown anything.
    func poolPetals(levelID: String) -> (count: Int, lastGrownAt: Date, lastCollected: Date?)? {
        guard let context else { return nil }
        let descriptor = FetchDescriptor<PoolPetalsRecord>(predicate: #Predicate { $0.levelID == levelID })
        let rows = (try? context.fetch(descriptor)) ?? []
        guard let row = rows.max(by: { ($0.count, $0.lastGrownAt) < ($1.count, $1.lastGrownAt) }) else { return nil }
        return (row.count, row.lastGrownAt, row.lastCollected)
    }

    /// Every pool's petals at once, by level id, so the map reads the store
    /// once rather than once per pool.
    func allPoolPetals() -> [String: (count: Int, lastGrownAt: Date, lastCollected: Date?)] {
        guard let context else { return [:] }
        var out: [String: (count: Int, lastGrownAt: Date, lastCollected: Date?)] = [:]
        for row in (try? context.fetch(FetchDescriptor<PoolPetalsRecord>())) ?? [] {
            if let had = out[row.levelID], (had.count, had.lastGrownAt) >= (row.count, row.lastGrownAt) { continue }
            out[row.levelID] = (row.count, row.lastGrownAt, row.lastCollected)
        }
        return out
    }

    /// Writes one pool's petals. Does not bump `version`: the map's life is
    /// not laid out again for a petal picked.
    func setPoolPetals(levelID: String, count: Int, lastGrownAt: Date, lastCollected: Date?) {
        guard let context else { return }
        let descriptor = FetchDescriptor<PoolPetalsRecord>(predicate: #Predicate { $0.levelID == levelID })
        let rows = (try? context.fetch(descriptor)) ?? []
        if let row = rows.first {
            row.count = count
            row.lastGrownAt = lastGrownAt
            row.lastCollected = lastCollected
            for extra in rows.dropFirst() { context.delete(extra) }
        } else {
            context.insert(PoolPetalsRecord(levelID: levelID, count: count, lastGrownAt: lastGrownAt, lastCollected: lastCollected))
        }
        try? context.save()
    }

    /// The plots the player may dig: 0 always, and every deed bought.
    func ownedPlots() -> Set<Int> {
        var out: Set<Int> = [0]
        guard let context else { return out }
        for row in (try? context.fetch(FetchDescriptor<PlotDeedRecord>())) ?? [] { out.insert(row.plotIndex) }
        return out
    }

    func addPlotDeed(index: Int) {
        guard let context, index > 0, !ownedPlots().contains(index) else { return }
        context.insert(PlotDeedRecord(plotIndex: index))
        try? context.save()
        version += 1
    }

    /// Item id to tint name, the latest bought per item.
    func colourways() -> [String: String] {
        guard let context else { return [:] }
        var out: [String: (tint: String, at: Date)] = [:]
        for row in (try? context.fetch(FetchDescriptor<ColourwayRecord>())) ?? [] {
            if let had = out[row.itemID], had.at > row.boughtAt { continue }
            out[row.itemID] = (row.tint, row.boughtAt)
        }
        return out.mapValues(\.tint)
    }

    func setColourway(item: String, tint: String) {
        guard let context else { return }
        let descriptor = FetchDescriptor<ColourwayRecord>(predicate: #Predicate { $0.itemID == item })
        let rows = (try? context.fetch(descriptor)) ?? []
        if let row = rows.first {
            row.tint = tint
            row.boughtAt = Date()
            for extra in rows.dropFirst() { context.delete(extra) }
        } else {
            context.insert(ColourwayRecord(itemID: item, tint: tint))
        }
        try? context.save()
        version += 1
    }
}

/// The two switches the settings screen offers, plus nothing else.
final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var soundOn: Bool {
        didSet { UserDefaults.standard.set(soundOn, forKey: "settings.sound") }
    }
    @Published var hapticsOn: Bool {
        didSet { UserDefaults.standard.set(hapticsOn, forKey: "settings.haptics") }
    }

    private init() {
        let d = UserDefaults.standard
        soundOn = d.object(forKey: "settings.sound") as? Bool ?? true
        hapticsOn = d.object(forKey: "settings.haptics") as? Bool ?? true
    }
}


/// What this binary was actually signed with. Development and ad-hoc builds
/// carry `embedded.mobileprovision`, whose Entitlements dictionary is the
/// truth. App Store builds carry no profile, and are signed from the Release
/// entitlements file, which has iCloud in it.
enum Entitlements {
    static let hasCloudKit: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1) else {
            return true
        }
        return text.contains("com.apple.developer.icloud-container-identifiers")
        #endif
    }()
}
