import SwiftUI

/// A level is the water and two stones in the corners. Everything else the
/// game has to say it says in the pond: the words are ink under the surface
/// and the buttons are stones in the water.
struct LevelView: View {

    @ObservedObject var controller: GameController
    let onExit: () -> Void

    var body: some View {
        ZStack {
            WaterView(controller: controller)
                .ignoresSafeArea()

            hud
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear { controller.onExit = onExit }
    }

    private var hud: some View {
        VStack {
            HStack(alignment: .top) {
                StoneIconButton(symbol: "chevron.left", action: onExit)
                    .padding(.leading, 18)
                    .padding(.top, 8)
                    .opacity(controller.phase == .playing ? 0.9 : 0)
                Spacer()
                StoneIconButton(symbol: "leaf") { controller.openSettings() }
                    .padding(.trailing, 18)
                    .padding(.top, 8)
                    .opacity(controller.phase == .playing ? 0.9 : 0)
            }
            Spacer()
        }
    }
}
