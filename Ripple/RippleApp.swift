import SwiftUI

@main
struct RippleApp: App {

    /// Woodblock is the game (owner's pick, 2026-09-08). `-photo` keeps the
    /// photographic water around for comparison.
    @StateObject private var game = GameController(
        level: Library.springOne,
        style: ProcessInfo.processInfo.arguments.contains("-photo") ? .photographic : .woodblock)

    var body: some Scene {
        WindowGroup {
            LevelView(controller: game)
                .modelContainer(ProgressStore.shared.container)
                .onAppear { DemoScript.startIfRequested(controller: game) }
        }
    }
}
