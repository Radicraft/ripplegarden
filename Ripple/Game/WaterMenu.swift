import CoreGraphics
import Foundation
import UIKit
import QuartzCore
import simd

/// Menus happen in the pond, never on a sheet of glass over it. The words are
/// ink under the surface, so the water refracts them and the caustics play
/// over them; the buttons are stones sitting in the water; opening one
/// darkens the water around it like a cloud passing, and every item rises
/// from the deep. Nothing here is paper.

/// How the words and the stones sit in the water once they are up.
private enum Water {
    /// How far under the surface the ink rests, and where it starts.
    static let restDepth: Float = 0.28
    static let deepDepth: Float = 0.95
    static let restZ: Float = -0.30
    static let deepZ: Float = -0.95
    /// One item takes this long to rise, and each row starts this much later.
    static let rise: Float = 0.6
    static let stagger: Float = 0.04
    static let sink: Float = 0.5

    /// Pixels of a label texture to world points. Labels are drawn at twice
    /// the size they are asked for, and read best a little under that.
    static let labelScale: CGFloat = 0.45

    static func ease(_ t: Float) -> Float {
        let c = max(0, min(1, t))
        return 1 - (1 - c) * (1 - c) * (1 - c)
    }

    static func size(_ texture: String, textures: TextureCache) -> CGSize {
        let t = textures.size(texture)
        return CGSize(width: t.width * labelScale, height: t.height * labelScale)
    }
}

// MARK: - Ink under the surface

/// A few lines of ink that rise from the deep, wait, and sink again. The
/// hints, the line that opens a level and the status line are all this.
@MainActor
final class WaterWords {

    struct Line {
        let text: String
        let points: CGFloat
        /// Body copy wraps and centres; a caption is one line.
        var wrapped: Bool = false
    }

    private enum State { case rising, holding, sinking, gone }

    private(set) var lines: [Line]
    /// The middle of the block, in world points.
    var centre: CGPoint
    /// How wide wrapped copy may run, in world points.
    var width: CGFloat = 320
    /// How long the words hold once they are up. Nil means they stay.
    var hold: TimeInterval?

    private var state: State = .rising
    private var t: Float = 0

    init(lines: [Line], centre: CGPoint, hold: TimeInterval?) {
        self.lines = lines
        self.centre = centre
        self.hold = hold
    }

    var isGone: Bool { state == .gone }

    func update(dt: Float) {
        t += dt
        switch state {
        case .rising:
            if t > Water.rise + Water.stagger * Float(lines.count) { state = .holding; t = 0 }
        case .holding:
            if let h = hold, t > Float(h) { state = .sinking; t = 0 }
        case .sinking:
            if t > Water.sink { state = .gone }
        case .gone:
            break
        }
    }

    /// New words in the same place: the status line changes as the pond does,
    /// and the new line rises where the old one stood.
    func replace(lines: [Line]) {
        self.lines = lines
        state = .rising
        t = 0
    }

    func sink() {
        guard state != .gone, state != .sinking else { return }
        state = .sinking
        t = 0
    }

    func sprites(textures: TextureCache) -> [Sprite] {
        guard !lines.isEmpty, state != .gone else { return [] }
        var names: [String] = []
        var sizes: [CGSize] = []
        for line in lines {
            let name = line.wrapped
                ? LabelSprites.words(line.text, points: line.points, textures: textures, width: width / Water.labelScale / 2)
                : LabelSprites.caption(line.text, points: line.points, textures: textures)
            names.append(name)
            sizes.append(Water.size(name, textures: textures))
        }
        let gap: CGFloat = 6
        let total = sizes.reduce(CGFloat(0)) { $0 + $1.height } + gap * CGFloat(max(0, lines.count - 1))
        var y = centre.y - total / 2
        var out: [Sprite] = []
        for i in lines.indices {
            let s = sizes[i]
            let p = progress(row: i)
            if p > 0.001 {
                out.append(Sprite(names[i], at: CGPoint(x: centre.x, y: y + s.height / 2), size: s,
                                  mode: .submerged, alpha: min(1, p * 1.6),
                                  depth: Water.deepDepth + (Water.restDepth - Water.deepDepth) * p,
                                  z: Water.deepZ + (Water.restZ - Water.deepZ) * p))
            }
            y += s.height + gap
        }
        return out
    }

