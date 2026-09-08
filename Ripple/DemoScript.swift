import UIKit

/// Launch with `-demo` and the level plays itself: it pushes petals off the
/// tile with taps placed between petal and centre, holds a finger beside the
/// driftwood to shove it clear, and keeps tapping around the roundel until
/// the silt is gone. Lets the whole loop be checked and recorded in the
/// Simulator, where there is no finger to tap with.
@MainActor
enum DemoScript {

    private static var timer: Timer?
    private static var syntheticID = 9000
    private static var holding = false
    private static var beats = 0
    private static var attempts: [Int: Int] = [:]

    static var isEnabled: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-demo") || args.contains("-tour")
    }

    /// A fresh level: start the beat count over.
    static func reset() {
        beats = 0
        attempts = [:]
        holding = false
    }

    static func startIfRequested(controller: GameController) {
        guard isEnabled, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in beat(controller: controller) }
        }
    }

    private static func beat(controller: GameController) {
        guard controller.phase == .playing, !holding else { return }
        guard let size = controller.worldSize, size.width > 0 else { return }
        beats += 1
        if beats < 3 { return }   // let the title breathe

        let c = CGPoint(x: controller.level.mosaicCentre.x * size.width, y: controller.level.mosaicCentre.y * size.height)
        let r = controller.level.mosaicRadius * size.height
        let live = controller.debris.filter { !$0.cleared }

        // Ice first: tap a spot twice to break through, then work outward
        // from the holes with taps in the open water beside the edge.
        if let field = controller.iceField, field.fraction > 0.06 {
            let centre = CGPoint(x: size.width / 2, y: size.height * 0.48)
            if field.ice(at: centre) > 0.5 {
                tap(controller, at: centre, size: size)     // strike, then break through
            } else if let edge = field.nearestIce(to: centre, range: 2000) {
                // Alternate: a tap on the fractured ice just inside the edge,
                // and a tap in the open water beside it to send a wave at it.
                let dx = centre.x - edge.x, dy = centre.y - edge.y
                let len = max(1, hypot(dx, dy))
                let onIce = CGPoint(x: edge.x - dx / len * 14, y: edge.y - dy / len * 14)
                let open = CGPoint(x: edge.x + dx / len * 60, y: edge.y + dy / len * 60)
                tap(controller, at: beats % 2 == 0 ? onIce : open, size: size)
            }
            return
        }
        // A tidying level: push each piece toward its nearest bank.
        if controller.level.mosaicRadius <= 0 {
            guard let piece = live.min(by: { edgeDistance($0.position, size) < edgeDistance($1.position, size) }) else { return }
            let p = piece.position
            let toLeft = p.x, toRight = size.width - p.x, toTop = p.y, toBottom = size.height - p.y
            let m = min(toLeft, toRight, toTop, toBottom)
            var away = CGVector(dx: 0, dy: 0)
            if m == toLeft { away.dx = 1 } else if m == toRight { away.dx = -1 } else if m == toTop { away.dy = 1 } else { away.dy = -1 }
            if piece.cls == .heavy, beats % 3 == 0 {
                hold(controller, at: CGPoint(x: p.x + away.dx * 42, y: p.y + away.dy * 42), size: size, for: 1.6)
            } else {
                tap(controller, at: CGPoint(x: p.x + away.dx * 32, y: p.y + away.dy * 32), size: size)
            }
            return
        }
        let onTile = live.filter { hypot($0.position.x - c.x, $0.position.y - c.y) < r + $0.radius * 0.5 }

        // Every fifth beat, if the log still lies on the tile, a held press on
        // the centre side of it.
        if beats % 5 == 0, let log = onTile.first(where: { $0.cls == .heavy }) {
            let dx = log.position.x - c.x, dy = log.position.y - c.y
            let len = max(1, hypot(dx, dy))
            let at = CGPoint(x: log.position.x - dx / len * 42, y: log.position.y - dy / len * 42)
            NSLog("[demo] hold at (%.0f,%.0f) for log at (%.0f,%.0f)", at.x, at.y, log.position.x, log.position.y)
            hold(controller, at: at, size: size, for: 1.6)
            return
        }
        // Petals: tap between the petal and the centre so the ring shoves it
        // outward. One that keeps coming back (pinned on the rock) gets a tap
        // from the far side instead every third try.
        if let petal = onTile.filter({ $0.cls == .light }).min(by: { $0.id < $1.id }) {
            attempts[petal.id, default: 0] += 1
            let fromFarSide = attempts[petal.id, default: 0] % 3 == 0
            let dx = petal.position.x - c.x, dy = petal.position.y - c.y
            let len = max(1, hypot(dx, dy))
            let sgn: CGFloat = fromFarSide ? 1 : -1
            let tapAt = CGPoint(x: petal.position.x + sgn * dx / len * 30, y: petal.position.y + sgn * dy / len * 30)
            tap(controller, at: tapAt, size: size)
            return
        }
        // Then wash: taps around the ring, biased to where silt tends to linger.
        let angle = CGFloat(beats) * 2.4
        let at = CGPoint(x: c.x + cos(angle) * r * 0.7, y: c.y + sin(angle) * r * 0.7)
        tap(controller, at: at, size: size)
    }

    /// Points here are world points; the controller wants screen points.
    private static func tap(_ controller: GameController, at world: CGPoint, size: CGSize) {
        syntheticID += 1
        let id = syntheticID
        let p = controller.screenPoint(world)
        let screen = screenSizeOf(controller) ?? size
        controller.touchBegan(id: id, at: p, in: screen, weight: 0.4)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            controller.touchEnded(id: id, at: p, in: screen)
        }
    }

    private static func hold(_ controller: GameController, at world: CGPoint, size: CGSize, for seconds: Double) {
        syntheticID += 1
        let id = syntheticID
        holding = true
        let p = controller.screenPoint(world)
        let screen = screenSizeOf(controller) ?? size
        controller.touchBegan(id: id, at: p, in: screen, weight: 0.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            controller.touchEnded(id: id, at: p, in: screen)
            holding = false
        }
    }

    private static func screenSizeOf(_ controller: GameController) -> CGSize? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.bounds.size
    }

    private static func edgeDistance(_ p: CGPoint, _ size: CGSize) -> CGFloat {
        min(p.x, size.width - p.x, p.y, size.height - p.y)
    }

    private static func sizeOf(_ controller: GameController) -> CGSize? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.bounds.size
    }
}
