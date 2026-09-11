import CoreGraphics
import Foundation
import QuartzCore
import SwiftUI
import simd

/// The player's own pond (docs/garden-spec.md, "The plot"). A second scene
/// on its own `WaterRenderer`, the size of one level: bank earth the size
/// of the world, which the finger digs into, a sluice stone that lets the
/// water in, and a tray of everything the year's levels have given, to be
/// put down and left to live. No goals, no status line, no hints after the
/// first visit.
///
/// What a touch means is decided by what it lands on: earth is dug, water
/// is worked as in a level, the stones are tapped, the tray is scrolled or
/// picked from, a placed thing is held to lift it. Everything placed is
/// saved through `ProgressStore` as `PlotState` and comes back as it was,
/// grown by the real days it was left.
@MainActor
final class PlotController: ObservableObject, TouchInput {

    static let worldScale = CGSize(width: 1.4, height: 1.4)
    static let gridLongSide = Tuning.gridLongSide
    /// Which of the player's plots this is; the pager sets it before the first frame.
    var plotIndex = 0
    /// Depth the water shader reads as dry ground below.
    static let dryLine: Float = 0.11

    /// The menu that is up, when one is.
    @Published private(set) var presented: MenuScreen?
    /// The one line a first visit shows, for a few seconds.
    @Published private(set) var words: PondWords?
    var onExit: (() -> Void)?

    let sound = SoundDirector()
    let haptics = Haptics()

    private weak var renderer: WaterRenderer?
    private let garden: Garden
    private var art: ArtSet
    private var viewSize = CGSize.zero
    private var screenSize = CGSize.zero
    private var placed = false
    private var elapsed: Float = 0
    private let inventory = Inventory.shared
    private let progress = ProgressStore.shared

    // MARK: The plot itself

    private var state = PlotState()
    private var dig: DigField?
    private enum Sluice { case closed, filling, draining }
    private var sluice: Sluice = .closed
    private var sluicePoint = CGPoint.zero
    private var trayStonePoint = CGPoint.zero
    /// The depth map wants painting again: the water moved or the spade did.
    private var depthDirty = true
    private var repaintAt: Float = 0
    private var lastPaintedWater: Float = -1
    private var nextSluiceRippleAt: Float = 0
    private var firstVisit = false
    private var wordsUntil: Float = 0

    /// Everything put down, alive.
    private var live: [LiveItem] = []
    private var petalsAfloat: [Debris] = []
    private var pellets: [Debris] = []
    private var grains: [Grain] = []
    private var nextFloaterID = 1
    private let tray = Tray()
    /// A thing under a finger, off the tray or lifted from the plot.
    private var carry: Carry?
    /// Two fingers on one thing: a twist turns it, a pinch sizes it.
    private var pair: Pair?
    private var probeOrder: [Debris] = []
    /// The koi are being called to a pellet rather than a finger.
    private var pelletCall = false

    /// The season the real calendar says it is: its art, its bank painting
    /// and its air. Winter is December to February and so on round.
    private let season: Season

    // MARK: The view

    /// Zoom and centre, eased toward what the fingers asked for.
    private var zoomTarget: Float = 0.76
    private var centreTarget = SIMD2<Float>(0, 0)
    /// Two fingers on the water with nothing held: a pinch zooms, a drag
    /// the same way tilts, as in a level.
    private struct CameraPair {
        var ids: [Int]
        var startDistance: CGFloat
        var startZoom: Float
        var anchorWorld: SIMD2<Float>
        var active = false
        var tilting = false
        var last: [Int: CGPoint] = [:]
        var travel: [Int: CGPoint] = [:]
        var lastAt: TimeInterval = 0
    }
    private var cameraPair: CameraPair?

    // MARK: The weather

    /// A gentle wind that changes its mind every twenty seconds, in points
    /// per second of drift for a light thing on the water, eased so the
    /// boats swing round rather than jump.
    private var breeze = SIMD2<Float>(0, 0)
    private var breezeTarget = SIMD2<Float>(0, 0)
    private var nextBreezeAt: Float = 0
    /// A gust two fingers threw: a line of water marching across the pond
    /// and a shove on everything with a sail.
    private struct Gust {
        var direction: SIMD2<Float>
        var origin: CGPoint
        var length: CGFloat
        var age: Float = 0
    }
    private var gust: Gust?
    private var lastGustAt: TimeInterval = 0
    /// Snow, when the sky item is on: flakes falling to land on the water.
    private var snow: [FallingPetal] = []
    private var snowAccumulator: Float = 0
    /// Fireflies after dusk, when the sky item is on.
    private struct Firefly {
        var position: CGPoint
        var drift: CGVector
        var phase: Float
    }
    private var fireflies: [Firefly] = []

    // MARK: Touch

    private enum Role {
        case dig(DigStroke)
        case water(WaterTouch)
        case sluice(began: TimeInterval, acted: Bool)
        case trayStone(began: TimeInterval)
        case tray(item: CatalogueItem?, start: CGPoint, last: CGPoint, decided: Bool)
        case carrying
        /// A finger resting on a placed thing: a tap uses it, a long press lifts it.
        case hold(item: LiveItem, began: TimeInterval, start: CGPoint)
        case idle
    }
    private struct DigStroke {
        var last: CGPoint
        var carried: CGFloat = 0
        var sinceGrain: CGFloat = 0
        var lastAt: TimeInterval
        var speed: Float = 0
        var nextVoiceAt: TimeInterval = 0
    }
    private struct WaterTouch {
        var last: CGPoint
        var lastAt: TimeInterval
        var speed: Float = 0
        var isWake = false
        var sinceSplat: CGFloat = 0
        var sounding = false
        /// Which way the finger is going, for reading two of them as a gust.
        var heading: SIMD2<Float>?
        /// Thrown as a gust: the water is done with it.
        var spent = false
        /// It has been calling a koi: the call is let go when it lifts.
        var calling = false
    }
    private final class Carry {
        let item: CatalogueItem
        /// The placed record it was lifted from, if it came off the plot.
        var lifted: LiveItem?
        var position: CGPoint
        var rotation: Float
        var scale: CGFloat
        var fingerID: Int
        init(item: CatalogueItem, lifted: LiveItem?, position: CGPoint, rotation: Float, scale: CGFloat, fingerID: Int) {
            self.item = item
            self.lifted = lifted
            self.position = position
            self.rotation = rotation
            self.scale = scale
            self.fingerID = fingerID
        }
    }
    private struct Pair {
        var ids: [Int]
        var target: LiveItem?
        var startAngle: Float
        var startDistance: CGFloat
        var rotation0: Float
        var scale0: CGFloat
    }
    private var touches: [Int: Role] = [:]
    private var screenTouches: [Int: CGPoint] = [:]
    private var lastTouchAt: TimeInterval = 0

    // MARK: Saving

    private var saveAt: TimeInterval?
    private let sluiceSoundID = -8

    /// The season the calendar says: December to February winter, then
    /// three months each of spring, summer and autumn.
    static func seasonNow(month: Int = Calendar.current.component(.month, from: Date())) -> Season {
        let id: String
        switch month {
        case 3...5: id = "spring"
        case 6...8: id = "summer"
        case 9...11: id = "autumn"
        default: id = "winter"
        }
        return Library.season(id: id) ?? Library.spring
    }

    init() {
        // The season's air over the plot. Nothing the garden would lay out
        // on its own: no reeds, flowers, weeds, fish or small life, and no
        // stones in the bed either, since those are drawn into the floor
        // wherever they fall and the plot is bare earth until the player
        // digs. The branches, the clouds and the dragonfly stay. Snow falls
        // only when the snow item is on, whatever the month.
        season = PlotController.seasonNow()
        var a = season.woodblock
        a.ambientFall = nil
        a.koi = []
        a.shoal = []
        a.reeds = []
        a.flowers = []
        a.weeds = []
        a.under = []
        a.skaters = []
        a.stones = []
        a.gravel = []
        a.sand = []
        a.frog = nil
        a.newt = nil
        a.heron = nil
        art = a
        garden = Garden(art: a)
    }

    // MARK: - Wiring

    func attach(renderer: WaterRenderer) {
        self.renderer?.onFrame = nil
        self.renderer = renderer
        viewSize = .zero
        placed = false
        renderer.style = .woodblock
        renderer.pitchLimit = WaterRenderer.maxPitch
        var look = art.floor
        look.mosaicRadius = 0
        renderer.floorLook = look
        renderer.setSilt(wholePond: false)
        renderer.setFilm(on: false)
        // The whole world wears the season's bank, as a level does.
        let painting = "bank_\(season.id)"
        renderer.bankPaintings = [painting, painting, painting, painting]
        renderer.bank = SIMD3(1, 1, 1)
        renderer.depthPainter = { [weak self] w, h in
            self?.paintDepth(width: w, height: h) ?? Array(repeating: DepthPainter.dryDepth, count: w * h)
        }
        renderer.rebuildDepth()
        renderer.zoom = 0.76
        garden.textureSize = { [weak renderer] name in renderer?.textures.size(name) ?? CGSize(width: 1, height: 1) }
        renderer.onFrame = { [weak self] dt in self?.frame(dt: dt) }
        renderer.onChargedRelease = { [weak self] charge, at in
            guard let self else { return }
            self.sound.holdRelease(charge: charge)
            self.haptics.holdRelease(charge: charge)
            if charge > 0.5 { self.garden.burstDroplets(at: at, power: charge) }
        }
        renderer.onSwellStart = { [weak self] in
            self?.sound.swell()
            self?.haptics.swell()
        }
        sound.startAmbience(named: "amb_\(season.id)")
    }

    /// The season's air, with the night under it after dusk and a little
    /// rain's hush when the mist is up. Set every frame; the director eases
    /// each layer itself.
    private func blendAir() {
        guard let renderer else { return }
        var shares: [String: Float] = ["amb_\(season.id)": 1]
        let evening = max(0, min(1, (renderer.dayPhase - 0.68) / 0.12))
        if evening > 0.01 {
            shares["amb_night"] = evening * 0.8
            shares["amb_\(season.id)"] = 1 - evening * 0.5
        }
        if state.sky.contains("mist") { shares["amb_rain_light"] = 0.25 }
        sound.blendAmbience(shares)
    }

    /// On the way out: the plot is written now, not two seconds from now.
    func leave() {
        letGoOfEverything()
        save()
        presented = nil
        words = nil
        if sluice == .filling { sound.inletEnd(id: sluiceSoundID) }
        sound.stopAmbience()
    }

    /// Every finger is forgotten: a thing being carried goes back where it
    /// came from, and every voice a touch had stops.
    private func letGoOfEverything() {
        for (id, role) in touches {
            if case .water(let t) = role {
                if t.sounding { sound.holdEnd(id: id) }
                if t.isWake { sound.wakeEnd(id: id) }
            }
        }
        touches.removeAll()
        screenTouches.removeAll()
        cameraPair = nil
        garden.releaseCall()
        pelletCall = false
        if let c = carry, let l = c.lifted {
            l.lifted = false
            wake(l)
        }
        carry = nil
        pair = nil
        haptics.slideEnd()
        renderer?.cancelAll()
    }

    // MARK: - Laying out

