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
        .onAppear {
            hub.onPlay = onPlay
            if ProcessInfo.processInfo.arguments.contains("-showSettings") { showSettings = true }
        }
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
                Spacer()
                StoneIconButton(symbol: "leaf") { showSettings = true }
            }
            .padding(.horizontal, 24)
            .padding(.top, 58)
            Spacer()
        }
    }
}
