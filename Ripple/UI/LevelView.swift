import SwiftUI

/// A level is the pond, two glyphs in 44pt targets, and whatever the game has
/// to say. What is read sits low in the water under a veil; a menu is one
/// scrim over the lot.
struct LevelView: View {

    @ObservedObject var controller: GameController
    @ObservedObject private var tutorial = Tutorial.shared
    let onExit: () -> Void

    var body: some View {
        ZStack {
            WaterView(controller: controller)
                .ignoresSafeArea()

            words
            hud
            menu
            walk
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear { controller.onExit = onExit }
    }

    /// The line that opens the level, what is left, a hint. The first
    /// walk's line stands in for them all while it has one.
    @ViewBuilder private var words: some View {
        ZStack {
            if let w = controller.words, controller.presented == nil, tutorial.lines[.level] == nil {
                PondVeil(words: w)
                    .transition(.opacity)
                    .id(w)
            }
        }
        .animation(Motion.scrim, value: controller.words)
        .allowsHitTesting(false)
    }

    /// The first walk: its line in the same veil, over the completion too,
    /// and its ring on the completion's word for the player's own pond.
    @ViewBuilder private var walk: some View {
        ZStack {
            if let w = tutorial.lines[.level], controller.presented == nil || controller.presented == .complete {
                PondVeil(words: w)
                    .transition(.opacity)
                    .id(w)
            }
            if controller.presented == .complete {
                // The completion lays its words out in the safe area, so
                // this reader keeps to it too: "Your pond" sits a little
                // right of centre, between the longer word and the shorter.
                GeometryReader { g in
                    TutorialPulse(on: tutorial.spot(for: .level) == .yourPond)
                        .position(x: g.size.width / 2 + 10, y: g.size.height * 0.744)
                }
            }
        }
        .animation(Motion.scrim, value: tutorial.lines)
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
