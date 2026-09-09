import SwiftUI

/// The stream, with its labels floating on the water. The only thing over the
/// glass is the leaf: the settings and the seasons pass happen in the water.
struct HubView: View {

    @ObservedObject var hub: HubController
    let onPlay: (LevelSpec) -> Void

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
        .onAppear { hub.onPlay = onPlay }
    }

    private var header: some View {
        VStack {
            HStack(alignment: .firstTextBaseline) {
                Spacer()
                StoneIconButton(symbol: "leaf") { hub.openSettings() }
            }
            .padding(.horizontal, 24)
            .padding(.top, 58)
            Spacer()
        }
    }
}
