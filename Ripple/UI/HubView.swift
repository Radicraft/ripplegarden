import SwiftUI

/// The stream, with its labels floating on the water. Over the glass there is
/// the petal purse at the top left, one system gear in a 44pt target, and a
/// menu when the player asks for one.
struct HubView: View {

    @ObservedObject var hub: HubController
    @ObservedObject private var inventory = Inventory.shared
    let onPlay: (LevelSpec) -> Void
    @Environment(\.openPlot) private var openPlot

    var body: some View {
        ZStack {
            WaterView(input: hub, worldScale: HubController.worldScale, gridLongSide: HubController.gridLongSide) { renderer in
                hub.attach(renderer: renderer)
            }
            .ignoresSafeArea()

            purse
            gear
            menu
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear {
            hub.onPlay = onPlay
            // A finger drawn sideways across the stream goes to the player's pond.
            hub.onSwipeToPlot = openPlot
        }
    }

    /// The petals picked, in the serif, where the plot keeps its own.
    private var purse: some View {
        VStack {
            HStack {
                PetalPurse(petals: inventory.petals)
                    .padding(.leading, 6)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .opacity(hub.presented == nil ? 1 : 0)
            .animation(Motion.leave, value: hub.presented)
            Spacer()
        }
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