    private func place() {
        guard let renderer else { return }
        let args = ProcessInfo.processInfo.arguments
        renderer.viewCentre = SIMD2(Float(viewSize.width) / 2, Float(viewSize.height) / 2)
        // The stones the plot is worked with sit where the screen can reach
        // them: the sluice at the right edge halfway up, the tray's stone at
        // the bottom right above the gear.
        sluicePoint = renderer.worldPoint(screen: CGPoint(x: screenSize.width - 30, y: screenSize.height * 0.42))
        trayStonePoint = renderer.worldPoint(screen: CGPoint(x: screenSize.width - 30, y: screenSize.height - 100))

        // What was saved, if anything.
        let saved = progress.plot(index: plotIndex)
        firstVisit = saved == nil
        state = saved ?? PlotState()
        dig = DigField(state: state, world: viewSize) ?? DigField(world: viewSize)
        sluice = state.sluiceOpen ? .filling : .closed
        if plotIndex == 0, args.contains("-plotDug") || args.contains("-plotFull") {
            if dig?.isEmpty ?? true { dig?.digDemoHollow() }
            state.water = 1
            state.sluiceOpen = false
            sluice = .closed
        }
        if sluice == .filling { sound.inletBegin(id: sluiceSoundID) }

        garden.depthAt = { [weak self] p in self?.depth(at: p) ?? 1 }
        garden.groundAt = { [weak self] p in self?.depth(at: p) ?? 1 }
        // The fish keep to the water the player dug.
        garden.confineToWater = true
        garden.configure(art: art, size: viewSize, bloomStage: 3)
        garden.mistAmount = state.sky.contains("mist") ? 1.0 : 0.3
        zoomTarget = 0.76
        centreTarget = SIMD2(Float(viewSize.width) / 2, Float(viewSize.height) / 2)
        cameraPair = nil
        gust = nil
        snow = []
        fireflies = []
        nextBreezeAt = 0

        // Everything placed comes back, and the fish that were let go.
        live = []
        petalsAfloat = []
        pellets = []
        grains = []
        carry = nil
        pair = nil
        pelletCall = false
        touches.removeAll()
        screenTouches.removeAll()
        for p in state.placed {
            guard let item = Catalogue.item(p.item) else { continue }
            let l = LiveItem(placed: p, item: item)
            live.append(l)
            wake(l)
        }
        for p in state.petals {
            petalsAfloat.append(makeFloater(sprite: art.petalParticle, at: p, radius: 8, light: true))
        }
        catchUpPetals(since: state.lastVisit)
        if plotIndex == 0, args.contains("-plotFull") { demoPlace() }
        if firstVisit {
            words = PondWords(title: nil, line: "Drag on the earth to dig. Tap the stone to let the water in.")
            wordsUntil = elapsed + 6
        }
        depthDirty = true
        repaintAt = 0
        placed = true
    }

    /// Things put down for a screenshot: reeds and blossom along the shore,
    /// pads on the shelf, a stone, a log, two koi and a shoal, the toys and
    /// the bowl.
    private func demoPlace() {
        let wanted = ["reeds-spring", "reeds-spring-tall", "blossom-spring-1", "blossom-spring-2", "fern",
                      "lilypad-1", "lilypad-2", "lotus", "stone-medium", "driftwood-log",
                      "koi-orange", "koi-kohaku", "shoal-minnow", "food-bowl",
                      "paper-boat", "sailing-boat", "floating-lantern", "tea-bowl"]
        inventory.grant(wanted, level: "grant")
        var rng = SystemRandomNumberGenerator()
        for id in wanted where !live.contains(where: { $0.item.id == id }) {
            guard let item = Catalogue.item(id) else { continue }
            var spot: CGPoint?
            for _ in 0..<60 {
                let p = CGPoint(x: CGFloat.random(in: 60...(viewSize.width - 60), using: &rng),
                                y: CGFloat.random(in: 80...(viewSize.height - 80), using: &rng))
                if let q = placementPoint(for: item, at: p) {
                    // Not on top of something already down.
                    if live.contains(where: { hypot($0.placed.position.x - q.x, $0.placed.position.y - q.y) < 50 }) { continue }
                    spot = q
                    break
                }
            }
            guard let q = spot else { continue }
            var p = PlacedItem(item: item.id, position: q, rotation: Float.random(in: -0.2...0.2, using: &rng), scale: 1)
            // Grown already, so the screenshot shows the plants and not sprouts.
            p.plantedAt = Date().addingTimeInterval(-30 * 86400)
            let l = LiveItem(placed: p, item: item)
            live.append(l)
            state.placed.append(p)
            wake(l)
        }
        for l in live where l.item.shedsPetals {
            for _ in 0..<2 { shedPetal(from: l) }
        }
    }

    // MARK: - Depth

    /// Depth of the pond at a world point: what was dug times how full the
    /// hollow is, never below dry earth. Dug earth with no water in it yet
    /// is lifted a hair above dry, still well under the waterline, which
    /// the bank shader draws as its darker lip: turned earth, before the
    /// sluice has let anything in.
    static let turnedEarth: Float = 0.025

    func depth(at p: CGPoint) -> Float {
        guard let dig else { return DepthPainter.dryDepth }
        let dug = dig.depth(at: p)
        return PlotController.effectiveDepth(dug: dug, water: state.water)
    }

    /// The bed the sim reads from what has been dug and how full the hollow
    /// is. The edge of the water is kept crisp: where there is water at all
    /// it is at least ankle deep, so the shoreline is a line and not a wide
    /// wet smear over the brush's soft rim.
    static func effectiveDepth(dug: Float, water: Float) -> Float {
        let turned = DepthPainter.dryDepth + dug * turnedEarth
        let wet = dug * water
        guard wet > 0.02 else { return turned }
        let filled = 0.13 + 0.87 * min(1, (wet - 0.02) / 0.98)
        return max(turned, filled)
    }

    private func isWater(_ p: CGPoint) -> Bool { depth(at: p) >= PlotController.dryLine }

    private func paintDepth(width w: Int, height h: Int) -> [Float] {
        var map = [Float](repeating: DepthPainter.dryDepth, count: w * h)
        guard let dig, viewSize.width > 0 else { return map }
        let water = state.water
        let sx = viewSize.width / CGFloat(w), sy = viewSize.height / CGFloat(h)
        for y in 0..<h {
            let py = (CGFloat(y) + 0.5) * sy
            for x in 0..<w {
                let dug = dig.depth(at: CGPoint(x: (CGFloat(x) + 0.5) * sx, y: py))
                map[y * w + x] = PlotController.effectiveDepth(dug: dug, water: water)
            }
        }
        return map
    }

    // MARK: - Per frame

    private func frame(dt: Float) {
        guard let renderer else { return }
        elapsed += dt
        let now = CACurrentMediaTime()
        if viewSize == .zero, let world = renderer.worldSizePoints, let screen = renderer.viewSizePoints, world.width > 0 {
            viewSize = world
            screenSize = screen
            place()
        }
        guard placed, let dig else { return }
        // Ease the view toward where the fingers want it, and keep it on the plot.
        renderer.zoom += (zoomTarget - renderer.zoom) * min(1, dt * 8)
        let halfW = Float(screenSize.width) / renderer.zoom / 2, halfH = Float(screenSize.height) / renderer.zoom / 2
        centreTarget.x = max(halfW, min(Float(viewSize.width) - halfW, centreTarget.x))
        centreTarget.y = max(halfH, min(Float(viewSize.height) - halfH, centreTarget.y))
        renderer.viewCentre += (centreTarget - renderer.viewCentre) * min(1, dt * 8)

        if words != nil, elapsed > wordsUntil { withAnimation(Motion.words) { words = nil } }

        updateSluice(dt: dt)
        // The depth map is painted again at most five times a second while
        // the water is moving or the spade is in the earth.
        if dig.dirtyRect != nil { depthDirty = true }
        if depthDirty, elapsed >= repaintAt {
            renderer.repaintDepth()
            dig.markClean()
            depthDirty = false
            lastPaintedWater = state.water
            repaintAt = elapsed + 0.2
        }

        updateTouches(now: now, dt: dt)
        updateGrowth(now: now)
        updatePetals(now: now)
        updateWeather(dt: dt, now: now)

        // The floaters read the water where they lie.
        let samples = renderer.latestSamples()
        var byID: [Int: FieldSample] = [:]
        for (i, d) in probeOrder.enumerated() where i < samples.count { byID[d.id] = samples[i] }
        let floaters = petalsAfloat + pellets + live.compactMap(\.body)
        let wind = windNow()
        for d in floaters {
            let was = d.position
            DebrisPhysics.integrate(d, sample: byID[d.id], current: .zero, dt: dt)
            // Nothing floats onto the earth: a piece that would is left where it was.
            if !isWater(d.position) { d.position = was; d.velocity = .zero }
            keepOffWalls(d)
        }
        // The boats feel the wind on their sails and turn their bows into
        // their own motion, the way a boat with way on lies.
        for l in live where l.sail > 0 {
            guard let d = l.body else { continue }
            d.velocity += wind * l.sail * dt
            d.spin = 0
            let sp = simd_length(d.velocity)
            if sp > 3 {
                var diff = CGFloat(atan2(d.velocity.y, d.velocity.x)) - d.angle
                while diff > .pi { diff -= 2 * .pi }
                while diff < -.pi { diff += 2 * .pi }
                d.angle += diff * CGFloat(min(1, dt * (0.6 + Float(sp) * 0.03)))
            }
        }
        DebrisPhysics.separate(floaters, dt: dt)
        for l in live where l.body != nil {
            l.placed.position = l.body!.position
            l.placed.rotation = Float(l.body!.angle)
        }
        updateToys(dt: dt)
        for g in grains { g.update(dt: dt) }
        grains.removeAll(where: \.landed)

        // Sway on the bank: a spring the wind and the fingers shove.
        for l in live {
            let force = -l.sway * 24 - l.swayVel * 4.5 + breeze.x * 0.15
            l.swayVel += force * dt
            l.sway += l.swayVel * dt
            l.sway = max(-0.45, min(0.45, l.sway))
        }

        updateFish(dt: dt, now: now)
        // The sky things. Dusk holds the hour at evening; the moon lies in
        // the water only once the light has gone; the mist is the garden's.
        if state.sky.contains("dusk"), renderer.dayPhase < 0.8 { renderer.dayPhase = 0.8 }
        let dark = renderer.dayPhase > 0.7 || renderer.dayPhase < 0.18
        garden.stillness(state.sky.contains("moon") && dark ? 1 : 0)
        updateSky(dt: dt, dark: dark)
        garden.update(dt: dt, now: now)
        for s in garden.splashes { renderer.addSplat(at: s.at, in: viewSize, radius: s.radius, amplitude: s.amplitude) }
        garden.splashes.removeAll()
        // The koi mouthing at the surface, heard.
        for e in garden.events {
            if case .mouth(let p) = e, isWater(p) { sound.mouth(x: Float(p.x / viewSize.width)) }
        }
        if Int(elapsed * 2) != Int((elapsed - dt) * 2) { blendAir() }

        // Probes for next frame: one per floater, within the renderer's room.
        probeOrder = Array(floaters.prefix(Tuning.maxProbes))
        var cells: [SIMD2<Float>] = []
        for d in probeOrder { cells.append(renderer.cell(for: d.position, in: viewSize) ?? SIMD2(0, 0)) }
        renderer.setProbes(cells)

        // The tray keeps to the bottom of the screen.
        tray.home = renderer.worldPoint(screen: CGPoint(x: screenSize.width / 2 - 24, y: screenSize.height - 96))
        let offRight = renderer.worldPoint(screen: CGPoint(x: screenSize.width + Tray.length, y: screenSize.height - 96))
        tray.update(dt: dt, items: trayItems(), slideFrom: offRight.x - tray.home.x)

        feed(renderer)

        if let at = saveAt, now >= at { save() }
    }

