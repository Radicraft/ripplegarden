import SwiftUI

/// The garden path, or a level. One controller lives for the whole app and is
/// re-pointed at whichever level is opened.
struct RootView: View {

    enum Screen: Equatable {
        case garden
        case level(String)
    }

    @StateObject private var game: GameController
    @StateObject private var hub = HubController()
    @State private var screen: Screen

    init() {
        let args = ProcessInfo.processInfo.arguments
        let style: WaterStyle = args.contains("-photo") ? .photographic : .woodblock
        var start = Library.springOne
        var first: Screen = .garden
        if let i = args.firstIndex(of: "-level"), i + 1 < args.count, let l = Library.level(id: args[i + 1]) {
            start = l
            first = .level(l.id)
        } else if args.contains("-demo"), !args.contains("-tour") {
            first = .level(start.id)
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
                .transition(.opacity)
            case .level:
                LevelView(controller: game) {
                    game.leave()
                    withAnimation(.easeInOut(duration: 0.6)) { screen = .garden }
                }
                .transition(.opacity)
            }
        }
        .modelContainer(ProgressStore.shared.container)
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