    private func progress(row: Int) -> Float {
        switch state {
        case .rising: return Water.ease((t - Water.stagger * Float(row)) / Water.rise)
        case .holding: return 1
        case .sinking: return 1 - Water.ease(t / Water.sink)
        case .gone: return 0
        }
    }
}

// MARK: - The menu

/// One stone in a menu: a word, a colour, and what it does.
struct WaterMenuButton {
    let label: String
    var dark: Bool = false
    let action: () -> Void
}

/// A line of a menu.
enum WaterMenuRow {
    case title(String)
    case words(String)
    case toggle(String, get: () -> Bool, set: (Bool) -> Void)
    case buttons([WaterMenuButton])
}

@MainActor
final class WaterMenu {

    private enum State { case rising, open, closing, gone }

    /// The rows, in order down the pond. The store swaps its own once the
    /// prices arrive.
    private(set) var rows: [WaterMenuRow]
    /// A tap on the water outside closes the menu. The completion does not.
    var closesOnOutsideTap = true
    /// Half the width of a row, in world points.
    var halfWidth: CGFloat = 190

    /// A ring or a swell on the water, which only the controller can make.
    var splat: ((CGPoint, Float, Float) -> Void)?

    private let sound: SoundDirector
    private let haptics: Haptics

    private var state: State = .gone
    private var t: Float = 0
    private var centre: CGPoint = .zero
    private var world: CGSize = .zero
    private(set) var dim: Float = 0
    /// Half the size of the menu in world points, for the clear ellipse.
    private var extent = CGSize(width: 240, height: 260)

    private struct PlacedStone {
        let at: CGPoint
        let radius: CGFloat
        let dark: Bool
        let label: String
        let row: Int
        let key: Int
        let action: () -> Void
    }
    private var stones: [PlacedStone] = []
    /// Stones that have just been pressed, and the dip they have left.
    private var dips: [Int: Float] = [:]

    init(rows: [WaterMenuRow], sound: SoundDirector, haptics: Haptics) {
        self.rows = rows
        self.sound = sound
        self.haptics = haptics
    }

    var isOpen: Bool { state != .gone }
    var isGone: Bool { state == .gone }

    /// New rows in place, keeping the menu where it is: the store shows its
    /// prices the moment the App Store answers.
    func replace(rows: [WaterMenuRow]) { self.rows = rows }

    func open(at centre: CGPoint, world: CGSize) {
        self.centre = centre
        self.world = world
        state = .rising
        t = 0
        // A broad soft swell spreads from the middle of the menu.
        splat?(centre, 110, -0.10)
        sound.swell()
        haptics.swell()
    }

    func close() {
        guard state == .rising || state == .open else { return }
        state = .closing
        t = 0
        sound.holdRelease(charge: 0.3)
        haptics.holdRelease(charge: 0.3)
    }

    func update(dt: Float) {
        t += dt
        switch state {
        case .rising:
            if t > Water.rise + Water.stagger * Float(rows.count) { state = .open; t = 0 }
        case .closing:
            if t > Water.sink { state = .gone }
        case .open, .gone:
            break
        }
        let target: Float = (state == .closing || state == .gone) ? 0 : 1
        dim += (target - dim) * min(1, dt * 4)
        for (k, left) in dips {
            let next = left - dt
            if next <= 0 { dips.removeValue(forKey: k) } else { dips[k] = next }
        }
    }

    /// Centre and radii of the clear water around the menu, in world uv.
    var rect: SIMD4<Float> {
        guard world.width > 0, world.height > 0 else { return SIMD4(0.5, 0.5, 0.35, 0.35) }
        return SIMD4(Float(centre.x / world.width), Float(centre.y / world.height),
                     Float(extent.width / world.width), Float(extent.height / world.height))
    }

    /// A tap. Returns true when the menu has taken it, which is whenever it
    /// is open: no touch reaches the water through a menu.
    @discardableResult
    func hit(_ point: CGPoint) -> Bool {
        guard state == .rising || state == .open else { return isOpen }
        if let stone = stones.first(where: { hypot($0.at.x - point.x, $0.at.y - point.y) < max($0.radius * 1.8, 46) }) {
            press(stone)
            return true
        }
        if closesOnOutsideTap, outside(point) { close() }
        return true
    }

    private func outside(_ p: CGPoint) -> Bool {
        let dx = (p.x - centre.x) / max(1, extent.width)
        let dy = (p.y - centre.y) / max(1, extent.height)
        return dx * dx + dy * dy > 1
    }

