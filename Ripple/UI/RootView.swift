import SwiftData
import SwiftUI

/// The garden path, a level, or the player's own plots. One controller
/// lives for the whole app and is re-pointed at whichever level is opened;
/// the plots keep their own, one per plot, through the pager.
struct RootView: View {

    enum Screen: Equatable {
        case garden
        case level(String)
        case plot
    }

    @StateObject private var game: GameController
    @StateObject private var hub = HubController()
    @StateObject private var plots = PlotPager()
    @State private var screen: Screen

    init() {
        let args = ProcessInfo.processInfo.arguments
        let style: WaterStyle = args.contains("-photo") ? .photographic : .woodblock
        var start = Library.springOne
        var first: Screen = .garden
        if let i = args.firstIndex(of: "-level"), i + 1 < args.count, let l = Library.level(id: args[i + 1]) {
            start = l
            first = .level(l.id)
        } else if args.contains("-demo"), !args.contains("-tour"), !args.contains("-tutorial") {
            // `-tutorial -demo` starts on the map as a first launch does,
            // and the demo takes the level up once a pool is opened.
            first = .level(start.id)
        } else if args.contains("-plot") || args.contains("-plotDug") || args.contains("-plotFull") {
            first = .plot
        }
        _game = StateObject(wrappedValue: GameController(level: start, style: style))
        _screen = State(initialValue: first)
    }

    var body: some View {
        ZStack {
            switch screen {
            case .garden:
                HubView(hub: hub) { level in
                    game.prepare(level: level)
                    withAnimation(.easeInOut(duration: 0.6)) { screen = .level(level.id) }
                }
                // What the map calls to page sideways to the plot, once the
                // hub's swipe is wired to it (`\.openPlot`).
                .environment(\.openPlot, { withAnimation(.easeInOut(duration: 0.6)) { screen = .plot } })
                .transition(.opacity)
            case .level:
                LevelView(controller: game) {
                    game.leave()
                    withAnimation(.easeInOut(duration: 0.6)) { screen = .garden }
                }
                .onAppear {
                    // The completion's third word: straight to the player's pond.
                    game.onYourPond = {
                        game.leave()
                        withAnimation(.easeInOut(duration: 0.6)) { screen = .plot }
                    }
                }
                .transition(.opacity)
            case .plot:
                // `-plot`, `-plotDug` and `-plotFull` land here on plot 0.
                PlotView(pager: plots) {
                    withAnimation(.easeInOut(duration: 0.55)) { screen = .garden }
                }
                // The plot lies to the right of the stream: it slides in from
                // there and goes back the same way, over the map.
                .zIndex(2)
                .transition(.move(edge: .trailing))
            }
        }
        .progressContainer()
        .onAppear {
            DemoScript.startIfRequested(controller: game)
            Tour.shared.open = { level in
                game.prepare(level: level)
                withAnimation(.easeInOut(duration: 0.6)) { screen = .level(level.id) }
            }
            Tour.shared.exit = { withAnimation(.easeInOut(duration: 0.6)) { screen = .garden } }
            Tour.shared.next = { game.next() }
            Tour.shared.phase = { game.phase }
            Tour.shared.start()
        }
    }
}

private extension View {
    /// The store is only nil if no container could be made at all, in which
    /// case the game runs without one rather than refusing to launch.
    @ViewBuilder func progressContainer() -> some View {
        if let container = ProgressStore.shared.container {
            self.modelContainer(container)
        } else {
            self
        }
    }
}
