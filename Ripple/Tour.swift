import Foundation

/// Launch with `-tour` and the app walks itself: the garden path, open the
/// first stone, play it (the demo does the tapping), admire the card, back to
/// the path, on to the next stone. For recording what a session looks like.
@MainActor
final class Tour {

    static let shared = Tour()
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-tour") }

    var open: ((LevelSpec) -> Void)?
    var exit: (() -> Void)?
    var next: (() -> Void)?
    var phase: (() -> GameController.Phase)?
    private var running = false

    func start() {
        guard Tour.isEnabled, !running else { return }
        running = true
        Task { @MainActor in
            let levels = Library.levels(in: Library.winter)
            try? await Task.sleep(for: .seconds(4.5))
            guard let first = levels.first else { return }
            DemoScript.reset()
            open?(first)
            await waitForCard()
            try? await Task.sleep(for: .seconds(3.5))
            exit?()
            try? await Task.sleep(for: .seconds(4.0))
            DemoScript.reset()
            guard levels.count > 1 else { return }
            open?(levels[1])
            await waitForCard()
            try? await Task.sleep(for: .seconds(3.0))
            DemoScript.reset()
            next?()
            try? await Task.sleep(for: .seconds(12))
        }
    }

    private func waitForCard() async {
        for _ in 0..<600 {
            try? await Task.sleep(for: .seconds(0.25))
            if phase?() == .complete { return }
        }
    }
}
