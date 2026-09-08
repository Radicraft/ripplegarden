import UIKit

/// Launch with `-demo` and the level plays itself: every beat it finds a
/// piece of debris and taps the water on the far side of it, so it drifts to
/// the bank. Lets the whole loop, clearing, reveal, bloom and completion, be
/// checked in the Simulator, where there is no finger to tap with.
@MainActor
enum DemoScript {

    private static var timer: Timer?
    private static var syntheticID = 9000

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-demo")
    }

    static func startIfRequested(controller: GameController) {
        guard isEnabled, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.15, repeats: true) { _ in
            Task { @MainActor in beat(controller: controller) }
        }
    }

    private static func beat(controller: GameController) {
        guard controller.phase == .playing else { return }
        let size = controller.scene.size
        guard size.width > 0 else { return }

        // The piece nearest a bank goes first, so the pond clears from the
        // outside in and the reveal reads well on a capture.
        guard let target = controller.debris.filter({ !$0.cleared }).min(by: {
            edgeDistance($0.position, size) < edgeDistance($1.position, size)
        }) else { return }

        let p = target.position
        let toLeft = p.x, toRight = size.width - p.x
        let toTop = p.y, toBottom = size.height - p.y
        let m = min(toLeft, toRight, toTop, toBottom)
        var away = CGVector(dx: 0, dy: 0)
        if m == toLeft { away.dx = 1 } else if m == toRight { away.dx = -1 }
        else if m == toTop { away.dy = 1 } else { away.dy = -1 }

        let tapAt = CGPoint(x: p.x + away.dx * 34, y: p.y + away.dy * 34)
        syntheticID += 1
        let id = syntheticID
        controller.touchBegan(id: id, at: tapAt, in: size, weight: 0.4)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            controller.touchEnded(id: id, at: tapAt, in: size)
        }
    }

    private static func edgeDistance(_ p: CGPoint, _ size: CGSize) -> CGFloat {
        min(p.x, size.width - p.x, p.y, size.height - p.y)
    }
}
