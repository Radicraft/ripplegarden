import SwiftUI

/// A level is the pond, two glyphs in 44pt targets, and whatever the game has
/// to say. What is read sits low in the water under a veil; a menu is one
/// scrim over the lot.
struct LevelView: View {

    @ObservedObject var controller: GameController
    let onExit: () -> Void

    var body: some View {
        ZStack {
            WaterView(controller: controller)
                .ignoresSafeArea()

            words
            hud
            menu
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear { controller.onExit = onExit }
    }

    /// The line that opens the level, what is left, a hint.
    @ViewBuilder private var words: some View {
        ZStack {
            if let w = controller.words, controller.presented == nil {
                PondVeil(words: w)
                    .transition(.opacity)
                    .id(w)
            }
        }
        .animation(Motion.scrim, value: controller.words)
        .allowsHitTesting(false)
    }

    /// Back at the top left, the settings gear opposite it. The bottom of the
    /// screen belongs to the words, so the gear does not sit there here.
    private var hud: some View {
        VStack {
            HStack {
                GlyphButton(symbol: "chevron.left") { _ in onExit() }
                Spacer()
                GlyphButton(symbol: "gearshape") { controller.openSettings(from: $0) }
            }
            .padding(.horizontal, 18)
            .opacity(controller.phase == .playing && controller.presented == nil ? 1 : 0)
            .animation(Motion.leave, value: controller.presented)
            Spacer()
        }
    }

    @ViewBuilder private var menu: some View {
        if let screen = controller.presented {
            MenuLayer(screen: screen,
                      sound: controller.sound,
                      haptics: controller.haptics,
                      hasNext: controller.hasNext,
                      onClose: { controller.closeMenu() },
                      onGarden: onExit,
                      onNext: { controller.next() },
                      onYourPond: { controller.onYourPond?() })
                .transition(.opacity)
        }
    }
}
