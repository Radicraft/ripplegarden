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
        let schema = Schema([LevelRecord.self, GardenRecord.self])
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
            try? context.save()
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