    /// What the tray shows: everything owned, less what is down, less the
    /// sky things already switched on.
    private func trayItems() -> [CatalogueItem] {
        var out: [CatalogueItem] = []
        for owned in inventory.owned {
            guard let item = Catalogue.item(owned.id) else { continue }
            let down = live.filter { $0.item.id == item.id }.count + (carry?.item.id == item.id && carry?.lifted == nil ? 1 : 0)
            if item.placement == .sky {
                if !state.sky.contains(item.id) { out.append(item) }
            } else if owned.count > down {
                out.append(item)
            }
        }
        return out
    }

    // MARK: - The sluice

    private func updateSluice(dt: Float) {
        var rate: Float = 0
        switch sluice {
        case .closed: break
        case .filling:
            let held = touches.values.contains { if case .sluice = $0 { return true }; return false }
            rate = (held ? 3 : 1) / PlotTuning.fillSeconds
        case .draining:
            rate = -1 / PlotTuning.fillSeconds
        }
        guard rate != 0 else { return }
        let was = state.water
        state.water = max(0, min(1, state.water + rate * dt))
        if state.water != was {
            if abs(state.water - lastPaintedWater) > 0.004 { depthDirty = true }
            noteChange()
        }
        if sluice == .filling, state.water >= 1 { closeSluice() }
        if sluice == .draining, state.water <= 0 { sluice = .closed }
        // Water coming in: a ripple train from the stone, and its foam.
        if sluice == .filling, elapsed > nextSluiceRippleAt {
            nextSluiceRippleAt = elapsed + 0.4
            let flow = garden.inletFlow()
            if let f = flow {
                let p = CGPoint(x: f.at.x + f.into.dx * 30, y: f.at.y + f.into.dy * 30)
                if isWater(p) { renderer?.addSplat(at: p, in: viewSize, radius: 9, amplitude: -0.05) }
            }
        }
    }

    private func openSluice() {
        sluice = .filling
        state.sluiceOpen = true
        garden.inlet = sluicePoint
        sound.inletBegin(id: sluiceSoundID)
        sound.plop()
        haptics.plop()
        noteChange()
    }

    private func closeSluice() {
        if sluice == .filling { sound.inletEnd(id: sluiceSoundID) }
        sluice = .closed
        state.sluiceOpen = false
        garden.inlet = nil
        haptics.tap(weight: 0.5)
        noteChange()
    }

    private func drainSluice() {
        if sluice == .filling { sound.inletEnd(id: sluiceSoundID) }
        sluice = .draining
        state.sluiceOpen = false
        garden.inlet = nil
        sound.holdRelease(charge: 0.4)
        haptics.holdRelease(charge: 0.4)
        noteChange()
    }

    // MARK: - Growth, petals, feeding

    /// How far a thing has grown, 0 a sprout to 1 full, eased on real days.
    private func grown(_ l: LiveItem, now: Date = Date()) -> CGFloat {
        guard l.item.growDays > 0 else { return 1 }
        let age = now.timeIntervalSince(l.placed.plantedAt) / 86400
        let t = CGFloat(max(0, min(1, age / l.item.growDays)))
        return t * t * (3 - 2 * t)
    }

    private func updateGrowth(now: TimeInterval) {
        // Growth is read when drawn; nothing to step. A koi carries its
        // size in its body, eased so a feeding is seen to swell it.
        for l in live {
            guard let k = l.koi else { continue }
            k.bodyScale += (l.placed.size - k.bodyScale) * 0.02
        }
    }

    /// A flowering plant lets a petal go every `petalMinutes` of real time,
    /// up to the cap on the water.
    private func updatePetals(now: TimeInterval) {
        let date = Date()
        for l in live where l.item.shedsPetals && grown(l, now: date) > 0.9 {
            if l.nextPetalAt == nil { l.nextPetalAt = date.addingTimeInterval(PlotTuning.petalMinutes * 60) }
            guard let at = l.nextPetalAt, date >= at else { continue }
            l.nextPetalAt = date.addingTimeInterval(PlotTuning.petalMinutes * 60)
            shedPetal(from: l)
        }
    }

    /// The petals that fell while the player was away, as many as the time
    /// allows and the water will hold.
    private func catchUpPetals(since last: Date) {
        let minutes = Date().timeIntervalSince(last) / 60
        guard minutes > PlotTuning.petalMinutes else { return }
        let date = Date()
        for l in live where l.item.shedsPetals && grown(l, now: date) > 0.9 {
            let n = min(6, Int(minutes / PlotTuning.petalMinutes))
            for _ in 0..<n { shedPetal(from: l) }
        }
    }

    private func shedPetal(from l: LiveItem) {
        guard petalsAfloat.count < PlotTuning.maxFloatingPetals else { return }
        guard let p = wetPoint(near: l.placed.position, from: 24, to: 90) else { return }
        let d = makeFloater(sprite: art.petalParticle, at: p, radius: 8, light: true)
        petalsAfloat.append(d)
        garden.splashes.append((p, 6, -0.08))
        noteChange()
    }

    /// A point on the water near another, between two reaches, or nil if
    /// no water lies that close.
    private func wetPoint(near c: CGPoint, from lo: CGFloat, to hi: CGFloat) -> CGPoint? {
        for _ in 0..<24 {
            let a = CGFloat.random(in: 0...(2 * .pi))
            let r = CGFloat.random(in: lo...hi)
            let p = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
            guard p.x > 10, p.y > 10, p.x < viewSize.width - 10, p.y < viewSize.height - 10 else { continue }
            if depth(at: p) > 0.16 { return p }
        }
        return nil
    }

    private func makeFloater(sprite: String, at p: CGPoint, radius: CGFloat, light: Bool) -> Debris {
        let d = Debris(id: nextFloaterID, cls: light ? .light : .heavy, sprite: sprite, position: p, radius: radius, scale: 1)
        nextFloaterID += 1
        return d
    }

    /// A tap near a petal on the water takes it.
    private func collectPetal(near p: CGPoint) -> Bool {
        guard let i = petalsAfloat.indices.min(by: {
            hypot(petalsAfloat[$0].position.x - p.x, petalsAfloat[$0].position.y - p.y)
                < hypot(petalsAfloat[$1].position.x - p.x, petalsAfloat[$1].position.y - p.y)
        }) else { return false }
        let d = petalsAfloat[i]
        guard hypot(d.position.x - p.x, d.position.y - p.y) < 26 else { return false }
        petalsAfloat.remove(at: i)
        inventory.addPetals(1)
        renderer?.addSplat(at: d.position, in: viewSize, radius: 5, amplitude: -0.06)
        sound.plop()
        haptics.plop()
        noteChange()
        return true
    }

    /// The bowl tapped: pellets scatter on the water near it and the fish
    /// are called to them.
    private func feedFish(from bowl: LiveItem) {
        var any = false
        for _ in 0..<8 {
            guard pellets.count < 24, let p = wetPoint(near: bowl.placed.position, from: 30, to: 120) else { continue }
            let d = makeFloater(sprite: PlotArt.first(of: ["pellet", "mote"]), at: p, radius: 4, light: true)
            pellets.append(d)
            garden.splashes.append((p, 3, -0.04))
            any = true
        }
        if any {
            sound.tap(x: Float(bowl.placed.position.x / viewSize.width), weight: 0.2)
            haptics.tap(weight: 0.3)
        } else {
            haptics.tap(weight: 0.2)
        }
    }

    /// The koi and the pellets. While pellets lie on the water the nearest
    /// one to a koi calls the fish the way a finger does, and a pellet under
    /// any koi's mouth is taken with a gulp: the feeding that counts grows
    /// the fish. A charged finger on the water calls them itself, and wins
    /// over the food while it is down.
    private func updateFish(dt: Float, now: TimeInterval) {
        let koi = live.compactMap(\.koi)
        // A finger calling: the touches route their charge in `updateTouches`.
        let fingerCalling = touches.values.contains { if case .water(let t) = $0 { return t.calling }; return false }
        if !fingerCalling, !pellets.isEmpty, !koi.isEmpty {
            // The pellet nearest any koi's mouth is the one called to.
            var best: Debris?
            var bestD: CGFloat = .greatestFiniteMagnitude
            for p in pellets {
                for k in koi {
                    let d = hypot(p.position.x - k.headPoint.x, p.position.y - k.headPoint.y)
                    if d < bestD { bestD = d; best = p }
                }
            }
            if let p = best {
                garden.callKoi(at: p.position, charge: 1, dt: dt, stop: 6)
                pelletCall = true
            }
        } else if pelletCall {
            garden.releaseCall()
            pelletCall = false
        }
        // A pellet under a mouth is taken.
        for k in koi where !pellets.isEmpty && k.depth < 0.6 {
            let head = k.headPoint
            guard let i = pellets.firstIndex(where: { hypot($0.position.x - head.x, $0.position.y - head.y) < 16 }) else { continue }
            let p = pellets.remove(at: i)
            renderer?.addSplat(at: p.position, in: viewSize, radius: 6, amplitude: -0.1)
            sound.gulp(x: Float(p.position.x / viewSize.width))
            haptics.gulp()
            if pelletCall { garden.releaseCall(); pelletCall = false }
            guard let l = live.first(where: { $0.koi === k }) else { continue }
            let date = Date()
            if let last = l.placed.fedAt, date.timeIntervalSince(last) < PlotTuning.feedHours * 3600 {
                // Fed again too soon: eaten, not grown.
            } else {
                l.placed.fedAt = date
                l.placed.size = min(PlotTuning.koiMaxSize, l.placed.size + PlotTuning.growPerFeed)
            }
            noteChange()
        }
    }

    // MARK: - The weather

    /// The breeze changes its mind every twenty seconds and eases there;
    /// a thrown gust marches its line of water across the pond.
    private func updateWeather(dt: Float, now: TimeInterval) {
        if elapsed > nextBreezeAt {
            nextBreezeAt = elapsed + 20
            let a = Float.random(in: 0...(2 * .pi))
            breezeTarget = SIMD2(cos(a), sin(a)) * Float.random(in: 6...18)
        }
        breeze += (breezeTarget - breeze) * min(1, dt * 0.25)

        guard var g = gust, let renderer else { return }
        g.age += dt
        let t = min(1, g.age / GameTuning.gustSeconds)
        let along = g.length * CGFloat(t)
        let mid = CGPoint(x: g.origin.x + CGFloat(g.direction.x) * along, y: g.origin.y + CGFloat(g.direction.y) * along)
        let perp = SIMD2(-g.direction.y, g.direction.x)
        let across = abs(perp.x) * Float(viewSize.width) + abs(perp.y) * Float(viewSize.height)
        let n = GameTuning.gustSplatsPerFrame
        let body = sin(Float.pi * t)
        if g.age <= GameTuning.gustSeconds {
            for i in 0..<n {
                let f = (Float(i) / Float(n - 1) - 0.5) * across
                let at = CGPoint(x: mid.x + CGFloat(perp.x * f), y: mid.y + CGFloat(perp.y * f))
                if isWater(at) {
                    renderer.addSplat(at: at, in: viewSize, radius: GameTuning.gustRadius,
                                      amplitude: GameTuning.gustAmplitude * (0.55 + 0.45 * body))
                }
            }
        }
        for s in snow { s.blow(dx: CGFloat(g.direction.x * 70 * dt), dy: CGFloat(g.direction.y * 70 * dt)) }
        garden.blow(direction: g.direction, strength: 70 * dt)
        // The sails keep the push a while after the line has crossed.
        gust = g.age >= 1.4 ? nil : g
    }

