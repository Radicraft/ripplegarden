import UIKit

/// Launch with `-demo` and the level plays itself: it breaks the ice, calls
/// the koi with a held finger, flicks a wake for the shoal to follow, taps
/// seeds toward the shallows, sweeps the duckweed, rocks the pond at the
/// lip, plays the chime stones in order, and leaves a still pond alone.
/// Lets the whole loop be checked and recorded in the Simulator, where
/// there is no finger to tap with.
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
    private static var lastPiecePos: [Int: CGPoint] = [:]

    static var isEnabled: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-demo") || args.contains("-tour")
    }

    /// A fresh level: start the beat count over.
    static func reset() {
        beats = 0
        attempts = [:]
        lastPiecePos = [:]
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

    /// `-gestures "flick:0.3,0.5>0.7,0.5@4;stir:0.5,0.5@8;drop:0.5,0.6@12;gust:>@16"`:
    /// one water gesture per item, played without a finger at world fractions
    /// and seconds after launch, so each can be seen in the Simulator.
    ///
    /// `flick:from>to` a stroke over 0.35s, fast enough to lay a wake.
    /// `stir:centre` two turns of a circle over 1.2s (`stir:centre:r` for a
    /// radius as a fraction of the pond's height). `drop:at` two taps 0.2s
    /// apart. `gust:from>to` two parallel flicks; `gust:>` sweeps the middle
    /// of the pond left to right. `slosh:from>to` one slow finger over 1.5s,
    /// shoving a body of water ahead of it. `tilt:` two fingers drawn 120 pt
    /// up the screen over 0.6s, laying the camera over toward the water
    /// (`tilt:-120` stands it up again). `tap:at` and `hold:at` are here too.
    ///
    /// The pond's own life can be called on as well: `leap:` sends a koi up,
    /// `drip:` drops one bead off a branch, `wind:` runs a gust across, and
    /// `dusk:` (or `dusk:0.2` for the morning) moves the day on.
    static func scheduleScriptedGestures(controller: GameController) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-gestures"), i + 1 < args.count else { return }
        for item in args[i + 1].split(separator: ";") {
            let parts = item.split(separator: "@")
            guard parts.count == 2, let t = Double(parts[1]) else { continue }
            // An item with nothing after the colon ("leap:") is still a
            // gesture, so the empty half is kept.
            let body = parts[0].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard body.count == 2 else { continue }
            let kind = String(body[0]), arg = String(body[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                guard let size = controller.worldSize, size.width > 0 else { return }
                NSLog("[gestures] %@ %@", kind, arg)
                play(kind: kind, arg: arg, controller: controller, size: size)
            }
        }
    }

    private static func play(kind: String, arg: String, controller: GameController, size: CGSize) {
        // "0.3,0.5" is a point as a fraction of the pond.
        func point(_ s: Substring) -> CGPoint? {
            let xy = s.split(separator: ",").compactMap { Double($0) }
            guard xy.count == 2 else { return nil }
            return CGPoint(x: size.width * xy[0], y: size.height * xy[1])
        }
        let ends = arg.split(separator: ">", omittingEmptySubsequences: false)
        switch kind {
        case "tap":
            guard let p = point(arg[...]) else { return }
            tap(controller, at: p, size: size)
        case "hold":
            guard let p = point(arg[...]) else { return }
            hold(controller, at: p, size: size, for: 1.6)
        case "drop":
            guard let p = point(arg[...]) else { return }
            tap(controller, at: p, size: size)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { tap(controller, at: p, size: size) }
        case "flick":
            guard ends.count == 2, let a = point(ends[0]), let b = point(ends[1]) else { return }
            syntheticID += 1
            drag(controller, path: line(from: a, to: b, steps: 22), seconds: 0.35, id: syntheticID, size: size)
        case "stir":
            // An optional radius after the centre: "stir:0.5,0.5:0.16".
            let bits = arg.split(separator: ":")
            guard let c = point(bits[0]) else { return }
            let r = bits.count > 1 ? (Double(bits[1]) ?? 0.13) : 0.13
            let radius = min(size.width, size.height) * CGFloat(r)
            var path: [CGPoint] = []
            let steps = 75
            for k in 0...steps {
                let a = Double(k) / Double(steps) * 4 * .pi   // two turns
                path.append(CGPoint(x: c.x + radius * CGFloat(cos(a)), y: c.y + radius * CGFloat(sin(a))))
            }
            syntheticID += 1
            drag(controller, path: path, seconds: 1.2, id: syntheticID, size: size)
        case "slosh":
            // Slow enough not to cut a wake, far enough to shove the water.
            let a = (ends.count == 2 ? point(ends[0]) : nil) ?? CGPoint(x: size.width * 0.35, y: size.height * 0.5)
            let b = (ends.count == 2 ? point(ends[1]) : nil) ?? CGPoint(x: size.width * 0.62, y: size.height * 0.5)
            syntheticID += 1
            drag(controller, path: line(from: a, to: b, steps: 60), seconds: 1.5, id: syntheticID, size: size)
        case "leap":
            controller.scriptedLeap()
        case "drip":
            controller.scriptedDrip()
        case "wind":
            controller.scriptedWind()
        case "dusk":
            controller.scriptedDusk(Float(arg) ?? 0.85)
        case "tilt":
            // Two fingers side by side, drawn up the screen: the camera lies
            // over and the pond is seen more from its side.
            tiltDrag(controller, by: CGFloat(Double(arg) ?? 120), seconds: 1.5, size: size)
        case "gust":
            let a = (ends.count == 2 ? point(ends[0]) : nil) ?? CGPoint(x: size.width * 0.15, y: size.height * 0.5)
            let b = (ends.count == 2 ? point(ends[1]) : nil) ?? CGPoint(x: size.width * 0.85, y: size.height * 0.5)
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(1, hypot(dx, dy))
            // Two fingers side by side, thrown the same way.
            let off = CGPoint(x: -dy / len * 32, y: dx / len * 32)
            for sign in [CGFloat(1), CGFloat(-1)] {
                syntheticID += 1
                let from = CGPoint(x: a.x + off.x * sign, y: a.y + off.y * sign)
                let to = CGPoint(x: b.x + off.x * sign, y: b.y + off.y * sign)
                drag(controller, path: line(from: from, to: to, steps: 22), seconds: 0.35, id: syntheticID, size: size)
            }
        default:
            break
        }
    }

    /// Two fingers put down in the middle of the screen and drawn `by` points
    /// up it, which the controller reads as a tilt.
    private static func tiltDrag(_ controller: GameController, by: CGFloat, seconds: Double, size: CGSize) {
        let screen = screenSizeOf(controller) ?? size
        syntheticID += 1
        let a = syntheticID
        syntheticID += 1
        let b = syntheticID
        let from = [a: CGPoint(x: screen.width * 0.38, y: screen.height * 0.58),
                    b: CGPoint(x: screen.width * 0.62, y: screen.height * 0.58)]
        for id in [a, b] { controller.touchBegan(id: id, at: from[id]!, in: screen, weight: 0.4) }
        let steps = 30
        for k in 1...steps {
            let t = seconds * Double(k) / Double(steps)
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                for id in [a, b] {
                    let at = CGPoint(x: from[id]!.x, y: from[id]!.y - by * CGFloat(k) / CGFloat(steps))
                    controller.touchMoved(id: id, to: at, in: screen)
                    if k == steps { controller.touchEnded(id: id, at: at, in: screen) }
                }
            }
        }
    }

    private static func line(from: CGPoint, to: CGPoint, steps: Int) -> [CGPoint] {
        (0...steps).map { k in
            let t = CGFloat(k) / CGFloat(steps)
            return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        }
    }

    /// A finger drawn along a path in world points: down at the first point,
    /// a move every 16 ms, up at the last.
    private static func drag(_ controller: GameController, path: [CGPoint], seconds: Double, id: Int, size: CGSize) {
        guard path.count > 1 else { return }
        let screen = screenSizeOf(controller) ?? size
        controller.touchBegan(id: id, at: controller.screenPoint(path[0]), in: screen, weight: 0.4)
        for (k, p) in path.enumerated().dropFirst() {
            let t = seconds * Double(k) / Double(path.count - 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                let at = controller.screenPoint(p)
                controller.touchMoved(id: id, to: at, in: screen)
                if k == path.count - 1 { controller.touchEnded(id: id, at: at, in: screen) }
            }
        }
    }

    static func startIfRequested(controller: GameController) {
        scheduleScriptedTaps(controller: controller)
        scheduleScriptedGestures(controller: controller)
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

        // Ice first. A struck spot gets its second tap next beat; otherwise
        // the sheet is worked in a grid, the cell with the most ice left
        // first, well in from any open water so a tap gets a whole ring of
        // shards. Small scraps go under with one tap, so late on any ice
        // will do.
        if let field = controller.iceField {
            if beats == 3 { controller.showWholePond() }
            if let last = lastIceTap, field.ice(at: last) > 0.5, field.strikeIndex(containing: last) != nil {
                lastIceTap = nil
                tap(controller, at: last, size: size)
                return
            }
            if field.fraction > 0.004 {
                // No progress for a few beats: the chosen spot is not taking
                // taps (the bank band, a pad); pick somewhere else at random.
                if abs(field.fraction - lastFraction) < 0.001 { stalls += 1 } else { stalls = 0 }
                lastFraction = field.fraction
                var best: (CGPoint, Int)?
                let cols = 4, rows = 7
                let inset: CGFloat = 90
                for r in 0..<rows {
                    for c in 0..<cols {
                        let cx = inset + (size.width - 2 * inset) * (CGFloat(c) + 0.5) / CGFloat(cols)
                        let cy = inset + (size.height - 2 * inset) * (CGFloat(r) + 0.5) / CGFloat(rows)
                        var icy = 0
                        var deep: CGPoint?
                        for (dx, dy) in [(0, 0), (-30, -30), (30, -30), (-30, 30), (30, 30), (0, -45), (0, 45)] {
                            let p = CGPoint(x: cx + CGFloat(dx), y: cy + CGFloat(dy))
                            if field.ice(at: p) > 0.5 {
                                icy += 1
                                if deep == nil, !field.isEdge(at: p, within: 46) { deep = p }
                            }
                        }
                        // Prefer solid cells; among equals, ones with a deep
                        // spot; a little chance so the same cell does not win
                        // every time, and pure chance once stuck.
                        let score = stalls > 3 ? Int.random(in: 0...100) : icy * 2 + (deep == nil ? 0 : 1) + Int.random(in: 0...1)
                        if let target = deep ?? (icy > 0 ? CGPoint(x: cx, y: cy) : nil), best == nil || score > best!.1 {
                            best = (target, score)
                        }
                    }
                }
                if var target = best?.0 {
                    if field.ice(at: target) < 0.5, let near = field.nearestIce(to: target, range: 120) { target = near }
                    lastIceTap = target
                    NSLog("[demo] ice %.1f%%: tap (%.0f,%.0f)", field.fraction * 100, target.x, target.y)
                    tap(controller, at: target, size: size)
                    return
                }
            }
        }

        // Then the first goal not yet met, in the order the level wants them.
        let states = controller.goalStates
        for (i, g) in controller.goals.enumerated() where i < states.count && !states[i].done {
            if play(goal: g.kind, controller: controller, size: size) { return }
        }
    }

    /// One beat's worth of play toward a goal. Returns false if there was
    /// nothing to do for it this beat, so the next goal gets the beat.
    private static func play(goal: GoalKind, controller: GameController, size: CGSize) -> Bool {
        let live = controller.debris.filter { !$0.cleared }
        switch goal {
        case .breakIce:
            // The ice loop above has it; nothing to add.
            return false

        case .clearDebris:
            // Push each piece toward its nearest bank; a heavy one wants a
            // held swell beside it every third beat.
            guard let piece = live.filter({ !$0.kind.isSeed && $0.meltsIn == nil })
                    .min(by: { edgeDistance($0.position, size) < edgeDistance($1.position, size) }) else { return false }
            let p = piece.position
            let toLeft = p.x, toRight = size.width - p.x, toTop = p.y, toBottom = size.height - p.y
            let m = min(toLeft, toRight, toTop, toBottom)
            var away = CGVector(dx: 0, dy: 0)
            if m == toLeft { away.dx = 1 } else if m == toRight { away.dx = -1 } else if m == toTop { away.dy = 1 } else { away.dy = -1 }
            if piece.cls == .heavy {
                if beats % 3 == 0 {
                    hold(controller, at: CGPoint(x: p.x + away.dx * 42, y: p.y + away.dy * 42), size: size, for: 1.6)
                } else {
                    // Two rings arriving together lift what one cannot.
                    tap(controller, at: CGPoint(x: p.x + away.dx * 60 + 40, y: p.y + away.dy * 60 + 40), size: size)
                    tap(controller, at: CGPoint(x: p.x + away.dx * 60 - 40, y: p.y + away.dy * 60 - 40), size: size)
                }
            } else {
                tap(controller, at: CGPoint(x: p.x + away.dx * 32, y: p.y + away.dy * 32), size: size)
            }
            return true

        case .clearSilt:
            // Taps on a grid over the pond, a cell a beat.
            let cols = 3, rows = 6
            let k = beats % (cols * rows)
            let at = CGPoint(x: size.width * (0.18 + 0.64 * (CGFloat(k % cols) + 0.5) / CGFloat(cols)),
                             y: size.height * (0.16 + 0.68 * (CGFloat(k / cols) + 0.5) / CGFloat(rows)))
            tap(controller, at: at, size: size)
            return true

        case .partDuckweed:
            // Flicks across the pond at different heights, and now and then
            // a hold in the middle to push the weed out in a ring.
            if beats % 4 == 0 {
                hold(controller, at: CGPoint(x: size.width * 0.5, y: size.height * 0.5), size: size, for: 1.6)
            } else {
                let y = size.height * (0.2 + 0.6 * CGFloat((beats * 7) % 10) / 10)
                let leftToRight = beats % 2 == 0
                let a = CGPoint(x: size.width * (leftToRight ? 0.12 : 0.88), y: y)
                let b = CGPoint(x: size.width * (leftToRight ? 0.88 : 0.12), y: y)
                syntheticID += 1
                drag(controller, path: line(from: a, to: b, steps: 22), seconds: 0.35, id: syntheticID, size: size)
            }
            return true

        case .rootSeeds(let bed, _):
            // Each seed outside the shallows gets a tap on its far side, so
            // the ring shoves it toward the bed. One inside is left to rest.
            let seeds = live.filter { $0.kind.isSeed && !$0.rooted }
            let outside = seeds.filter { hypot($0.position.x - bed.centre.x, $0.position.y - bed.centre.y) > bed.radius * 0.8 }
            guard let seed = outside.min(by: { $0.id < $1.id }) else { return false }
            attempts[seed.id, default: 0] += 1
            let dx = seed.position.x - bed.centre.x, dy = seed.position.y - bed.centre.y
            let len = max(1, hypot(dx, dy))
            let tapAt = CGPoint(x: seed.position.x + dx / len * 34, y: seed.position.y + dy / len * 34)
            // One near the bed wants a gentler push: a tap further off.
            let far = len < bed.radius * 1.6 ? 1.6 : 1.0
            tap(controller, at: CGPoint(x: seed.position.x + (tapAt.x - seed.position.x) * far,
                                        y: seed.position.y + (tapAt.y - seed.position.y) * far), size: size)
            return true

        case .callKoi(let at, _):
            // One finger at a time: a second landing beside a held one
            // reads as a pair and drops the hold.
            guard !holding else { return true }
            hold(controller, at: at, size: size, for: 3.0)
            return true

        case .koiOpensBud(let bud):
            // A finger held a little below the bud: the koi comes up under it.
            guard !holding else { return true }
            hold(controller, at: CGPoint(x: bud.x, y: bud.y + 34), size: size, for: 3.0)
            return true

        case .leadShoal(let gate):
            // A flick from the shoal through the middle of the gate and on
            // past it; the shoal follows for a few seconds, so not every beat.
            guard beats % 4 == 0 else { return true }
            let mid = CGPoint(x: (gate.0.x + gate.1.x) / 2, y: (gate.0.y + gate.1.y) / 2)
            let from = controller.shoalCentroids.min {
                hypot($0.x - mid.x, $0.y - mid.y) < hypot($1.x - mid.x, $1.y - mid.y)
            } ?? CGPoint(x: mid.x, y: mid.y + size.height * 0.2)
            let dx = mid.x - from.x, dy = mid.y - from.y
            let len = max(1, hypot(dx, dy))
            let to = CGPoint(x: mid.x + dx / len * 140, y: mid.y + dy / len * 140)
            NSLog("[demo] shoal at (%.0f,%.0f): flick through gate (%.0f,%.0f)", from.x, from.y, mid.x, mid.y)
            syntheticID += 1
            drag(controller, path: line(from: from, to: to, steps: 22), seconds: 0.35, id: syntheticID, size: size)
            return true

        case .temptShyKoi(let home):
            // A finger held a little way off the home, over open water, and
            // nothing else at all: the water over the pads has to lie still.
            guard beats % 6 == 0 else { return true }
            let spot = open(near: home.centre, distance: 210, controller: controller, size: size)
            hold(controller, at: spot, size: size, for: 4.0)
            return true

        case .wakeTarget:
            // Send crests at it from the open side, a tap one beat and a held
            // swell the next, from wherever is not a pad, a rock or the thing.
            guard let target = controller.targets.first(where: { !$0.woke }) else { return false }
            let blocked: [(CGPoint, CGFloat)] = controller.pads.map { ($0.centre, $0.radius * 1.2) } + controller.level.rocks.map {
                (CGPoint(x: $0.centre.x * size.width, y: $0.centre.y * size.height), $0.radius * size.height * 1.3)
            }
            var spot: CGPoint?
            for k in 0..<16 {
                let a = CGFloat(k) / 16 * 2 * .pi + CGFloat(beats) * 0.37
                for r in [95.0, 140.0, 190.0] as [CGFloat] {
                    let p = CGPoint(x: target.position.x + cos(a) * r, y: target.position.y + sin(a) * r)
                    guard p.x > 40, p.y > 40, p.x < size.width - 40, p.y < size.height - 40 else { continue }
                    if blocked.contains(where: { hypot($0.0.x - p.x, $0.0.y - p.y) < $0.1 }) { continue }
                    spot = p
                    break
                }
                if spot != nil { break }
            }
            guard let p = spot else { return false }
            NSLog("[demo] target at (%.0f,%.0f): %@ from (%.0f,%.0f)", target.position.x, target.position.y, beats % 2 == 0 ? "hold" : "tap", p.x, p.y)
            if beats % 2 == 0 { hold(controller, at: p, size: size, for: 1.4) } else { tap(controller, at: p, size: size) }
            return true

        case .shishiOdoshi(let at, _):
            // A held swell beside the spout, over the water.
            let dx = size.width / 2 - at.x, dy = size.height / 2 - at.y
            let len = max(1, hypot(dx, dy))
            hold(controller, at: CGPoint(x: at.x + dx / len * 110, y: at.y + dy / len * 110), size: size, for: 1.6)
            return true

        case .suikinkutsu(let stones, let order):
            // The next stone in the phrase gets a tap just beside it, toward
            // the open water, every other beat so each crest has passed.
            guard beats % 2 == 0 else { return true }
            let played = controller.notesPlayed.count
            guard played < order.count, order[played] < stones.count else { return false }
            let stone = stones[order[played]]
            let dx = size.width / 2 - stone.x, dy = size.height / 2 - stone.y
            let len = max(1, hypot(dx, dy))
            tap(controller, at: CGPoint(x: stone.x + dx / len * 44, y: stone.y + dy / len * 44), size: size)
            return true

        case .fillPool(let lip, _, _):
            // Rock the pond toward the lip: a held swell released beside it
            // one beat, a slow shove of water at it the next.
            let dx = size.width / 2 - lip.x, dy = size.height / 2 - lip.y
            let len = max(1, hypot(dx, dy))
            let inward = CGPoint(x: dx / len, y: dy / len)
            if beats % 2 == 0 {
                hold(controller, at: CGPoint(x: lip.x + inward.x * 120, y: lip.y + inward.y * 120), size: size, for: 1.4)
            } else {
                let a = CGPoint(x: lip.x + inward.x * 220, y: lip.y + inward.y * 220)
                let b = CGPoint(x: lip.x + inward.x * 90, y: lip.y + inward.y * 90)
                syntheticID += 1
                holding = true
                drag(controller, path: line(from: a, to: b, steps: 60), seconds: 1.5, id: syntheticID, size: size)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { holding = false }
            }
            return true

        case .stillness:
            // Nothing at all: the pond has to be left alone.
            return true
        }
    }

    /// A point `distance` from `centre` over open water: not on a pad, a
    /// rock or the bank, trying round the compass from the pond's middle.
    private static func open(near centre: CGPoint, distance: CGFloat, controller: GameController, size: CGSize) -> CGPoint {
        let blocked: [(CGPoint, CGFloat)] = controller.pads.map { ($0.centre, $0.radius * 1.3) } + controller.level.rocks.map {
            (CGPoint(x: $0.centre.x * size.width, y: $0.centre.y * size.height), $0.radius * size.height * 1.4)
        }
        let toMiddle = atan2(size.height / 2 - centre.y, size.width / 2 - centre.x)
        for k in 0..<12 {
            let a = toMiddle + CGFloat(k) * (k % 2 == 0 ? 1 : -1) * 0.5
            let p = CGPoint(x: centre.x + cos(a) * distance, y: centre.y + sin(a) * distance)
            guard p.x > 60, p.y > 60, p.x < size.width - 60, p.y < size.height - 60 else { continue }
            if blocked.contains(where: { hypot($0.0.x - p.x, $0.0.y - p.y) < $0.1 }) { continue }
            return p
        }
        return CGPoint(x: size.width / 2, y: size.height / 2)
    }

    /// Points here are world points; the controller wants screen points.
    private static func tap(_ controller: GameController, at world: CGPoint, size: CGSize) {
        syntheticID += 1
        let id = syntheticID
        var at = world
        for pad in controller.pads where hypot(pad.centre.x - at.x, pad.centre.y - at.y) < pad.radius * 1.15 {
            let dx = at.x - pad.centre.x, dy = at.y - pad.centre.y
            let len = max(1, hypot(dx, dy))
            at = CGPoint(x: pad.centre.x + dx / len * pad.radius * 1.4, y: pad.centre.y + dy / len * pad.radius * 1.4)
        }
        let p = controller.screenPoint(at)
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
