import SwiftUI
import SpriteKit
import simd

/// One level in play. Owns the debris, decides what each touch means, keeps
/// the SpriteKit overlay and the Metal water in step, and runs the reveal and
/// the bloom when the pond is clear.
@MainActor
final class GameController: ObservableObject, TouchInput {

    enum Phase {
        case playing, celebrating, complete
    }

    @Published private(set) var phase: Phase = .playing
    @Published private(set) var hint: Hint?
    @Published private(set) var showTitle = false
    @Published private(set) var level: LevelSpec
    @Published private(set) var season: Season

    let scene = GardenScene()
    let sound = SoundDirector()
    let haptics = Haptics()
    private let progress = ProgressStore.shared

    private weak var renderer: WaterRenderer?
    private var viewSize = CGSize.zero

    private(set) var debris: [Debris] = []
    private var probeOrder: [Debris] = []
    private var current = SIMD2<Float>(0, 0)
    private var cleared = 0

    private var reveal = Array(repeating: Float(0), count: 16)
    private var revealTarget = Array(repeating: Float(0), count: 16)

    private let diagnostics = ProcessInfo.processInfo.arguments.contains("-diag")
    private var diagFrames = 0
    private var diagMaxSlope: Float = 0
    private var elapsed: Float = 0
    private var touchedYet = false
    private var hintShown = false

    private struct EdgeStroke {
        var last: CGPoint
        var travelled: CGFloat = 0
        var isStroke = false
        var sinceHaptic: CGFloat = 0
    }
    private var edgeStrokes: [Int: EdgeStroke] = [:]
    private var pondTouches: [Int: Float] = [:]     // id -> seconds held
    private var holdSounding: Set<Int> = []

    init(level: LevelSpec) {
        self.level = level
        self.season = Library.season(for: level)
        scene.configure(season: season)
        scene.setBloom(stage: progress.bloomStage(for: season.id), animated: false)
    }

    // MARK: - Wiring

    func attach(renderer: WaterRenderer) {
        self.renderer = renderer
        renderer.floorLook = season.floor
        renderer.depthPainter = { [level] w, h in DepthPainter.paint(level: level, width: w, height: h) }
        renderer.onFrame = { [weak self] dt in self?.frame(dt: dt) }
        renderer.onChargedRelease = { [weak self] charge in
            guard let self else { return }
            self.sound.holdRelease(charge: charge)
            self.haptics.holdRelease(charge: charge)
        }
        renderer.onSwellStart = { [weak self] in
            self?.sound.swell()
            self?.haptics.swell()
        }
        renderer.rebuildDepth()
        renderer.reveal = reveal
        load(level: level)
    }