    /// The stone dips, the water rings, and then the thing happens.
    private func press(_ stone: PlacedStone) {
        dips[stone.key] = 0.15
        splat?(stone.at, 16, -0.18)
        sound.plop()
        haptics.tap(weight: 0.5)
        let action = stone.action
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            action()
        }
    }

    // MARK: - Laying it out

    /// The sprites and stones for this frame. The layout is worked out here,
    /// where the label sizes are known, and kept for the next tap.
    func sprites(textures: TextureCache) -> (submerged: [Sprite], surface: [Sprite], solids: [SolidInstance]) {
        guard state != .gone else { stones = []; return ([], [], []) }

        // Measure first: every row's height, so the whole menu sits centred.
        struct Measured {
            var words: [(name: String, size: CGSize)] = []
            var height: CGFloat = 0
        }
        var measured: [Measured] = []
        for row in rows {
            var m = Measured()
            switch row {
            case .title(let text):
                let name = LabelSprites.caption(text, points: 30, textures: textures)
                let size = Water.size(name, textures: textures)
                m.words = [(name, size)]
                m.height = size.height + 14
            case .words(let text):
                let name = LabelSprites.words(text, points: 17, textures: textures,
                                              width: halfWidth * 2 / Water.labelScale / 2)
                let size = Water.size(name, textures: textures)
                m.words = [(name, size)]
                m.height = size.height + 10
            case .toggle(let title, _, _):
                let name = LabelSprites.caption(title, points: 19, textures: textures)
                m.words = [(name, Water.size(name, textures: textures))]
                m.height = 96
            case .buttons:
                // Room for the words above the stones and the stones themselves.
                m.height = 160
            }
            measured.append(m)
        }
        let total = measured.reduce(CGFloat(0)) { $0 + $1.height }
        extent = CGSize(width: halfWidth + 70, height: total / 2 + 80)

        var under: [Sprite] = []
        var over: [Sprite] = []
        var solids: [SolidInstance] = []
        var placed: [PlacedStone] = []
        var y = centre.y - total / 2
        var key = 0

        for (i, row) in rows.enumerated() {
            let m = measured[i]
            let p = progress(row: i)
            let rowMiddle = y + m.height / 2
            y += m.height
            switch row {
            case .title, .words:
                if let w = m.words.first, p > 0.001 {
                    under.append(ink(w.name, at: CGPoint(x: centre.x, y: rowMiddle), size: w.size, p: p))
                }
            case .toggle(_, let get, let set):
                if let w = m.words.first, p > 0.001 {
                    let x = centre.x - halfWidth + w.size.width / 2
                    under.append(ink(w.name, at: CGPoint(x: x, y: rowMiddle), size: w.size, p: p))
                }
                let on = get()
                for (k, choice) in [("On", true), ("Off", false)].enumerated() {
                    placed.append(PlacedStone(at: CGPoint(x: centre.x + (k == 0 ? 70 : 166), y: rowMiddle),
                                              radius: 24, dark: on == choice.1, label: choice.0,
                                              row: i, key: key, action: { set(choice.1) }))
                    key += 1
                }
            case .buttons(let buttons):
                let radii = buttons.map { $0.dark ? CGFloat(31) : CGFloat(28) }
                let gap: CGFloat = 70
                let span = radii.reduce(CGFloat(0)) { $0 + $1 * 2 } + gap * CGFloat(max(0, buttons.count - 1))
                var x = centre.x - span / 2
                for (k, b) in buttons.enumerated() {
                    x += radii[k]
                    placed.append(PlacedStone(at: CGPoint(x: x, y: rowMiddle + 26), radius: radii[k], dark: b.dark,
                                              label: b.label, row: i, key: key, action: b.action))
                    key += 1
                    x += radii[k] + gap
                }
            }
        }

        // The stones themselves, and their words floating just above them.
        for stone in placed {
            let p = progress(row: stone.row)
            guard p > 0.001 else { continue }
            let r = Float(stone.radius)
            let rest = r * 0.35
            let dip: Float = dips[stone.key] != nil ? 6 : 0
            let lift = (-r * 1.2) + (rest + r * 1.2) * p - dip
            let alpha = min(1, p * 1.8)
            let pale: SIMD4<Float> = [0.72, 0.71, 0.68, 1]
            let dark: SIMD4<Float> = [0.20, 0.23, 0.25, 1]
            let colour = stone.dark ? dark : pale
            solids.append(SolidInstance(position: SIMD2(Float(stone.at.x), Float(stone.at.y)),
                                        lift: lift,
                                        yaw: Float(stone.at.x * 0.021 + stone.at.y * 0.013),
                                        roll: Float(stone.at.x * 0.37 + stone.at.y * 0.11),
                                        tilt: .zero,
                                        length: r * 1.5, radius: r, shape: 2, alpha: alpha,
                                        colourA: colour, colourB: colour))
            let name = LabelSprites.caption(stone.label, points: 20, textures: textures)
            let size = Water.size(name, textures: textures)
            over.append(Sprite(name, at: CGPoint(x: stone.at.x, y: stone.at.y - stone.radius * 0.2),
                               size: size, alpha: alpha, z: 0.22 - dip * 0.0008))
        }

        stones = placed
        return (under, over, solids)
    }

    private func ink(_ name: String, at point: CGPoint, size: CGSize, p: Float) -> Sprite {
        Sprite(name, at: point, size: size, mode: .submerged, alpha: min(1, p * 1.6),
               depth: Water.deepDepth + (Water.restDepth - Water.deepDepth) * p,
               z: Water.deepZ + (Water.restZ - Water.deepZ) * p)
    }

    private func progress(row: Int) -> Float {
        switch state {
        case .rising: return Water.ease((t - Water.stagger * Float(row)) / Water.rise)
        case .open: return 1
        case .closing: return 1 - Water.ease(t / Water.sink)
        case .gone: return 0
        }
    }
}

