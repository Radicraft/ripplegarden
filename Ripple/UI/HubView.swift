import SwiftUI

/// The stream, with its labels floating over the water.
struct HubView: View {

    @ObservedObject var hub: HubController
    let onPlay: (LevelSpec) -> Void
    @ObservedObject private var store = Store.shared
    @State private var showSettings = false

    var body: some View {
        ZStack {
            WaterView(input: hub, worldScale: HubController.worldScale, gridLongSide: HubController.gridLongSide) { renderer in
                hub.attach(renderer: renderer)
            }
            .ignoresSafeArea()

            GeometryReader { geo in
                ZStack {
                    ForEach(hub.marks) { mark in
                        if mark.screen.y > -80, mark.screen.y < geo.size.height + 80 {
                            label(mark)
                                .position(x: mark.screen.x, y: mark.screen.y + mark.radius * 0.85)
                            if mark.first {
                                Text(mark.season.name)
                                    .font(Ink.title(26))
                                    .foregroundStyle(Ink.paper)
                                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                                    .position(x: geo.size.width / 2, y: mark.screen.y - mark.radius * 1.55)
                            }
                        }
                    }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            header
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .overlay {
            PondOverlay(isPresented: $showSettings) {
                SettingsCard { showSettings = false }
            }
        }
        .onAppear { hub.onPlay = onPlay }
    }

    private func label(_ mark: HubController.Mark) -> some View {
        PaperChip(opacity: mark.unlocked ? 0.95 : 0.6) {
            Text(mark.level.title.split(separator: ",").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? mark.level.title)
                .font(Ink.label(13))
                .foregroundStyle(mark.unlocked ? Ink.ink : Ink.ink.opacity(0.45))
        }
        .overlay(alignment: .topTrailing) {
            if mark.complete {
                Circle().fill(Ink.blossom).frame(width: 8, height: 8).offset(x: 2, y: -2)
            }
        }
    }

    private var header: some View {
        VStack {
            HStack(alignment: .firstTextBaseline) {
                // The title lives at the source and drifts off as you go down.
                if let top = hub.marks.first(where: \.first) {
                    Text("Ripple Garden")
                        .font(Ink.title(30))
                        .foregroundStyle(Ink.paper)
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                        .opacity(Double(max(0, min(1, (top.screen.y - 120) / 160))))
                }
                Spacer()
                StoneIconButton(symbol: "leaf") { showSettings = true }
            }
            .padding(.horizontal, 24)
            .padding(.top, 58)
            Spacer()
        }
    }
}
