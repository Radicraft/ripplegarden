import SwiftUI

/// The stream, with its labels floating on the water. Over the glass there is
/// one system gear in a 44pt target, and a menu when the player asks for one.
struct HubView: View {

    @ObservedObject var hub: HubController
    let onPlay: (LevelSpec) -> Void

    var body: some View {
        ZStack {
            WaterView(input: hub, worldScale: HubController.worldScale, gridLongSide: HubController.gridLongSide) { renderer in
                hub.attach(renderer: renderer)
            }
            .ignoresSafeArea()

            words
            gear
            menu
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear { hub.onPlay = onPlay }
    }

    /// The one line the map ever shows: how to lay the view over.
    @ViewBuilder private var words: some View {
        ZStack {
            if let w = hub.words, hub.presented == nil {
                PondVeil(words: w)
                    .transition(.opacity)
                    .id(w)
            }
        }
        .animation(Motion.scrim, value: hub.words)
        .allowsHitTesting(false)
    }

    private var gear: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                GlyphButton(symbol: "gearshape") { hub.openSettings(from: $0) }
            }
            .padding(.trailing, 12)
            .padding(.bottom, 22)
        }
        .opacity(hub.presented == nil ? 1 : 0)
        .animation(Motion.leave, value: hub.presented)
    }

    @ViewBuilder private var menu: some View {
        if let screen = hub.presented {
            MenuLayer(screen: screen,
                      sound: hub.sound,
                      haptics: hub.haptics,
                      onClose: { hub.closeMenu() })
                .transition(.opacity)
        }
    }
}