    /// What pushes on a sail this frame, as acceleration: the breeze as a
    /// steady lean, a gust as a shove that fades.
    private func windNow() -> SIMD2<Float> {
        var w = breeze * GameTuning.lightDrag
        if let g = gust {
            let fade = max(0, 1 - g.age / 1.4)
            w += g.direction * 380 * fade
        }
        return w
    }

    /// Two fast fingers going the same way over the water throw a gust.
    private func gustPair(now: TimeInterval) -> (ids: [Int], direction: SIMD2<Float>)? {
        var fast: [(Int, SIMD2<Float>)] = []
        for (id, role) in touches {
            guard case .water(let t) = role, t.isWake, !t.spent, let h = t.heading,
                  t.speed > GameTuning.gustSpeed, now - t.lastAt < 0.12 else { continue }
            fast.append((id, h))
        }
        guard fast.count >= 2 else { return nil }
        for i in 0..<fast.count {
            for j in (i + 1)..<fast.count {
                let a = fast[i].1, b = fast[j].1
                guard acos(max(-1, min(1, simd_dot(a, b)))) <= GameTuning.gustAngle else { continue }
                return ([fast[i].0, fast[j].0], simd_normalize(a + b))
            }
        }
        return nil
    }

    private func startGust(direction: SIMD2<Float>, ids: [Int], now: TimeInterval) {
        lastGustAt = now
        for id in ids {
            guard case .water(var t)? = touches[id] else { continue }
            if t.sounding { sound.holdEnd(id: id); t.sounding = false }
            if t.isWake { sound.wakeEnd(id: id) }
            t.spent = true
            t.isWake = false
            touches[id] = .water(t)
            renderer?.cancelHold(id: id)
        }
        haptics.slideEnd()
        let w = Float(viewSize.width), h = Float(viewSize.height)
        let centre = SIMD2(w / 2, h / 2)
        let span = abs(direction.x) * w + abs(direction.y) * h
        let start = centre - direction * (span / 2 + 40)
        gust = Gust(direction: direction, origin: CGPoint(x: CGFloat(start.x), y: CGFloat(start.y)), length: CGFloat(span + 80))
        garden.blow(direction: direction, strength: 90)
        for s in snow { s.blow(dx: CGFloat(direction.x * 90), dy: CGFloat(direction.y * 90)) }
        // The reeds and blossom on the bank lean after it.
        for l in live { l.swayVel += direction.x * 2.2 }
        sound.gust(x: 0.5)
        haptics.swell()
    }

    /// The toys with something of their own: the tea bowl fills from the
    /// waves that pass it, like the bamboo, and tips when it is full.
    private func updateToys(dt: Float) {
        for l in live where !l.lifted {
            guard case .feature(let kind) = l.item.art, kind == "bowl", let d = l.body else { continue }
            l.tip = max(0, l.tip - dt * 1.6)
            let over = abs(d.height) - 0.02
            if over > 0 { l.fill = min(1, l.fill + over * 30 * dt) }
            if l.fill >= 1 {
                l.fill = 0
                l.tip = 1
                renderer?.addSplat(at: d.position, in: viewSize, radius: 10, amplitude: -0.14)
                garden.burstDroplets(at: d.position, power: 0.3)
                sound.spill(x: Float(d.position.x / viewSize.width))
                haptics.plop()
            }
        }
    }

    /// Snow when its item is on, fireflies after dusk when theirs is.
    private func updateSky(dt: Float, dark: Bool) {
        if state.sky.contains("snow") {
            snowAccumulator += 1.2 * dt
            while snowAccumulator >= 1, snow.count < 90 {
                snowAccumulator -= 1
                let f = FallingPetal(x: CGFloat.random(in: 0...viewSize.width), y: -20, texture: PlotArt.first(of: ["snow_2", "snow_1", "mote"]))
                f.scale *= 0.55
                snow.append(f)
            }
            snowAccumulator = min(snowAccumulator, 1)
        }
        for f in snow {
            f.update(dt: dt)
            if !f.landed, f.y > viewSize.height * CGFloat.random(in: 0.35...0.9) {
                f.land()
                let p = CGPoint(x: f.x, y: f.y)
                if isWater(p) { renderer?.addSplat(at: p, in: viewSize, radius: 5, amplitude: -0.04) }
            }
        }
        snow.removeAll { $0.dead }

        if state.sky.contains("fireflies"), dark {
            while fireflies.count < 12 {
                fireflies.append(Firefly(position: CGPoint(x: CGFloat.random(in: 40...(viewSize.width - 40)),
                                                           y: CGFloat.random(in: 60...(viewSize.height - 60))),
                                         drift: CGVector(dx: CGFloat.random(in: -12...12), dy: CGFloat.random(in: -8...8)),
                                         phase: Float.random(in: 0...(2 * .pi))))
            }
        } else if !fireflies.isEmpty {
            fireflies.removeLast()
        }
        for i in fireflies.indices {
            fireflies[i].phase += dt * 1.3
            var p = fireflies[i].position
            p.x += (fireflies[i].drift.dx + CGFloat(sin(fireflies[i].phase * 0.7)) * 10) * CGFloat(dt)
            p.y += (fireflies[i].drift.dy + CGFloat(cos(fireflies[i].phase * 0.5)) * 8) * CGFloat(dt)
            if p.x < 20 || p.x > viewSize.width - 20 { fireflies[i].drift.dx *= -1 }
            if p.y < 20 || p.y > viewSize.height - 20 { fireflies[i].drift.dy *= -1 }
            fireflies[i].position = p
        }
    }

    // MARK: - Placing

    /// Where an item would go if dropped at `p`, by its placement, or nil
    /// when it may not go there.
    private func placementPoint(for item: CatalogueItem, at p: CGPoint) -> CGPoint? {
        guard let dig, p.x > 8, p.y > 8, p.x < viewSize.width - 8, p.y < viewSize.height - 8 else { return nil }
        let d = depth(at: p)
        switch item.placement {
        case .bank:
            guard d < PlotController.dryLine, let shore = dig.shorePoint(near: p, within: 60, water: state.water) else { return nil }
            let out = dig.outward(at: shore, water: state.water)
            return CGPoint(x: shore.x + out.dx * 12, y: shore.y + out.dy * 12)
        case .shallows:
            return (0.15...0.6).contains(d) ? p : nil
        case .water, .free:
            return d > 0.2 ? p : nil
        case .anywhere, .sky:
            return p
        }
    }

    /// The thing under the finger is let go.
    private func drop(_ c: Carry, at p: CGPoint) {
        defer { carry = nil }
        // Back on the tray: stored, and no longer on the plot.
        if tray.contains(p) {
            if let l = c.lifted { removeLive(l) }
            sound.paper()
            haptics.tap(weight: 0.3)
            noteChange()
            return
        }
        if c.item.placement == .sky {
            if state.sky.contains(c.item.id) { state.sky.remove(c.item.id) } else { state.sky.insert(c.item.id) }
            garden.mistAmount = state.sky.contains("mist") ? 1.0 : 0.3
            sound.plop()
            haptics.plop()
            noteChange()
            return
        }
        guard let q = placementPoint(for: c.item, at: p) else {
            // Refused: it floats back to where it came from.
            if let l = c.lifted {
                l.lifted = false
                wake(l)
            } else {
                tray.takeBack(c.item, from: p)
                if !tray.open { tray.toggle() }
            }
            haptics.tap(weight: 0.2)
            return
        }
        if let l = c.lifted {
            l.placed.position = q
            l.placed.rotation = c.rotation
            l.placed.scale = c.scale
            l.lifted = false
            wake(l)
            land(l, at: q)
        } else {
            var placed = PlacedItem(item: c.item.id, position: q, rotation: c.rotation, scale: c.scale)
            if c.item.placement == .free { placed.size = 1 }
            let l = LiveItem(placed: placed, item: c.item)
            live.append(l)
            wake(l)
            land(l, at: q)
        }
        noteChange()
    }

    /// The sound and the water of a thing arriving.
    private func land(_ l: LiveItem, at q: CGPoint) {
        let x = Float(q.x / viewSize.width)
        if isWater(q) {
            let heavy = l.item.category == .stone || l.item.category == .wood
            renderer?.addSplat(at: q, in: viewSize, radius: heavy ? 22 : 12, amplitude: heavy ? -0.45 : -0.2)
            garden.burstDroplets(at: q, power: heavy ? 0.8 : 0.4)
            if heavy { sound.dive() } else { sound.tap(x: x, weight: 0.6) }
            haptics.holdRelease(charge: heavy ? 0.8 : 0.4)
        } else {
            sound.clearNote(index: 1, of: 4)
            haptics.tap(weight: 0.5)
        }
    }

    /// A placed thing comes alive: floaters get a body, fish are let go
    /// into the garden as the real koi and shoals a level has.
    private func wake(_ l: LiveItem) {
        l.body = nil
        takeOutOfWater(l)
        let r = l.item.size * 0.5 * l.placed.scale
        switch l.item.category {
        case .wood:
            let d = makeFloater(sprite: "driftwood_1", at: l.placed.position, radius: r, light: false)
            d.angle = CGFloat(l.placed.rotation)
            l.body = d
        case .toy:
            let d = makeFloater(sprite: toySprite(l.item), at: l.placed.position, radius: r, light: true)
            d.angle = CGFloat(l.placed.rotation)
            l.body = d
            if case .feature(let kind) = l.item.art, kind == "boat" {
                l.sail = l.item.id == "sailing-boat" ? 1.0 : 0.6
            }
        case .koi:
            if case .koi(let texture) = l.item.art {
                let k = garden.addKoi(texture: texture, at: l.placed.position, size: l.placed.size)
                l.koi = k
            }
        case .shoal:
            if case .shoal(let texture) = l.item.art {
                l.shoal = garden.addShoal(texture: texture, at: l.placed.position, count: 8)
            }
        default:
            break
        }
        // Stones in the water are rocks the fish go round.
        garden.rocks = live.filter { $0.item.category == .stone && !$0.lifted }.map { ($0.placed.position, $0.item.size * 0.5 * $0.placed.scale) }
    }

    /// The fish a thing let go are taken back out of the garden.
    private func takeOutOfWater(_ l: LiveItem) {
        if let k = l.koi { garden.removeKoi(k); l.koi = nil }
        if let s = l.shoal { garden.removeShoal(s); l.shoal = nil }
    }

    private func removeLive(_ l: LiveItem) {
        live.removeAll { $0 === l }
        takeOutOfWater(l)
        state.placed.removeAll { $0.id == l.placed.id }
        garden.rocks = live.filter { $0.item.category == .stone && !$0.lifted }.map { ($0.placed.position, $0.item.size * 0.5 * $0.placed.scale) }
    }

    private func toySprite(_ item: CatalogueItem) -> String {
        PlotArt.first(of: [Catalogue.icon(for: item) ?? "", "leaf_1", "mote"].filter { !$0.isEmpty })
    }