// MARK: - The menus the game has

/// The two menus both screens share. They are built here so the hub and a
/// level offer exactly the same thing.
@MainActor
enum WaterMenus {

    static func settings(sound: SoundDirector, haptics: Haptics) -> WaterMenu {
        let settings = Settings.shared
        let menu = WaterMenu(rows: [], sound: sound, haptics: haptics)
        menu.replace(rows: [
            .title("The garden"),
            .toggle("Sound", get: { settings.soundOn }, set: { settings.soundOn = $0 }),
            .toggle("Haptics", get: { settings.hapticsOn }, set: { settings.hapticsOn = $0 }),
            .buttons([WaterMenuButton(label: "Restore purchases", action: { Task { await Store.shared.restore() } })]),
            .buttons([WaterMenuButton(label: "Done", dark: true, action: { [weak menu] in menu?.close() })])
        ])
        return menu
    }

    static func store(sound: SoundDirector, haptics: Haptics) -> WaterMenu {
        let menu = WaterMenu(rows: [], sound: sound, haptics: haptics)
        menu.replace(rows: storeRows(menu: menu))
        // The first fetch runs at launch and may have found nothing. Ask
        // again while the menu is up, and lay it out afresh when it answers.
        if Store.shared.products.isEmpty {
            Task { @MainActor [weak menu] in
                await Store.shared.load()
                guard let menu, menu.isOpen else { return }
                menu.replace(rows: storeRows(menu: menu))
            }
        }
        return menu
    }

    private static func storeRows(menu: WaterMenu) -> [WaterMenuRow] {
        let store = Store.shared
        var rows: [WaterMenuRow] = [
            .title("Seasons to come"),
            .words("Winter, spring, summer and autumn are yours. The Seasons pass adds new seasons as they arrive, and renews monthly or yearly until you cancel.")
        ]
        if store.isSubscribed {
            rows.append(.words("You have the Seasons pass. Thank you."))
        } else if store.products.isEmpty {
            rows.append(.words("Coming soon"))
        } else {
            rows.append(.buttons(store.products.map { product in
                let period = product.id == Store.annualID ? "Year" : "Month"
                return WaterMenuButton(label: "\(period) \(product.displayPrice)", dark: true,
                                       action: { Task { await store.purchase(product) } })
            }))
        }
        var legal = [WaterMenuButton(label: "Terms", dark: false, action: { UIApplication.shared.open(Store.termsURL) })]
        if let privacy = Store.privacyURL {
            legal.append(WaterMenuButton(label: "Privacy", dark: false, action: { UIApplication.shared.open(privacy) }))
        }
        legal.append(WaterMenuButton(label: "Done", dark: true, action: { [weak menu] in menu?.close() }))
        rows.append(.buttons(legal))
        return rows
    }
}
