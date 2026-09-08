import SwiftUI

/// The hub: a path through the year's garden. Each season is a stretch of
/// path with six stones on it; a finished stone shows its roundel. Seasons
/// further down the path sleep until the one before is done.
struct GardenPathView: View {

    let onPlay: (LevelSpec) -> Void
    @ObservedObject private var progress = ProgressStore.shared
    @ObservedObject private var store = Store.shared
    @State private var showSettings = false

    var body: some View {
        ZStack {
            LinearGradient(colors: Library.seasons.map { $0.pathColour }, startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    header
                    ForEach(Library.seasons) { season in
                        SeasonStretch(season: season, unlocked: progress.isUnlocked(season: season), onPlay: onPlay)
                    }
                    comingSoon
                        .padding(.top, 30)
                        .padding(.bottom, 60)
                }
            }
        }
        .statusBarHidden(true)
        .sheet(isPresented: $showSettings) { SettingsSheet() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Ripple Garden")
                .font(.system(size: 30, weight: .regular, design: .serif))
                .foregroundStyle(Ink.paper)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "leaf")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Ink.ink)
                    .frame(width: 34, height: 34)
                    .background(Ink.paper.opacity(0.85), in: Circle())
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 58)
        .padding(.bottom, 8)
    }

    private var comingSoon: some View {
        VStack(spacing: 10) {
            Text("Seasons to come")
                .font(.system(size: 20, design: .serif))
                .foregroundStyle(Ink.ink)
            Text("New seasons, new levels and new looks for the garden arrive with the Seasons pass. The first year is yours to keep.")
                .font(.system(size: 14, design: .serif))
                .foregroundStyle(Ink.ink.opacity(0.75))
                .multilineTextAlignment(.center)
            if store.isSubscribed {
                Text("You have the Seasons pass. Thank you.")
                    .font(.system(size: 14, weight: .medium, design: .serif))
                    .foregroundStyle(Ink.ink)
            } else if store.products.isEmpty {
                Text("Coming soon")
                    .font(.system(size: 14, weight: .medium, design: .serif))
                    .foregroundStyle(Ink.ink.opacity(0.6))
            } else {
                HStack(spacing: 12) {
                    ForEach(store.products, id: \.id) { product in
                        Button {
                            Task { await store.purchase(product) }
                        } label: {
                            VStack(spacing: 2) {
                                Text(product.id == Store.annualID ? "Yearly" : "Monthly")
                                    .font(.system(size: 14, weight: .medium, design: .serif))
                                Text(product.displayPrice)
                                    .font(.system(size: 13, design: .serif))
                            }
                            .foregroundStyle(Ink.paper)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(Ink.ink, in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(22)
        .background(Ink.paper.opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 28)
    }
}

/// One season's stretch of path.
private struct SeasonStretch: View {
    let season: Season
    let unlocked: Bool
    let onPlay: (LevelSpec) -> Void
    @ObservedObject private var progress = ProgressStore.shared

    private let rowHeight: CGFloat = 112

    var body: some View {
        let levels = Library.levels(in: season)
        VStack(alignment: .leading, spacing: 4) {
            Text(season.name)
                .font(.system(size: 24, weight: .regular, design: .serif))
                .foregroundStyle(Ink.paper)
                .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
                .padding(.horizontal, 28)
                .padding(.top, 26)
            Text(unlocked ? season.tagline : "This season sleeps until the one before is done.")
                .font(.system(size: 14, design: .serif))
                .foregroundStyle(Ink.paper.opacity(0.85))
                .padding(.horizontal, 28)
                .padding(.bottom, 8)

            ZStack {
                PathShape(count: levels.count, rowHeight: rowHeight)
                    .stroke(Ink.paper.opacity(0.55), style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [1, 12]))
                VStack(spacing: 0) {
                    ForEach(Array(levels.enumerated()), id: \.element.id) { i, level in
                        let done = progress.isComplete(levelID: level.id)
                        let open = unlocked && (i == 0 || progress.isComplete(levelID: levels[i - 1].id))
                        HStack {
                            if i % 2 == 1 { Spacer() }
                            LevelStone(level: level, season: season, done: done, open: open)
                                .onTapGesture { if open { onPlay(level) } }
                            if i % 2 == 0 { Spacer() }
                        }
                        .padding(.horizontal, 64)
                        .frame(height: rowHeight)
                    }
                }
            }
        }
        .opacity(unlocked ? 1 : 0.45)
    }
}

/// A stepping stone on the path: number, or the roundel once it is done.
private struct LevelStone: View {
    let level: LevelSpec
    let season: Season
    let done: Bool
    let open: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Ink.paper)
                .overlay(Circle().stroke(Ink.ink.opacity(0.5), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 4)
            if done, let image = Art.image(season.woodblock.mosaic) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            } else {
                Text("\(level.index)")
                    .font(.system(size: 24, weight: .regular, design: .serif))
                    .foregroundStyle(Ink.ink.opacity(open ? 1 : 0.35))
            }
        }
        .frame(width: 78, height: 78)
        .opacity(open ? 1 : 0.6)
    }
}

/// A gentle S-curve through the rows of stones.
private struct PathShape: SwiftUI.Shape {
    let count: Int
    let rowHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard count > 0 else { return p }
        let leftX = rect.minX + 64 + 39
        let rightX = rect.maxX - 64 - 39
        func point(_ i: Int) -> CGPoint {
            CGPoint(x: i % 2 == 0 ? leftX : rightX, y: rect.minY + rowHeight * (CGFloat(i) + 0.5))
        }
        p.move(to: point(0))
        for i in 1..<count {
            let a = point(i - 1), b = point(i)
            let mid = (a.y + b.y) / 2
            p.addCurve(to: b, control1: CGPoint(x: a.x, y: mid), control2: CGPoint(x: b.x, y: mid))
        }
        return p
    }
}

/// Loose PNGs from the bundle, for SwiftUI.
enum Art {
    private static var cache: [String: UIImage] = [:]
    static func image(_ name: String) -> UIImage? {
        if let i = cache[name] { return i }
        guard let path = Bundle.main.path(forResource: name, ofType: "png"), let i = UIImage(contentsOfFile: path) else { return nil }
        cache[name] = i
        return i
    }
}

extension Season {
    /// The path's background takes each season's water colour.
    var pathColour: Color {
        let m = woodblock.floor.mid
        return Color(red: Double(m.x) * 1.4, green: Double(m.y) * 1.4, blue: Double(m.z) * 1.4)
    }
}
