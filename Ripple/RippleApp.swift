import SwiftUI

@main
struct RippleApp: App {

    @StateObject private var game = GameController(level: Library.springOne)

    var body: some Scene {
        WindowGroup {
            LevelView(controller: game)
                .modelContainer(ProgressStore.shared.container)
                .onAppear { DemoScript.startIfRequested(controller: game) }
        }
    }
}