    /// A finger lifts a placed thing off the plot.
    private func lift(_ l: LiveItem, by id: Int, at p: CGPoint) {
        l.lifted = true
        l.body = nil
        takeOutOfWater(l)
        garden.rocks = live.filter { $0.item.category == .stone && !$0.lifted }.map { ($0.placed.position, $0.item.size * 0.5 * $0.placed.scale) }
        carry = Carry(item: l.item, lifted: l, position: p, rotation: l.placed.rotation, scale: l.placed.scale, fingerID: id)
        touches[id] = .carrying
        sound.paper()
        haptics.holdRelease(charge: 0.5)
    }

    /// The placed thing under a point, if one is.
    private func liveItem(at p: CGPoint) -> LiveItem? {
        var best: LiveItem?
        var bestD: CGFloat = .greatestFiniteMagnitude
        // Fish are let go, not put down: they are not lifted back out.
        for l in live where !l.lifted && l.item.category != .koi && l.item.category != .shoal {
            let reach = max(22, l.item.size * 0.5 * l.placed.scale)
            let d = hypot(l.placed.position.x - p.x, l.placed.position.y - p.y)
            if d < reach, d < bestD { bestD = d; best = l }
        }
        return best
    }

    /// A floater is kept out of the pads and the stones.
    private func keepOffWalls(_ d: Debris) {
        for l in live where !l.lifted && (l.item.category == .stone || l.item.category == .aquaticPlant) {
            let r = l.item.size * 0.5 * l.placed.scale * 0.9 + d.radius * 0.6
            let dx = d.position.x - l.placed.position.x, dy = d.position.y - l.placed.position.y
            let dist = hypot(dx, dy)
            guard dist < r, dist > 0.01 else { continue }
            d.position = CGPoint(x: l.placed.position.x + dx / dist * r, y: l.placed.position.y + dy / dist * r)
            let n = SIMD2(Float(dx / dist), Float(dy / dist))
            let into = simd_dot(d.velocity, n)
            if into < 0 { d.velocity -= n * into * 1.4 }
        }
    }

    // MARK: - Saving

    private func noteChange() {
        saveAt = CACurrentMediaTime() + 2
    }

    private func save() {
        saveAt = nil
        guard placed, let dig else { return }
        for l in live where !l.lifted {
            if let i = state.placed.firstIndex(where: { $0.id == l.placed.id }) {
                // A fish is saved where it swims, a shoal where its middle is.
                if let k = l.koi { l.placed.position = k.position }
                if let c = l.shoal?.centroid { l.placed.position = c }
                state.placed[i] = l.placed
            } else {
                state.placed.append(l.placed)
            }
        }
        state.petals = petalsAfloat.map(\.position)
        state.sluiceOpen = sluice == .filling
        state.lastVisit = Date()
        dig.encode(into: &state)
        progress.savePlot(state, index: plotIndex)
    }

    // MARK: - Menus over the plot

    private func present(_ screen: MenuScreen, from screen0: CGPoint?) {
        letGoOfEverything()
        if viewSize != .zero {
            let at = screen0.map { worldPoint($0) } ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
            if isWater(at) { renderer?.addSplat(at: at, in: viewSize, radius: 90, amplitude: -0.09) }
        }
        sound.plop()
        haptics.swell()
        withAnimation(Motion.scrim) { presented = screen }
    }

    func openSettings(from screen: CGPoint? = nil) { present(.settings, from: screen) }

    func closeMenu() {
        guard presented != nil else { return }
        sound.holdRelease(charge: 0.25)
        haptics.holdRelease(charge: 0.25)
        withAnimation(Motion.leave) { presented = nil }
    }

    // MARK: - Touch

    private func worldPoint(_ p: CGPoint) -> CGPoint { renderer?.worldPoint(screen: p) ?? p }

    func touchBegan(id: Int, at screen: CGPoint, in size: CGSize, weight: Float) {
        screenSize = size
        guard presented == nil, placed, let renderer else { return }
        let now = CACurrentMediaTime()
        lastTouchAt = now
        screenTouches[id] = screen
        let p = worldPoint(screen)

        // A second finger while one thing is held: the pair turns and sizes it.
        if pair == nil, let other = screenTouches.keys.first(where: { $0 != id }), let op = screenTouches[other] {
            var target: LiveItem?
            var rot: Float = 0, sc: CGFloat = 1
            if let c = carry, c.fingerID == other {
                target = c.lifted
                rot = c.rotation
                sc = c.scale
            } else if case .hold(let l, _, _)? = touches[other] {
                target = l
                rot = l.placed.rotation
                sc = l.placed.scale
                touches[other] = .hold(item: l, began: .infinity, start: op)
            }
            if target != nil || (carry?.fingerID == other) {
                pair = Pair(ids: [other, id], target: target,
                            startAngle: Float(atan2(screen.y - op.y, screen.x - op.x)),
                            startDistance: max(1, hypot(screen.x - op.x, screen.y - op.y)),
                            rotation0: rot, scale0: sc)
                touches[id] = .idle
                return
            }
            // A second finger beside one on the water may be a pinch or a
            // tilt. It is watched from here; what it is gets decided as it
            // moves, and until then it works the water like the first.
            if cameraPair == nil, case .water? = touches[other], isWater(p) {
                let mid = CGPoint(x: (op.x + screen.x) / 2, y: (op.y + screen.y) / 2)
                let anchor = worldPoint(mid)
                cameraPair = CameraPair(ids: [other, id], startDistance: hypot(op.x - screen.x, op.y - screen.y),
                                        startZoom: renderer.zoom, anchorWorld: SIMD2(Float(anchor.x), Float(anchor.y)),
                                        last: [other: op, id: screen], lastAt: now)
            }
        }

        if let item = tray.item(at: p) {
            touches[id] = .tray(item: item, start: p, last: p, decided: false)
            return
        }
        if tray.contains(p) {
            touches[id] = .tray(item: nil, start: p, last: p, decided: false)
            return
        }
        if hypot(p.x - trayStonePoint.x, p.y - trayStonePoint.y) < 34 {
            touches[id] = .trayStone(began: now)
            return
        }
        if hypot(p.x - sluicePoint.x, p.y - sluicePoint.y) < 38 {
            touches[id] = .sluice(began: now, acted: false)
            haptics.tap(weight: 0.3)
            return
        }
        if collectPetal(near: p) {
            touches[id] = .idle
            return
        }
        if let l = liveItem(at: p) {
            touches[id] = .hold(item: l, began: now, start: p)
            return
        }
        if isWater(p) {
            renderer.touchDown(id: id, at: p, in: viewSize, weight: weight)
            sound.tap(x: Float(p.x / viewSize.width), weight: weight)
            haptics.tap(weight: weight)
            garden.startle(at: p, in: viewSize)
            sound.holdBegin(id: id)
            touches[id] = .water(WaterTouch(last: p, lastAt: now, sounding: true))
        } else {
            touches[id] = .dig(DigStroke(last: p, lastAt: now))
            haptics.slideBegin()
            digStamp(from: p, to: p, stroke: &touches[id])
        }
    }

    func touchMoved(id: Int, to screen: CGPoint, in size: CGSize) {
        guard presented == nil, placed, let renderer else { return }
        screenTouches[id] = screen
        let now = CACurrentMediaTime()
        let p = worldPoint(screen)
        if var pr = pair, pr.ids.contains(id) {
            updatePair(&pr)
            pair = pr
            return
        }
        if let cp = cameraPair, cp.ids.contains(id) {
            updateCameraPair(id: id, now: now)
            if cameraPair?.active == true || cameraPair?.tilting == true { return }
        }
        guard let role = touches[id] else { return }
        switch role {
        case .dig(var s):
            let step = hypot(p.x - s.last.x, p.y - s.last.y)
            let dtS = max(1.0 / 240, now - s.lastAt)
            s.speed += (Float(step / CGFloat(dtS)) - s.speed) * 0.4
            s.lastAt = now
            touches[id] = .dig(s)
            digStamp(from: s.last, to: p, stroke: &touches[id])
            if case .dig(var t) = touches[id]! {
                t.last = p
                t.sinceGrain += step
                // Earth thrown up now and then along the stroke.
                if t.sinceGrain > 18 {
                    t.sinceGrain = 0
                    throwGrains(at: p, count: 3)
                }
                if now > t.nextVoiceAt, step > 0.5 {
                    t.nextVoiceAt = now + 0.11
                    sound.clearNote(index: Int.random(in: 0...2), of: 6)
                }
                haptics.slide(speed: t.speed, grain: 0.9, travel: Float(step))
                touches[id] = .dig(t)
            }
            noteChange()
        case .water(var t):
            guard !t.spent else { t.last = p; t.lastAt = now; touches[id] = .water(t); return }
            let step = hypot(p.x - t.last.x, p.y - t.last.y)
            let dtS = max(1.0 / 240, now - t.lastAt)
            t.speed += (Float(step / CGFloat(dtS)) - t.speed) * 0.4
            if step > 1.5 { t.heading = simd_normalize(SIMD2(Float(p.x - t.last.x), Float(p.y - t.last.y))) }
            if !t.isWake, t.speed > GameTuning.wakeSpeed {
                t.isWake = true
                renderer.cancelHold(id: id)
                if t.sounding { sound.holdEnd(id: id); t.sounding = false }
                sound.wakeBegin(id: id)
                haptics.slideBegin()
            }
            if t.isWake {
                let strength = min(1.6, max(0.35, t.speed / GameTuning.wakeFullSpeed))
                sound.wakeLevel(id: id, speed: t.speed)
                haptics.slide(speed: t.speed, grain: 0.1, travel: Float(step))
                t.sinceSplat += step
                if t.sinceSplat >= GameTuning.wakeSpacing {
                    let n = min(Int(t.sinceSplat / GameTuning.wakeSpacing), 6)
                    t.sinceSplat -= CGFloat(n) * GameTuning.wakeSpacing
                    for i in 1...n {
                        let f = CGFloat(i) / CGFloat(n)
                        let q = CGPoint(x: t.last.x + (p.x - t.last.x) * f, y: t.last.y + (p.y - t.last.y) * f)
                        if isWater(q) { renderer.addSplat(at: q, in: viewSize, radius: GameTuning.wakeRadius, amplitude: GameTuning.wakeAmplitude * strength) }
                    }
                    garden.startle(at: p, in: viewSize)
                }
            } else {
                renderer.touchMoved(id: id, to: p, in: viewSize)
            }
            t.last = p
            t.lastAt = now
            touches[id] = .water(t)
            // Two fingers thrown the same way over the water are a gust.
            if gust == nil, now - lastGustAt > GameTuning.gustCooldown, cameraPair?.active != true,
               let g = gustPair(now: now) {
                cameraPair = nil
                startGust(direction: g.direction, ids: g.ids, now: now)
            }
        case .sluice(let began, let acted):
            // Slid off the stone: it was not a press on it.
            if hypot(p.x - sluicePoint.x, p.y - sluicePoint.y) > 46 { touches[id] = .idle }
            else { touches[id] = .sluice(began: began, acted: acted) }
        case .trayStone:
            if hypot(p.x - trayStonePoint.x, p.y - trayStonePoint.y) > 46 { touches[id] = .idle }
        case .tray(let item, let start, let last, let decided):
            if !decided {
                let dx = p.x - start.x, dy = p.y - start.y
                guard hypot(dx, dy) > 10 else { return }
                if let item, abs(dy) > abs(dx) {
                    // Up off the tray: the thing comes with the finger.
                    carry = Carry(item: item, lifted: nil, position: p, rotation: 0, scale: 1, fingerID: id)
                    touches[id] = .carrying
                    sound.paper()
                    haptics.tap(weight: 0.3)
                    return
                }
                touches[id] = .tray(item: item, start: start, last: p, decided: true)
                tray.scroll(by: p.x - start.x)
                return
            }
            tray.scroll(by: p.x - last.x)
            touches[id] = .tray(item: item, start: start, last: p, decided: true)
        case .carrying:
            carry?.position = p
        case .hold(let l, let began, let start):
            // Moved off before the press took: the finger is doing something
            // else, whatever the ground under it says.
            if began != .infinity, hypot(p.x - start.x, p.y - start.y) > 12 {
                touches.removeValue(forKey: id)
                _ = l
                touchBeganOnGround(id: id, at: p, now: now)
            }
        case .idle:
            break
        }
    }

