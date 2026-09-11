import SwiftUI

/// The way from the map to the plot. RootView sets it on HubView; the hub's
/// sideways swipe calls it once that is wired (`@Environment(\.openPlot)`).
struct OpenPlotKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var openPlot: () -> Void {
        get { self[OpenPlotKey.self] }
        set { self[OpenPlotKey.self] = newValue }
    }
}

/// The player's own pond: the water, a chevron back to the map, the petal
/// purse in the top corner, the settings gear where the map keeps it, and
/// one line on the first visit. Nothing else is written over it.
struct PlotView: View {

    @ObservedObject var plot: PlotController
    @ObservedObject private var inventory = Inventory.shared
    let onExit: () -> Void

    var body: some View {
        ZStack {
            WaterView(input: plot, worldScale: PlotController.worldScale, gridLongSide: PlotController.gridLongSide) { renderer in
                plot.attach(renderer: renderer)
            }
            .ignoresSafeArea()

            words
            hud
            gear
            menu
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear { plot.onExit = onExit }
    }

    /// The first visit's one line, low in the water like a level's.
    @ViewBuilder private var words: some View {
        ZStack {
            if let w = plot.words, plot.presented == nil {
                PondVeil(words: w)
                    .transition(.opacity)
                    .id(w)
            }
        }
        .animation(Motion.words, value: plot.words)
        .allowsHitTesting(false)
    }

    /// Back at the top left; the petals at the top right, in the serif.
    private var hud: some View {
        VStack {
            HStack(alignment: .center) {
                GlyphButton(symbol: "chevron.left") { _ in
                    plot.leave()
                    onExit()
                }
                Spacer()
                HStack(spacing: 6) {
                    Text("\(inventory.petals)")
                        .font(Ink.serif(Size.prose))
                    Text(inventory.petals == 1 ? "petal" : "petals")
                        .font(Ink.serif(Size.body))
                        .opacity(Ink.dim)
                }
                .foregroundStyle(Ink.paper)
                .shadow(color: Ink.veil.opacity(0.65), radius: 5, y: 1)
                .padding(.trailing, 6)
            }
            .padding(.horizontal, 18)
            .opacity(plot.presented == nil ? 1 : 0)
            .animation(Motion.leave, value: plot.presented)
            Spacer()
        }
    }

    private var gear: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                GlyphButton(symbol: "gearshape") { plot.openSettings(from: $0) }
            }
            .padding(.trailing, 12)
            .padding(.bottom, 22)
        }
        .opacity(plot.presented == nil ? 1 : 0)
        .animation(Motion.leave, value: plot.presented)
    }

    @ViewBuilder private var menu: some View {
        if let screen = plot.presented {
            MenuLayer(screen: screen,
                      sound: plot.sound,
                      haptics: plot.haptics,
                      onClose: { plot.closeMenu() })
                .transition(.opacity)
        }
    }
}
