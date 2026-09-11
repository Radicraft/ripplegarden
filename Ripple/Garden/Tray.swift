import CoreGraphics
import Foundation
import simd

/// The wooden tray the player's things are kept on. It lies on the water
/// near the bottom of the screen and slides in from the right edge when its
/// stone is tapped; what is owned and not yet placed sits along it in a
/// row, and a drag along the row scrolls it. The controller decides what
/// happens when a thing is dragged off; the tray only says what is where.
final class Tray {

    /// One thing on the tray and where its picture sits, in world points.
    struct Slot {
        let item: CatalogueItem
        let centre: CGPoint
    }

    /// Whether the tray has been asked in.
    private(set) var open = false
    /// 0 out of sight beyond the right edge, 1 all the way in.
    private(set) var slide: Float = 0
    /// Points the row has been dragged along, 0 with the first thing at the left.
    private(set) var scroll: CGFloat = 0
    private var scrollVelocity: CGFloat = 0
    /// Where the tray's middle sits when fully in, in world points. Set by
    /// the controller from the screen each frame, so the tray stays on
    /// screen whatever the camera does.
    var home: CGPoint = .zero
    /// The tray's middle right now, slid by `slide` from the right.
    private(set) var centre: CGPoint = .zero
    /// The tray's size on the water.
    static let length: CGFloat = 330
    static let breadth: CGFloat = 92
    /// Points between things along the row, and how far in the first sits.
    static let pitch: CGFloat = 74
    static let inset: CGFloat = 46
    /// What the tray shows this frame.
    private(set) var items: [CatalogueItem] = []
    /// A thing on its way back after a drop the plot refused: where it is
    /// and how far along the return it has got.
    private(set) var returning: [(item: CatalogueItem, from: CGPoint, t: Float)] = []
    private var phase: Float = 0

    /// The painting, if the art has landed; else planks of disc bodies.
    let hasPainting = PlotArt.exists("tray")

    func toggle() { open.toggle() }
    func close() { open = false }

    /// The row scrolled by a drag.
    func scroll(by dx: CGFloat) {
        scroll -= dx
        scrollVelocity = -dx * 30
    }

    func update(dt: Float, items newItems: [CatalogueItem], slideFrom: CGFloat) {
        items = newItems
        phase += dt
        let want: Float = open ? 1 : 0
        slide += (want - slide) * min(1, dt * 6)
        if abs(slide - want) < 0.005 { slide = want }
        // The row cannot be dragged off either end.
        let span = max(0, CGFloat(items.count - 1) * Tray.pitch - (Tray.length - Tray.inset * 2))
        if scroll < 0 { scroll += (0 - scroll) * min(1, CGFloat(dt) * 10); scrollVelocity = 0 }
        if scroll > span { scroll += (span - scroll) * min(1, CGFloat(dt) * 10); scrollVelocity = 0 }
        scroll += scrollVelocity * CGFloat(dt)
        scrollVelocity *= exp(-CGFloat(dt) * 5)
        centre = CGPoint(x: home.x + slideFrom * CGFloat(1 - slide), y: home.y)
        for i in returning.indices { returning[i].t += dt * 2.2 }
        returning.removeAll { $0.t >= 1 }
    }

    /// The things along the row, only those that lie on the tray.
    var slots: [Slot] {
        var out: [Slot] = []
        let left = centre.x - Tray.length / 2 + Tray.inset
        for (i, item) in items.enumerated() {
            let x = left + CGFloat(i) * Tray.pitch - scroll
            guard x > centre.x - Tray.length / 2 + 18, x < centre.x + Tray.length / 2 - 18 else { continue }
            out.append(Slot(item: item, centre: CGPoint(x: x, y: centre.y)))
        }
        return out
    }

    func contains(_ p: CGPoint) -> Bool {
        guard slide > 0.5 else { return false }
        return abs(p.x - centre.x) < Tray.length / 2 && abs(p.y - centre.y) < Tray.breadth / 2 + 10
    }

    /// The thing under a point, if one is.
    func item(at p: CGPoint) -> CatalogueItem? {
        guard contains(p) else { return nil }
        return slots.min { hypot($0.centre.x - p.x, $0.centre.y - p.y) < hypot($1.centre.x - p.x, $1.centre.y - p.y) }
            .flatMap { hypot($0.centre.x - p.x, $0.centre.y - p.y) < Tray.pitch * 0.55 ? $0.item : nil }
    }

    /// A refused drop: the thing floats back to the tray from where it was.
    func takeBack(_ item: CatalogueItem, from: CGPoint) {
        returning.append((item, from, 0))
    }

    /// Where a returning thing is drawn this frame.
    func returnPoint(_ r: (item: CatalogueItem, from: CGPoint, t: Float)) -> CGPoint {
        let t = CGFloat(r.t)
        let e = t * t * (3 - 2 * t)
        let to = slots.first { $0.item.id == r.item.id }?.centre ?? centre
        return CGPoint(x: r.from.x + (to.x - r.from.x) * e, y: r.from.y + (to.y - r.from.y) * e)
    }

    // MARK: - Drawing

    /// The tray and what lies on it. The wood is a floater; the things on it
    /// are drawn by the controller with everything else, so they can be the
    /// same pictures on the tray and off it.
    func woodSprites(textureSize: (String) -> CGSize, painting: (String) -> UInt32,
                     solids: inout [SolidInstance]) -> [Sprite] {
        guard slide > 0.01 else { return [] }
        var out: [Sprite] = []
        let bob = CGFloat(sin(Double(phase) * 0.9)) * 1.5
        let c = CGPoint(x: centre.x, y: centre.y + bob)
        if hasPainting {
            let t = textureSize("tray")
            let w = Tray.length * 1.04
            let h = w * t.height / max(1, t.width)
            out.append(Sprite("tray", at: CGPoint(x: c.x + 4, y: c.y + 6), size: CGSize(width: w, height: h),
                              mode: .shadow, alpha: 0.35, z: 0))
            out.append(Sprite("tray", at: c, size: CGSize(width: w, height: h), mode: .floater, alpha: 1, z: 0.02))
        } else {
            // Planks: a row of thin brown discs, overlapping into one board.
            let r = Float(Tray.breadth) * 0.5
            let n = 5
            for i in 0..<n {
                let x = c.x - Tray.length / 2 + CGFloat(r) + CGFloat(i) * (Tray.length - CGFloat(r) * 2) / CGFloat(n - 1)
                solids.append(SolidInstance(position: SIMD2(Float(x), Float(c.y)), lift: 2.5, yaw: 0, roll: 0,
                                            tilt: .zero, length: 4, radius: r, shape: 4, alpha: 1,
                                            colourA: [0.46, 0.32, 0.20, 1], colourB: [0.46, 0.32, 0.20, 1]))
            }
        }
        return out
    }
}

/// Loose paintings the plot may or may not have yet: each is looked for
/// once, so a missing picture costs one lookup and then its fallback.
enum PlotArt {
    private static var known: [String: Bool] = [:]

    static func exists(_ name: String) -> Bool {
        if let k = known[name] { return k }
        let found = Bundle.main.url(forResource: name, withExtension: "png") != nil
        known[name] = found
        return found
    }

    /// The first of the names that exists, else the last.
    static func first(of names: [String]) -> String {
        names.first { exists($0) } ?? names.last ?? "mote"
    }
}