    /// A finger that slid off a thing it was resting on: from here it digs
    /// or works the water, as it would have from the start.
    private func touchBeganOnGround(id: Int, at p: CGPoint, now: TimeInterval) {
        guard let renderer else { return }
        if isWater(p) {
            renderer.touchDown(id: id, at: p, in: viewSize, weight: 0.5, ring: false)
            sound.holdBegin(id: id)
            touches[id] = .water(WaterTouch(last: p, lastAt: now, sounding: true))
        } else {
            touches[id] = .dig(DigStroke(last: p, lastAt: now))
            haptics.slideBegin()
        }
    }

    func touchEnded(id: Int, at screen: CGPoint, in size: CGSize) {
        screenTouches.removeValue(forKey: id)
        let now = CACurrentMediaTime()
        let p = worldPoint(screen)
        // A pair breaks up: the other finger goes on holding or carrying,
        // and this one is seen through to whatever it was doing.
        if let pr = pair, pr.ids.contains(id) { pair = nil }
        if let cp = cameraPair, cp.ids.contains(id) { cameraPair = nil }
        guard let role = touches.removeValue(forKey: id) else { return }
        guard presented == nil, let renderer else { return }
        switch role {
        case .dig:
            haptics.slideEnd()
            noteChange()
        case .water(let t):
            if t.sounding { sound.holdEnd(id: id) }
            if t.isWake { sound.wakeEnd(id: id); haptics.slideEnd() }
            if t.calling { garden.releaseCall() }
            renderer.touchUp(id: id)
        case .sluice(let began, let acted):
            guard !acted else { return }
            if now - began < 0.45 {
                switch sluice {
                case .closed: openSluice()
                case .filling, .draining: closeSluice()
                }
            }
        case .trayStone(let began):
            if now - began < 0.6 {
                tray.toggle()
                sound.wood(x: Float(trayStonePoint.x / viewSize.width))
                haptics.tap(weight: 0.6)
            }
        case .tray(let item, _, _, let decided):
            if !decided, let item, item.placement == .sky {
                // The sky things are switched on from the tray with a tap.
                state.sky.insert(item.id)
                garden.mistAmount = state.sky.contains("mist") ? 1.0 : 0.3
                sound.plop()
                haptics.plop()
                noteChange()
            }
        case .carrying:
            if let c = carry, c.fingerID == id { drop(c, at: p) }
        case .hold(let l, let began, _):
            if began != .infinity, now - began < 0.45 {
                // A tap on the bowl feeds the fish; on anything else, a nudge.
                if l.item.id == "food-bowl" { feedFish(from: l) }
                else { l.swayVel += Float.random(in: -1.5...1.5); haptics.tap(weight: 0.3) }
            }
        case .idle:
            break
        }
    }

    /// Presses that take time: a long press on a placed thing lifts it, a
    /// long press on the sluice lets the water out.
    private func updateTouches(now: TimeInterval, dt: Float) {
        for (id, role) in touches {
            switch role {
            case .water(var t):
                // The swell under a still finger is heard building, and a
                // charged finger calls the nearest koi up to it, as in a level.
                guard let r = renderer else { continue }
                let charge = r.charge(of: id)
                if t.sounding { sound.holdLevel(id: id, charge: charge) }
                if !t.isWake, !t.spent, charge > 0.15 {
                    if !t.calling, pelletCall { garden.releaseCall(); pelletCall = false }
                    t.calling = true
                    garden.callKoi(at: t.last, charge: charge, dt: dt)
                    touches[id] = .water(t)
                }
            case .hold(let l, let began, let start):
                if began != .infinity, now - began > 0.5 {
                    lift(l, by: id, at: start)
                }
            case .sluice(let began, let acted):
                if !acted, now - began > 0.7 {
                    drainSluice()
                    touches[id] = .sluice(began: began, acted: true)
                }
            default:
                break
            }
        }
    }

    private func updatePair(_ pr: inout Pair) {
        guard let a = screenTouches[pr.ids[0]], let b = screenTouches[pr.ids[1]] else { return }
        let angle = Float(atan2(b.y - a.y, b.x - a.x))
        let dist = max(1, hypot(b.x - a.x, b.y - a.y))
        var rot = pr.rotation0 + (angle - pr.startAngle)
        while rot > .pi { rot -= 2 * .pi }
        while rot < -.pi { rot += 2 * .pi }
        let item = pr.target?.item ?? carry?.item
        let range = item?.sizeRange ?? 0.8...1.2
        let sc = min(range.upperBound, max(range.lowerBound, pr.scale0 * dist / pr.startDistance))
        if let c = carry, c.fingerID == pr.ids[0] {
            c.rotation = rot
            c.scale = sc
        } else if let l = pr.target {
            l.placed.rotation = rot
            l.placed.scale = sc
            l.body?.angle = CGFloat(rot)
            noteChange()
        }
    }

    /// Two fingers on the water: a drag the same way tilts the camera, a
    /// spread or a squeeze zooms it, read leniently as in a level. Until
    /// one is decided the fingers go on working the water.
    private func updateCameraPair(id: Int, now: TimeInterval) {
        guard var p = cameraPair, p.ids.contains(id),
              let a = screenTouches[p.ids[0]], let b = screenTouches[p.ids[1]], let r = renderer else { return }
        let here = id == p.ids[0] ? a : b
        var step = CGPoint.zero
        if let was = p.last[id] {
            step = CGPoint(x: here.x - was.x, y: here.y - was.y)
            var t = p.travel[id] ?? .zero
            t.x += step.x
            t.y += step.y
            p.travel[id] = t
        }
        p.last[id] = here
        p.lastAt = now
        let dist = hypot(a.x - b.x, a.y - b.y)

        if !p.active, !p.tilting, let ta = p.travel[p.ids[0]], let tb = p.travel[p.ids[1]] {
            let mid = CGPoint(x: (ta.x + tb.x) / 2, y: (ta.y + tb.y) / 2)
            let sameWay = ta.y * tb.y > 0
            let upright = abs(mid.y) > (abs(mid.x) + abs(mid.y)) * GameTuning.tiltUpright
            let held = abs(dist - p.startDistance) < GameTuning.tiltSpread
            if sameWay, upright, held, hypot(mid.x, mid.y) > GameTuning.tiltTravel {
                p.tilting = true
                forgetWaterTouches(p.ids)
            }
        }
        if p.tilting {
            // Half the step from each of the two fingers is their average.
            // Drawn up the screen the camera lies down toward the water.
            r.pitchTarget -= Float(step.y) * 0.5 * GameTuning.tiltPerPoint
            cameraPair = p
            return
        }
        if !p.active {
            guard abs(dist - p.startDistance) > 18 else { cameraPair = p; return }
            // Two fingers thrown the same way are a gust, not a pinch.
            if gustPair(now: now) != nil { cameraPair = p; return }
            p.active = true
            forgetWaterTouches(p.ids)
        }
        let z = max(GameTuning.zoomMin, min(GameTuning.zoomMax, p.startZoom * Float(dist / max(1, p.startDistance))))
        zoomTarget = z
        // Keep the world point that was under the fingers under them.
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        centreTarget = p.anchorWorld - SIMD2(Float(mid.x - screenSize.width / 2), Float(mid.y - screenSize.height / 2)) / z
        cameraPair = p
    }

    /// Fingers that turned out to belong to the camera and not the water:
    /// their holds, their wakes and their voices all go.
    private func forgetWaterTouches(_ ids: [Int]) {
        for id in ids {
            guard case .water(let t)? = touches[id] else { continue }
            if t.sounding { sound.holdEnd(id: id) }
            if t.isWake { sound.wakeEnd(id: id); haptics.slideEnd() }
            if t.calling { garden.releaseCall() }
            renderer?.cancelHold(id: id)
            touches[id] = .idle
        }
    }

    /// The spade along a step of the stroke.
    private func digStamp(from a: CGPoint, to b: CGPoint, stroke: inout Role?) {
        guard let dig else { return }
        guard case .dig(var s)? = stroke else { return }
        // Stamps are laid at even spacing across the steps of the stroke,
        // carrying the remainder from one step to the next.
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        var points: [CGPoint] = []
        if len < 0.01 {
            points = [a]
        } else {
            var t = s.carried
            while t <= len {
                points.append(CGPoint(x: a.x + dx * t / len, y: a.y + dy * t / len))
                t += DigField.stampSpacing
            }
            s.carried = t - len
        }
        for q in points { dig.dig(along: [q]) }
        stroke = .dig(s)
    }

    private func throwGrains(at p: CGPoint, count: Int) {
        guard grains.count < 120 else { return }
        for _ in 0..<count {
            let a = CGFloat.random(in: 0...(2 * .pi))
            let out = CGFloat.random(in: 14...50)
            grains.append(Grain(at: p, velocity: CGVector(dx: cos(a) * out, dy: sin(a) * out * 0.75),
                                up: CGFloat.random(in: 50...120), size: CGFloat.random(in: 3...6)))
        }
    }

    // MARK: - Drawing