    /// Resets everything for a level. Safe to call again on the same level.
    func load(level newLevel: LevelSpec) {
        level = newLevel
        season = Library.season(for: newLevel)
        phase = .playing
        cleared = 0
        elapsed = 0
        touchedYet = false
        hintShown = false
        hint = nil
        current = .zero
        reveal = Array(repeating: 0, count: 16)
        revealTarget = reveal
        edgeStrokes.removeAll()
        pondTouches.removeAll()
        holdSounding.removeAll()

        renderer?.floorLook = season.floor
        renderer?.reveal = reveal
        renderer?.cancelAll()
        renderer?.reset()

        scene.configure(season: season)
        scene.setBloom(stage: progress.bloomStage(for: season.id), animated: false)
        scene.removeAllDebris()
        debris = []
        probeOrder = []
        if viewSize != .zero { placeDebris() }

        showTitle = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            self?.showTitle = false
        }
        sound.startAmbience(root: season.rootNote)
    }

    private func placeDebris() {
        debris = level.debris.enumerated().map { i, p in
            let name: String
            let radius: CGFloat
            switch p.cls {
            case .light:
                let names = season.lightDebris
                name = names[p.variant % names.count]
                radius = 15 * p.scale
            case .heavy:
                let names = season.heavyDebris
                name = names[p.variant % names.count]
                radius = 34 * p.scale
            }
            let d = Debris(id: i, cls: p.cls, sprite: name,
                           position: CGPoint(x: p.at.x * viewSize.width, y: p.at.y * viewSize.height),
                           radius: radius, scale: p.scale)
            scene.addDebris(d)
            return d
        }
    }

    // MARK: - Per frame

    private func frame(dt: Float) {
        guard let renderer else { return }
        elapsed += dt

        // View size arrives with the first frame; debris cannot be placed
        // before it is known.
        if viewSize == .zero, scene.size.width > 0 {
            viewSize = scene.size
            if debris.isEmpty { placeDebris() }
        }
        guard viewSize != .zero else { return }

        // Edge current fades unless it is fed.
        if simd_length(current) > 0.01 {
            current *= exp(-dt * log(2) / GameTuning.currentHalfLife)
        }

        // Water under each piece, from the probes set last frame.
        let samples = renderer.latestSamples()
        var byID: [Int: FieldSample] = [:]
        for (i, d) in probeOrder.enumerated() where i < samples.count { byID[d.id] = samples[i] }

        if diagnostics {
            diagFrames += 1
            let maxSlope = samples.map { simd_length($0.slope) }.max() ?? 0
            diagMaxSlope = max(diagMaxSlope, maxSlope)
            if diagFrames % 60 == 0, let first = debris.first {
                NSLog("[garden] probes=%d samples=%d maxSlope=%.4f first=(%.1f, %.1f) v=(%.1f, %.1f) cleared=%d",
                      probeOrder.count, samples.count, diagMaxSlope, first.position.x, first.position.y,
                      first.velocity.x, first.velocity.y, cleared)
                diagMaxSlope = 0
            }
        }

        if phase == .playing {
            for d in debris where !d.cleared {
                DebrisPhysics.integrate(d, sample: byID[d.id], current: current, dt: dt)
            }
            DebrisPhysics.separate(debris, dt: dt)
            for d in debris where !d.cleared && DebrisPhysics.hasReachedShore(d, in: viewSize) {
                clear(d)
            }
        }
        scene.update(debris: debris)

        // Next frame's probes.
        probeOrder = debris.filter { !$0.cleared }
        renderer.setProbes(probeOrder.compactMap { renderer.cell(for: $0.position, in: viewSize) })

        // Holds: the sound swells with the charge.
        for (id, held) in pondTouches {
            pondTouches[id] = held + dt
            let charge = renderer.charge(of: id)
            if charge > 0.12, held + dt > GameTuning.holdSoundAfter, !holdSounding.contains(id) {
                holdSounding.insert(id)
                sound.holdBegin(id: id)
                haptics.holdBegin()
            }
            if holdSounding.contains(id) { sound.holdLevel(id: id, charge: charge) }
        }

        // Mosaic reveal wipes outward at a steady pace.
        var changed = false
        for i in 0..<16 where reveal[i] < revealTarget[i] {
            reveal[i] = min(revealTarget[i], reveal[i] + dt * 0.75)
            changed = true
        }
        if changed { renderer.reveal = reveal }

        // First-time nudge, only if the player has not found the water yet.
        if let h = level.hint, !hintShown, !touchedYet, elapsed > 4.0, !HintMemory.seen(h) {
            hintShown = true
            withAnimation(.spring(duration: 0.6)) { hint = h }
        }
    }

    // MARK: - Touches

    private func isOnEdge(_ p: CGPoint, in size: CGSize) -> Bool {
        let b = GameTuning.edgeBand
        return p.x < b || p.y < b || p.x > size.width - b || p.y > size.height - b
    }

    private func noticeTouch() {
        touchedYet = true
        if let h = hint {
            HintMemory.markSeen(h)
            withAnimation(.easeOut(duration: 0.35)) { hint = nil }
        }
    }

    func touchBegan(id: Int, at point: CGPoint, in size: CGSize, weight: Float) {
        viewSize = size
        noticeTouch()
        guard phase == .playing || phase == .celebrating else { return }

        if isOnEdge(point, in: size) {
            // Might be a stroke along the bank, might be a tap near it. We
            // find out when it moves, or when it lifts without moving.
            edgeStrokes[id] = EdgeStroke(last: point)
            return
        }

        if let koi = scene.koiHit(at: point) {
            scene.dive(koi)
            sound.plop()
            haptics.plop()
        }

        renderer?.touchDown(id: id, at: point, in: size, weight: weight)
        pondTouches[id] = 0
        sound.tap(x: Float(point.x / size.width), weight: weight)
        haptics.tap(weight: weight)
    }

    func touchMoved(id: Int, to point: CGPoint, in size: CGSize) {
        if var stroke = edgeStrokes[id] {
            let dx = point.x - stroke.last.x, dy = point.y - stroke.last.y
            let dist = hypot(dx, dy)
            stroke.travelled += dist
            stroke.sinceHaptic += dist
            if !stroke.isStroke, stroke.travelled > GameTuning.edgeStrokeMinTravel {
                stroke.isStroke = true
                sound.currentBegin(id: id)
            }
            if stroke.isStroke, dist > 0 {
                let gain = GameTuning.currentGainPerPoint * Float(dist)
                current += SIMD2(Float(dx), Float(dy)) / Float(dist) * gain
                let mag = simd_length(current)
                if mag > GameTuning.currentMax { current *= GameTuning.currentMax / mag }
                sound.currentLevel(id: id, strength: mag / GameTuning.currentMax)

                // The bank acknowledges the finger with a faint wake.
                renderer?.addSplat(at: point, in: size, radius: 9, amplitude: -0.07)
                if stroke.sinceHaptic > 36 {
                    stroke.sinceHaptic = 0
                    haptics.currentTick()
                }
            }
            stroke.last = point
            edgeStrokes[id] = stroke
            return
        }
        renderer?.touchMoved(id: id, to: point, in: size)
    }

    func touchEnded(id: Int, at point: CGPoint, in size: CGSize) {
        if let stroke = edgeStrokes.removeValue(forKey: id) {
            if stroke.isStroke {
                sound.currentEnd(id: id)
            } else {
                // A still touch on the bank is just a tap near the edge.
                renderer?.touchDown(id: id, at: point, in: size, weight: 0.3)
                renderer?.touchUp(id: id)
                sound.tap(x: Float(point.x / size.width), weight: 0.3)
                haptics.tap(weight: 0.3)
            }
            return
        }
        pondTouches.removeValue(forKey: id)
        if holdSounding.remove(id) != nil { sound.holdEnd(id: id) }
        renderer?.touchUp(id: id)
    }

    // MARK: - Clearing and finishing

    private func clear(_ d: Debris) {
        d.cleared = true
        cleared += 1
        scene.clear(d, in: viewSize)
        let total = max(1, level.debris.count)
        sound.clearNote(index: cleared, of: total)
        haptics.clear()

        let sectors = season.floor.sectors
        let shouldShow = min(sectors, cleared * sectors / total)
        for i in 0..<shouldShow { revealTarget[i] = 1 }

        if cleared >= total { finish() }
    }

    private func finish() {
        phase = .celebrating
        for i in 0..<16 { revealTarget[i] = 1 }
        let target = level.bloomTarget
        progress.markComplete(levelID: level.id, seasonID: season.id, bloomStage: target)

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(0.7))
            self.sound.complete()
            self.haptics.complete()
            self.scene.bloom(to: target, duration: 5.0)
            try? await Task.sleep(for: .seconds(4.6))
            withAnimation(.easeOut(duration: 0.8)) { self.phase = .complete }
        }
    }

    /// The Next button. Until the hub exists this replays the level.
    func next() {
        let following = Library.level(after: level) ?? level
        load(level: following)
    }
}

