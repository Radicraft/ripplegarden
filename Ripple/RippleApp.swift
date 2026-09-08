import SwiftUI

@main
struct RippleApp: App {

    /// `-woodblock` draws the water as a print and uses the ukiyo-e art set.
    @StateObject private var game = GameController(
        level: Library.springOne,
        style: ProcessInfo.processInfo.arguments.contains("-woodblock") ? .woodblock : .photographic)

    var body: some Scene {
        WindowGroup {
            LevelView(controller: game)
                .modelContainer(ProgressStore.shared.container)
                .onAppear { DemoScript.startIfRequested(controller: game) }
        }
    }
}