    private func feed(_ renderer: WaterRenderer) {
        renderer.camera = garden.camera
        renderer.siltCovers = []
        // Pads and the heavy floaters turn ripples.
        var walls: [(centre: CGPoint, radius: CGFloat)] = []
        for l in live where !l.lifted {
            if l.item.category == .aquaticPlant { walls.append((l.placed.position, l.item.size * 0.5 * l.placed.scale * grown(l) * 0.9)) }
            if l.item.category == .stone || l.item.category == .wood { walls.append((l.placed.position, l.item.size * 0.5 * l.placed.scale * 0.8)) }
        }
        renderer.walls = Array(walls.prefix(Tuning.maxWalls))

        var paintings: [String] = []
        func painting(_ name: String) -> UInt32 {
            if let i = paintings.firstIndex(of: name) { return UInt32(i + 1) }
            paintings.append(name)
            return UInt32(paintings.count)
        }
        // The fish, as in a level: the garden lays each koi's spine along
        // the path its head swam and the body bends on it, the shoals go
        // as cut-outs, and both cast their shadows on the bed.
        let submerged = garden.submergedSprites()
        renderer.spines = submerged.spines
        var under = submerged.sprites
        under += garden.reflectionSprites()
        let koiBodies = garden.koiBodies(depthScale: WaterRenderer.depthScale, textureIndex: painting,
                                         tailCentre: { renderer.textures.tailCentre($0) })
        var underBodies = koiBodies.under
        underBodies += garden.bedStoneBodies(depthScale: WaterRenderer.depthScale, mossy: season.id != "winter")
        let t = Double(elapsed)

        // Floaters' shadows on the bed.
        for d in petalsAfloat + pellets + live.compactMap(\.body) {
            let s = spriteSize(d)
            under.append(Sprite(d.sprite, at: CGPoint(x: d.position.x + 7, y: d.position.y + 10), size: s,
                                rotation: Float(d.angle), mode: .shadow, alpha: d.cls == .heavy ? 0.9 : 0.5, z: -1.0))
        }

        var sink = DrawSink()
        sink.solids += koiBodies.surface

        // The two stones the plot is worked with.
        sink.solids.append(stoneBody(at: sluicePoint, radius: 26, colourA: [0.50, 0.53, 0.52, 1], colourB: [0.36, 0.55, 0.30, 1],
                                seed: 3.1, yaw: 0.4, alpha: 1))
        if sluice == .filling {
            // Water pouring over the stone: a bead of a ring at its foot each frame.
            sink.over.append(Sprite("mote", at: CGPoint(x: sluicePoint.x - 20, y: sluicePoint.y + 6 + CGFloat(sin(t * 9)) * 2),
                               size: CGSize(width: 14, height: 8), alpha: 0.5, tint: [1.6, 1.7, 1.8, 1], z: 0.05))
        }
        sink.solids.append(stoneBody(at: trayStonePoint, radius: 20, colourA: [0.56, 0.58, 0.60, 1], colourB: [0.56, 0.58, 0.60, 1],
                                seed: 7.7, yaw: 1.9, alpha: 1))

        // Everything placed.
        let date = Date()
        for l in live where !l.lifted {
            draw(l, grown: grown(l, now: date), sink: &sink, painting: painting)
        }
        // Petals and pellets lying on the water, and the bodies that float.
        for d in petalsAfloat {
            sink.paper(Sprite(d.sprite, at: d.position, size: spriteSize(d), rotation: Float(d.angle), mode: .floater, alpha: 1))
        }
        for d in pellets {
            sink.over.append(Sprite(d.sprite, at: d.position, size: spriteSize(d), rotation: Float(d.angle), mode: .floater, alpha: 0.95,
                               tint: d.sprite == "mote" ? [0.85, 0.66, 0.42, 1] : [1, 1, 1, 1], z: 0.01))
        }
        for l in live where !l.lifted {
            guard let d = l.body else { continue }
            if l.item.category == .wood {
                let body = NaturalSolid.log.body
                let radius = Float(d.radius * body.radius)
                sink.solids.append(SolidInstance(position: SIMD2(Float(d.position.x), Float(d.position.y)),
                                            lift: radius * Float(body.lift), yaw: Float(d.angle), roll: d.roll, tilt: d.slope,
                                            length: Float(d.radius * body.length), radius: radius, shape: body.shape, alpha: 1,
                                            colourA: [0.42, 0.30, 0.20, 1], colourB: [0.78, 0.66, 0.48, 1]))
            } else if l.item.category == .toy {
                drawToy(l, body: d, sink: &sink)
            } else {
                sink.paper(Sprite(d.sprite, at: d.position, size: spriteSize(d), rotation: Float(d.angle), mode: .floater, alpha: 1))
            }
        }
        // Snow on its way down and lying on the water; fireflies in the dark.
        for f in snow {
            sink.over.append(Sprite(f.texture, at: CGPoint(x: f.x, y: f.y), size: CGSize(width: 14 * f.scale, height: 14 * f.scale),
                                    rotation: f.rotation, mode: f.landed ? .floater : .plain, alpha: f.alpha, z: f.landed ? 0 : 0.5))
        }
        for f in fireflies {
            let glow = 0.5 + 0.5 * sin(f.phase * 2.1)
            sink.over.append(Sprite("mote", at: f.position, size: CGSize(width: 9, height: 9), alpha: 0.35 + 0.55 * glow,
                                    tint: [1.0, 0.9, 0.45, 1], z: 0.3))
            sink.over.append(Sprite("mote", at: f.position, size: CGSize(width: 22, height: 22), alpha: 0.18 * glow,
                                    tint: [1.0, 0.8, 0.3, 1], z: 0.29))
        }
        // Earth in the air.
        for g in grains {
            if g.lift > 4 {
                sink.over.append(Sprite("mote", at: g.position, size: CGSize(width: g.size * 0.8, height: g.size * 0.5), mode: .shadow, alpha: 0.25, z: 0.04))
            }
            sink.over.append(Sprite("mote", at: CGPoint(x: g.position.x, y: g.position.y - g.lift), size: CGSize(width: g.size, height: g.size * 0.9),
                               rotation: g.spin, alpha: 0.95, tint: [0.42, 0.31, 0.20, 1], z: 0.5 + Float(g.lift) * 0.002))
        }

        // The tray, its stone's charge, and what lies on it.
        sink.over += tray.woodSprites(textureSize: garden.textureSize, painting: painting, solids: &sink.solids)
        if tray.slide > 0.01 {
            for slot in tray.slots {
                drawIcon(slot.item, at: slot.centre, scale: 1, rotation: 0, z: 0.06, alpha: Float(tray.slide),
                         sink: &sink, painting: painting)
            }
            for r in tray.returning {
                drawIcon(r.item, at: tray.returnPoint(r), scale: 1, rotation: 0, z: 0.3, alpha: 1,
                         sink: &sink, painting: painting)
            }
        }
        // The thing under the finger, held above the plot with its shadow on it.
        if let c = carry {
            let side = c.item.size * c.scale
            sink.over.append(Sprite("mote", at: CGPoint(x: c.position.x + 10, y: c.position.y + 16),
                               size: CGSize(width: side * 0.9, height: side * 0.55), mode: .shadow, alpha: 0.35, z: 0))
            drawIcon(c.item, at: CGPoint(x: c.position.x, y: c.position.y - 14), scale: c.scale, rotation: c.rotation, z: 0.3, alpha: 1,
                     sink: &sink, painting: painting)
        }

        for s in garden.skaterSprites() { sink.paper(s) }
        if sluice == .filling { sink.over += garden.inletSprites() }
        for s in garden.petalSprites() { sink.paper(s) }
        sink.over += garden.dropletSprites()
        sink.over += garden.dripSprites()
        for s in garden.floraSprites() { sink.paper(s, cast: 18) }
        sink.over += garden.skySprites()
        sink.over += garden.moonSprites()
        sink.over += garden.mistSprites()

        renderer.submergedSprites = under
        renderer.submergedSolids = underBodies
        renderer.contactShadows = sink.shadows
        renderer.solids = sink.solids
        renderer.solidTextures = paintings
        renderer.surfaceSprites = sink.over
    }

    /// One placed thing, by its art and its category.
    private func draw(_ l: LiveItem, grown: CGFloat, sink: inout DrawSink, painting: (String) -> UInt32) {
        let p = l.placed.position
        let t = Float(elapsed)
        // Under a third grown a plant is a sprout, whichever plant it is.
        if l.item.growDays > 0, grown < 0.3 {
            let name = "sprout_\(min(3, 1 + Int(grown * 10)))"
            let ts = garden.textureSize(name)
            let h: CGFloat = 26 + 30 * grown / 0.3
            let w = h * ts.width / max(1, ts.height)
            sink.over.append(Sprite(name, at: CGPoint(x: p.x + 4, y: p.y + h * 0.3), size: CGSize(width: w, height: h * 0.5), mode: .shadow, alpha: 0.28, z: 0))
            sink.over.append(Sprite(name, at: p, size: CGSize(width: w, height: h), rotation: -.pi / 2 + l.sway * 0.5, alpha: 1,
                               wave: t * 0.9 + l.phase, z: 0.07, stands: true))
            return
        }
        let scale = l.placed.scale * grown
        switch l.item.art {
        case .sprite(let name, let stands):
            let ts = garden.textureSize(name)
            let w = l.item.size * scale
            let h = w * ts.height / max(1, ts.width)
            if stands {
                sink.over.append(Sprite(name, at: CGPoint(x: p.x + 6, y: p.y + h * 0.35), size: CGSize(width: w, height: h * 0.55),
                                   mode: .shadow, alpha: 0.3, z: 0))
                sink.over.append(Sprite(name, at: p, size: CGSize(width: w, height: h), rotation: -.pi / 2 + l.placed.rotation * 0.3 + l.sway,
                                   alpha: 1, wave: t * 0.9 + l.phase, z: 0.07, stands: true))
            } else if l.item.category == .aquaticPlant {
                // A pad is a thin disc wearing its painting, like a level's.
                let side = max(w, h)
                sink.over.append(Sprite(name, at: CGPoint(x: p.x + 3, y: p.y + 4), size: CGSize(width: side * 1.06, height: side * 1.06),
                                   mode: .shadow, alpha: 0.3, z: 0))
                sink.solids.append(SolidInstance(position: SIMD2(Float(p.x), Float(p.y)), lift: name.hasPrefix("lotus") ? 3.5 : 1.5,
                                            yaw: l.placed.rotation, roll: 0, texture: painting(name), tilt: .zero,
                                            length: 3, radius: Float(side) * 0.5, shape: 4, alpha: 1,
                                            colourA: [0.16, 0.36, 0.22, 1], colourB: [0.16, 0.36, 0.22, 1]))
            } else {
                sink.paper(Sprite(name, at: p, size: CGSize(width: w, height: h), rotation: l.placed.rotation, mode: .floater, alpha: 1))
            }
        case .solid(let shape, let colourA, let colourB, _):
            let r = l.item.size * 0.5 * scale
            if shape == 2 {
                sink.solids.append(stoneBody(at: p, radius: r, colourA: colourA, colourB: colourB,
                                        seed: Float(l.phase) * 10, yaw: l.placed.rotation, alpha: 1))
            } else if l.body == nil {
                sink.solids.append(SolidInstance(position: SIMD2(Float(p.x), Float(p.y)), lift: Float(r) * 0.4, yaw: l.placed.rotation, roll: 0,
                                            tilt: .zero, length: Float(r) * 2, radius: Float(r) * 0.4, shape: shape, alpha: 1,
                                            colourA: colourA, colourB: colourB))
            }
        case .koi, .shoal:
            break
        case .feature(let kind):
            drawFeature(kind, item: l.item, at: p, scale: scale, l: l, sink: &sink, painting: painting)
        }
    }

