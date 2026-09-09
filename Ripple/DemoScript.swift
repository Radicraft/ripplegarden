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
    private static var lastIceTap: CGPoint?
    private static var lastFraction: Float = 1
    private static var stalls = 0
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
        lastIceTap = nil
        lastFraction = 1
        stalls = 0
    }

    /// `-taps "0.5,0.72@4;0.3,0.4@8"`: scripted taps at world fractions and
    /// seconds after launch, for checking a designed level without a finger.
    static func scheduleScriptedTaps(controller: GameController) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-taps"), i + 1 < args.count else { return }
        for item in args[i + 1].split(separator: ";") {
            let parts = item.split(separator: "@")
            guard parts.count == 2, let t = Double(parts[1]) else { continue }
            let xy = parts[0].split(separator: ",").compactMap { Double($0) }
            guard xy.count == 2 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                guard let size = controller.worldSize, size.width > 0 else { return }
                let p = CGPoint(x: size.width * xy[0], y: size.height * xy[1])
                NSLog("[taps] tap at (%.0f,%.0f)", p.x, p.y)
                tap(controller, at: p, size: size)
            }
        }
    }

    static func startIfRequested(controller: GameController) {
        scheduleScriptedTaps(controller: controller)
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
            // Finish what was started: a struck spot still on ice gets its second tap.
            if let last = lastIceTap, field.ice(at: last) > 0.5, field.strikeIndex(containing: last) != nil {
                lastIceTap = nil
                tap(controller, at: last, size: size)
                return
            }
            // Where to strike next: the middle of the pond while it is still
            // frozen, then somewhere well inside what is left of the sheet, so
            // the tap gets a whole ring of shards. When nothing is left but a
            // fringe along the banks, any of it will do: a tap there bites a
            // piece off at once.
            let centre = CGPoint(x: size.width / 2, y: size.height * 0.48)
            var deep: CGPoint?
            var anywhere: CGPoint?
            if field.ice(at: centre) > 0.5, !field.isEdge(at: centre, within: 46) {
                deep = centre
            } else {
                for _ in 0..<60 {
                    let p = CGPoint(x: CGFloat.random(in: 0...size.width), y: CGFloat.random(in: 0...size.height))
                    guard field.ice(at: p) > 0.5 else { continue }
                    if anywhere == nil { anywhere = p }
                    if !field.isEdge(at: p, within: 46) { deep = p; break }
                }
            }
            guard let target = deep ?? anywhere else { return }
            // Every seventh beat the finger slides across the sheet instead:
            // nothing breaks, the frost is wiped where it went.
            if beats % 7 == 0, let start = deep {
                let a = CGFloat.random(in: 0...(2 * .pi))
                let end = CGPoint(x: start.x + cos(a) * 170, y: start.y + sin(a) * 170)
                slide(controller, from: start, to: end, size: size)
                return
            }
            lastIceTap = target
            tap(controller, at: target, size: size)
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

    /// A finger drawn across the world from one point to another over 0.7s.
    private static func slide(_ controller: GameController, from: CGPoint, to: CGPoint, size: CGSize) {
        syntheticID += 1
        let id = syntheticID
        holding = true
        let screen = screenSizeOf(controller) ?? size
        controller.touchBegan(id: id, at: controller.screenPoint(from), in: screen, weight: 0.4)
        let steps = 18
        for k in 1...steps {
            let t = CGFloat(k) / CGFloat(steps)
            let w = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7 * Double(t)) {
                controller.touchMoved(id: id, to: controller.screenPoint(w), in: screen)
                if k == steps {
                    controller.touchEnded(id: id, at: controller.screenPoint(w), in: screen)
                    holding = false
                }
            }
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