/// Which first-time nudges the player has already had.
enum HintMemory {
    static func seen(_ h: Hint) -> Bool {
        UserDefaults.standard.bool(forKey: "hint.seen.\(h.rawValue)")
    }
    static func markSeen(_ h: Hint) {
        UserDefaults.standard.set(true, forKey: "hint.seen.\(h.rawValue)")
    }
}

/// Turns a level's obstacles and shallows into the depth map the wave kernel
/// samples. 1 is deep open water, 0 is a wall.
enum DepthPainter {
    static func paint(level: LevelSpec, width: Int, height: Int) -> [Float] {
        var map = [Float](repeating: 1, count: width * height)
        guard !level.obstacles.isEmpty || !level.shallows.isEmpty else { return map }
        let fw = Float(width), fh = Float(height)
        for y in 0..<height {
            for x in 0..<width {
                let px = Float(x) / fw, py = Float(y) / fh
                var d: Float = 1
                for s in level.shallows {
                    let r = Float(s.radius)
                    let dx = (px - Float(s.centre.x)) * (fw / fh), dy = py - Float(s.centre.y)
                    let dist = (dx * dx + dy * dy).squareRoot() / r
                    if dist < 1 { d = min(d, 0.25 + 0.75 * dist * dist) }
                }
                for o in level.obstacles {
                    let r = Float(o.radius)
                    let dx = (px - Float(o.centre.x)) * (fw / fh), dy = py - Float(o.centre.y)
                    let dist = (dx * dx + dy * dy).squareRoot() / r
                    if dist < 1 { d = 0 } else if dist < 1.25 { d = min(d, (dist - 1) / 0.25) }
                }
                map[y * width + x] = d
            }
        }
        return map
    }
}