    private func drawFeature(_ kind: String, item: CatalogueItem, at p: CGPoint, scale: CGFloat, l: LiveItem,
                             sink: inout DrawSink, painting: (String) -> UInt32) {
        let t = Float(elapsed)
        switch kind {
        case "food-bowl":
            if PlotArt.exists("food_bowl") {
                let ts = garden.textureSize("food_bowl")
                let w = item.size * scale, h = w * ts.height / max(1, ts.width)
                sink.over.append(Sprite("food_bowl", at: CGPoint(x: p.x + 3, y: p.y + 4), size: CGSize(width: w, height: h), mode: .shadow, alpha: 0.3, z: 0))
                sink.over.append(Sprite("food_bowl", at: p, size: CGSize(width: w, height: h), rotation: l.placed.rotation, alpha: 1, z: 0.04))
            } else {
                // A clay bowl: a disc the colour of fired earth.
                sink.solids.append(SolidInstance(position: SIMD2(Float(p.x), Float(p.y)), lift: 4, yaw: l.placed.rotation, roll: 0,
                                            tilt: .zero, length: 8, radius: Float(item.size * scale) * 0.5, shape: 4, alpha: 1,
                                            colourA: [0.62, 0.44, 0.30, 1], colourB: [0.62, 0.44, 0.30, 1]))
            }
        case "bamboo":
            let ts = garden.textureSize("bamboo_post")
            let h = item.size * scale
            let w = h * ts.width / max(1, ts.height)
            sink.over.append(Sprite("bamboo_post", at: CGPoint(x: p.x + 6, y: p.y + h * 0.32), size: CGSize(width: w, height: h * 0.5),
                               mode: .shadow, alpha: 0.3, z: 0))
            sink.over.append(Sprite("bamboo_post", at: p, size: CGSize(width: w, height: h), rotation: -.pi / 2 + l.sway * 0.3, alpha: 1,
                               wave: t * 0.4 + l.phase, z: 0, stands: true))
        case "chime":
            // Three stones half out of the water, in a short arc.
            for k in 0..<3 {
                let a = l.placed.rotation + Float(k - 1) * 0.6
                let q = CGPoint(x: p.x + CGFloat(cos(a)) * item.size * 0.3 * scale, y: p.y + CGFloat(sin(a)) * item.size * 0.3 * scale)
                sink.solids.append(stoneBody(at: q, radius: item.size * 0.16 * scale, colourA: [0.56, 0.58, 0.60, 1], colourB: [0.56, 0.58, 0.60, 1],
                                        seed: Float(k) * 3.7 + l.phase, yaw: a, alpha: 1))
            }
        default:
            // Toys float as bodies; a sky feature draws nothing here.
            if l.body == nil, item.placement != .sky {
                let name = toySprite(item)
                let ts = garden.textureSize(name)
                let w = item.size * scale, h = w * ts.height / max(1, ts.width)
                sink.over.append(Sprite(name, at: p, size: CGSize(width: w, height: h), rotation: l.placed.rotation, mode: .floater, alpha: 1, z: 0.02))
            }
        }
    }

    /// A toy on the water: an upright cut-out standing at its body's point,
    /// lifted by the water under it and facing the way it goes. The sailing
    /// boat's sail is a body yawed with the wind, once the art gives it a
    /// hull to stand on; the lantern glows as the light goes; the tea bowl
    /// shows the water it has caught.
    private func drawToy(_ l: LiveItem, body d: Debris, sink: inout DrawSink) {
        let name = d.sprite
        let ts = garden.textureSize(name)
        let w = l.item.size * l.placed.scale
        let h = w * ts.height / max(1, ts.width)
        let p = d.position
        var kind = ""
        if case .feature(let k) = l.item.art { kind = k }
        // A hull painting on its own lets the sail be a body; without one
        // the painted sail stands and the body sail stays away.
        let hullOnly = l.item.id == "sailing-boat" && PlotArt.exists("sail_boat_hull")
        let picture = hullOnly ? "sail_boat_hull" : name
        // Riding the water: the height under it lifts the cut-out.
        let bob = max(0, Float(d.height) * 40 / WaterRenderer.depthScale)
        let squash: CGFloat = kind == "bowl" ? 1 - 0.25 * CGFloat(l.tip) : 1
        sink.over.append(Sprite(picture, at: CGPoint(x: p.x + 5, y: p.y + h * 0.28), size: CGSize(width: w, height: h * 0.45),
                                mode: .shadow, alpha: 0.3, z: 0))
        sink.over.append(Sprite(picture, at: p, size: CGSize(width: w, height: h * squash), rotation: -.pi / 2, alpha: 1,
                                flipX: cos(Double(d.angle)) < 0, wave: Float(elapsed) * 0.9 + l.phase,
                                z: bob + 0.004, stands: true))
        switch kind {
        case "boat" where hullOnly:
            // The sail swings to the lee of the wind, its boom downwind.
            var wind = windNow()
            if simd_length(wind) < 0.5 { wind = SIMD2(cos(Float(d.angle)), sin(Float(d.angle))) }
            let yaw = atan2(wind.y, wind.x)
            sink.solids.append(SolidInstance(position: SIMD2(Float(p.x), Float(p.y)), lift: Float(h) * 0.22 + bob * WaterRenderer.depthScale,
                                             yaw: yaw, roll: 0, tilt: d.slope, length: Float(w) * 0.55, radius: Float(h) * 0.8,
                                             shape: 7, alpha: 1, colourA: [0.96, 0.93, 0.86, 1], colourB: [0.96, 0.93, 0.86, 1]))
        case "lantern":
            // Warm light on the water, more of it the further the day is
            // from noon.
            let noon = 1 - min(1, abs((renderer?.dayPhase ?? 0.5) - 0.5) * 2)
            let glow = (1 - noon) * (0.85 + 0.15 * sin(Float(elapsed) * 5 + l.phase))
            guard glow > 0.02 else { break }
            sink.over.append(Sprite("mote", at: CGPoint(x: p.x, y: p.y + 4), size: CGSize(width: w * 2.6, height: w * 1.7),
                                    mode: .floater, alpha: 0.5 * glow, tint: [1.0, 0.72, 0.36, 1], z: 0.006))
            sink.over.append(Sprite("mote", at: p, size: CGSize(width: w * 1.3, height: w * 1.3),
                                    alpha: 0.45 * glow, tint: [1.0, 0.82, 0.5, 1], z: bob + (h * 0.5).asZ))
        case "bowl":
            if l.fill > 0.05 {
                sink.over.append(Sprite("mote", at: p, size: CGSize(width: w * 0.55 * CGFloat(l.fill), height: w * 0.22 * CGFloat(l.fill)),
                                        alpha: 0.55, tint: [0.35, 0.5, 0.55, 1], z: bob + (h * 0.55).asZ))
            }
        default:
            break
        }
    }

    /// An item's picture, on the tray or under the finger: its sprite, or a
    /// small body for a thing that has none.
    private func drawIcon(_ item: CatalogueItem, at p: CGPoint, scale: CGFloat, rotation: Float, z: Float, alpha: Float,
                          sink: inout DrawSink, painting: (String) -> UInt32) {
        let cap: CGFloat = 54
        switch item.art {
        case .solid(let shape, let colourA, let colourB, _):
            let r = min(cap, item.size) * 0.5 * scale
            if shape == 2 {
                var s = stoneBody(at: p, radius: r, colourA: colourA, colourB: colourB, seed: 2.2, yaw: rotation, alpha: alpha)
                s.lift += z * 40
                sink.solids.append(s)
            } else {
                sink.solids.append(SolidInstance(position: SIMD2(Float(p.x), Float(p.y)), lift: Float(r) * 0.4 + z * 40, yaw: rotation, roll: 0,
                                            tilt: .zero, length: Float(r) * 2, radius: Float(r) * 0.4, shape: shape, alpha: alpha,
                                            colourA: colourA, colourB: colourB))
            }
        default:
            let icon = Catalogue.icon(for: item).flatMap { PlotArt.exists($0) ? $0 : nil }
            let name: String
            switch item.art {
            case .feature(let kind) where kind == "food-bowl": name = icon ?? "seed_1"
            case .feature: name = icon ?? "leaf_1"
            default: name = icon ?? "mote"
            }
            let ts = garden.textureSize(name)
            let long = max(ts.width, ts.height)
            let side = min(cap, item.size) * scale
            let w = side * ts.width / long, h = side * ts.height / long
            var edge = Sprite(name, at: CGPoint(x: p.x + 2.2, y: p.y + 3), size: CGSize(width: w, height: h), rotation: rotation,
                              mode: .floater, alpha: alpha, z: z)
            edge.gpu.mode |= SpriteInstance.ink
            sink.over.append(edge)
            sink.over.append(Sprite(name, at: p, size: CGSize(width: w, height: h), rotation: rotation, mode: .floater, alpha: alpha, z: z))
        }
    }

    private func stoneBody(at p: CGPoint, radius: CGFloat, colourA: SIMD4<Float>, colourB: SIMD4<Float>,
                           seed: Float, yaw: Float, alpha: Float) -> SolidInstance {
        let body = NaturalSolid.stone.body
        let r = Float(radius * body.radius)
        return SolidInstance(position: SIMD2(Float(p.x), Float(p.y)), lift: r * Float(body.lift), yaw: yaw, roll: seed * 64,
                             tilt: .zero, length: Float(radius * body.length), radius: r, shape: body.shape, alpha: alpha,
                             colourA: colourA, colourB: colourB)
    }

    private func spriteSize(_ d: Debris) -> CGSize {
        let s = garden.textureSize(d.sprite)
        let long = max(s.width, s.height)
        let side = d.radius * 2
        return CGSize(width: side * s.width / long, height: side * s.height / long)
    }
}

/// Where a frame's sprites and bodies are gathered before they go to the
/// renderer: the cut-outs over the water, the bodies, and the soft rings
/// under bodies that meet the water.
struct DrawSink {
    var over: [Sprite] = []
    var solids: [SolidInstance] = []
    var shadows: [Sprite] = []

    /// A cut-out of paper: a dark thickness edge just under it, and a
    /// shadow thrown down onto the water if it is held above it.
    mutating func paper(_ s: Sprite, cast: CGFloat = 0) {
        if cast > 0 {
            var sh = s
            sh.gpu.center += SIMD2(Float(cast * 0.7), Float(cast))
            sh.gpu.mode = SpriteInstance.Mode.shadow.rawValue | (s.gpu.mode & SpriteInstance.flipX)
            sh.gpu.alpha = s.gpu.alpha * 0.8
            over.append(sh)
        }
        var edge = s
        edge.gpu.center += SIMD2(2.2, 3.0)
        edge.gpu.mode = s.gpu.mode | SpriteInstance.ink
        over.append(edge)
        over.append(s)
    }
}

// MARK: - What lives on the plot

/// A placed thing while the plot is open: its saved record, its catalogue
/// entry, and what moves about it frame to frame.
final class LiveItem {
    var placed: PlacedItem
    let item: CatalogueItem
    let phase: Float
    var sway: Float = 0
    var swayVel: Float = 0
    /// A body on the water, for the things that float.
    var body: Debris?
    /// The fish this let go, swimming in the garden.
    var koi: Koi?
    var shoal: Shoal?
    /// How much of the wind a floater catches: 0 for anything without a sail.
    var sail: Float = 0
    /// The tea bowl: how full it is, and how far into its tip it is.
    var fill: Float = 0
    var tip: Float = 0
    /// Under a finger right now, so it is not drawn where it was.
    var lifted = false
    var nextPetalAt: Date?

    init(placed: PlacedItem, item: CatalogueItem) {
        self.placed = placed
        self.item = item
        phase = Float.random(in: 0...(2 * .pi))
    }
}

/// A grain of earth thrown up by the spade, on its way back down.
final class Grain {
    private(set) var position: CGPoint
    private var velocity: CGVector
    private(set) var lift: CGFloat = 0
    private var up: CGFloat
    let size: CGFloat
    let spin: Float
    private(set) var landed = false

    init(at p: CGPoint, velocity: CGVector, up: CGFloat, size: CGFloat) {
        position = p
        self.velocity = velocity
        self.up = up
        self.size = size
        spin = Float.random(in: 0...(2 * .pi))
    }

    func update(dt: Float) {
        let d = CGFloat(dt)
        position.x += velocity.dx * d
        position.y += velocity.dy * d
        lift += up * d
        up -= 320 * d
        if lift < 0 { landed = true }
    }
}

private extension CGFloat {
    /// Points above the water as the sprite's `z`, which is in depth units.
    var asZ: Float { Float(self) / WaterRenderer.depthScale }
}

extension PlotController: PlotIndexed {}
