import CoreGraphics
import Foundation
import simd

/// The hollow the player digs: a mask over the plot's world, one cell every
/// `PlotTuning.cellPoints`, r = how far down the earth has been taken at
/// that cell, 0 untouched to 1 as deep as the spade goes. The effective
/// depth of the pond is this times how full the sluice has let it get, so
/// the same hollow reads as dry earth, a puddle at its lowest point, or a
/// pond, as the water comes in.
///
/// Like `IceField` the mask is CPU memory with a dirty box, and the
/// renderer paints its depth map from it when the box is not empty.
final class DigField {
    let width: Int
    let height: Int
    let cell: CGFloat
    let world: CGSize
    private(set) var dug: [Float]
    /// The box of cells changed since the last repaint, or nil when clean.
    private(set) var dirtyRect: (x0: Int, y0: Int, x1: Int, y1: Int)?

    /// The soft brush: a raised cosine over the radius, so the sides of the
    /// hollow shelve rather than step. One stamp every `stampSpacing` points
    /// along the stroke; the amount per stamp is scaled so a stroke passing
    /// over a point takes about `digPerPass` off it at the middle.
    static let stampSpacing: CGFloat = 8
    /// The rim of earth round the plot that cannot be dug, so the pond
    /// never reaches the world's edge.
    static let margin: CGFloat = 36

    init(world: CGSize, cell: CGFloat = PlotTuning.cellPoints) {
        self.world = world
        self.cell = cell
        width = max(8, Int((world.width / cell).rounded(.up)))
        height = max(8, Int((world.height / cell).rounded(.up)))
        dug = Array(repeating: 0, count: width * height)
        dirtyRect = (0, 0, width - 1, height - 1)
    }

    // MARK: - Reading

    /// Dug depth at a world point, bilinear over the cells; 0 off the field.
    func depth(at p: CGPoint) -> Float {
        let fx = Float(p.x / cell) - 0.5, fy = Float(p.y / cell) - 0.5
        guard fx > -1, fy > -1, fx < Float(width), fy < Float(height) else { return 0 }
        let x0 = Int(floor(fx)), y0 = Int(floor(fy))
        let tx = fx - Float(x0), ty = fy - Float(y0)
        func at(_ x: Int, _ y: Int) -> Float {
            guard x >= 0, y >= 0, x < width, y < height else { return 0 }
            return dug[y * width + x]
        }
        let top = at(x0, y0) * (1 - tx) + at(x0 + 1, y0) * tx
        let bottom = at(x0, y0 + 1) * (1 - tx) + at(x0 + 1, y0 + 1) * tx
        return top * (1 - ty) + bottom * ty
    }

    /// Whether anything at all has been dug.
    var isEmpty: Bool { !dug.contains { $0 > 0.01 } }

    /// The deepest cell, 0 on untouched earth.
    var deepest: Float { dug.max() ?? 0 }

    // MARK: - Digging

    /// Lowers the earth along a stroke of world points. Returns the points
    /// the brush was stamped at, so grains can be thrown up from them.
    @discardableResult
    func dig(along stroke: [CGPoint]) -> [CGPoint] {
        guard let first = stroke.first else { return [] }
        var stamps: [CGPoint] = []
        if stroke.count == 1 {
            stamp(at: first)
            stamps.append(first)
            return stamps
        }
        var carried: CGFloat = 0
        for i in 1..<stroke.count {
            let a = stroke[i - 1], b = stroke[i]
            let dx = b.x - a.x, dy = b.y - a.y
            let len = hypot(dx, dy)
            guard len > 0.01 else { continue }
            var t = carried
            while t <= len {
                let p = CGPoint(x: a.x + dx * t / len, y: a.y + dy * t / len)
                stamp(at: p)
                stamps.append(p)
                t += DigField.stampSpacing
            }
            carried = t - len
        }
        return stamps
    }

    private func stamp(at p: CGPoint) {
        let r = PlotTuning.brushRadius
        let m = DigField.margin
        guard p.x > m, p.y > m, p.x < world.width - m, p.y < world.height - m else { return }
        // A stroke lays about 2r / spacing stamps over the point under it,
        // each weighted by the brush's falloff along that line, which
        // integrates to about half; so a stamp's centre is the pass amount
        // over that.
        let perStamp = PlotTuning.digPerPass * Float(DigField.stampSpacing / r)
        let x0 = max(0, Int((p.x - r) / cell)), x1 = min(width - 1, Int((p.x + r) / cell))
        let y0 = max(0, Int((p.y - r) / cell)), y1 = min(height - 1, Int((p.y + r) / cell))
        guard x0 <= x1, y0 <= y1 else { return }
        let rr = Float(r)
        for y in y0...y1 {
            let cy = (CGFloat(y) + 0.5) * cell
            let dy = Float(cy - p.y)
            for x in x0...x1 {
                let cx = (CGFloat(x) + 0.5) * cell
                let dx = Float(cx - p.x)
                let d = (dx * dx + dy * dy).squareRoot()
                guard d < rr else { continue }
                // Raised cosine: full at the middle, nothing at the rim.
                let w = 0.5 + 0.5 * cos(d / rr * .pi)
                // The margin shelves too, so the pond cannot cut a cliff at
                // the edge of what may be dug.
                let edge = min(1, Float(min(cx - m, cy - m, world.width - m - cx, world.height - m - cy) / 24))
                let i = y * width + x
                dug[i] = min(1, dug[i] + perStamp * w * max(0, edge))
            }
        }
        touch(x0, y0, x1, y1)
    }

    private func touch(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
        if let r = dirtyRect {
            dirtyRect = (min(r.x0, x0), min(r.y0, y0), max(r.x1, x1), max(r.y1, y1))
        } else {
            dirtyRect = (x0, y0, x1, y1)
        }
    }

    func markClean() { dirtyRect = nil }

    /// A ready-dug hollow, for looking at the plot without digging one: a
    /// soft bowl at the middle with a wandering rim, and a shelf of
    /// shallows toward one side where lilies could sit.
    func digDemoHollow() {
        let c = CGPoint(x: world.width * 0.5, y: world.height * 0.52)
        let rx = Float(world.width * 0.30), ry = Float(world.height * 0.22)
        for y in 0..<height {
            let cy = (CGFloat(y) + 0.5) * cell
            for x in 0..<width {
                let cx = (CGFloat(x) + 0.5) * cell
                let dx = Float(cx - c.x) / rx, dy = Float(cy - c.y) / ry
                let ang = atan2(dy, dx)
                let wobble = 1 + (ShoreNoise.value(cos(ang) * 1.7 + 3, sin(ang) * 1.7 + 3) - 0.5) * 0.3
                let r = (dx * dx + dy * dy).squareRoot() / wobble
                guard r < 1 else { continue }
                var d = 1 - r * r
                d = d * d * (3 - 2 * d)
                // A shelf on the near left, where the bed stays lily deep.
                if dx < -0.25, dy > 0 { d = min(d, 0.42) }
                dug[y * width + x] = max(dug[y * width + x], min(1, d * 1.15))
            }
        }
        dirtyRect = (0, 0, width - 1, height - 1)
    }

    // MARK: - The waterline

    /// The nearest point on the waterline to `p` within `reach`, given how
    /// full the hollow is, or nil when no water lies that close. The
    /// waterline is where the effective depth crosses the shader's dry
    /// threshold; cells are walked in a box and the crossing nearest the
    /// point wins.
    func shorePoint(near p: CGPoint, within reach: CGFloat, water: Float) -> CGPoint? {
        let threshold: Float = 0.11
        let x0 = max(1, Int((p.x - reach) / cell)), x1 = min(width - 2, Int((p.x + reach) / cell))
        let y0 = max(1, Int((p.y - reach) / cell)), y1 = min(height - 2, Int((p.y + reach) / cell))
        guard x0 <= x1, y0 <= y1 else { return nil }
        var best: CGPoint?
        var bestD = reach * reach
        for y in y0...y1 {
            for x in x0...x1 {
                let here = dug[y * width + x] * water
                guard here >= threshold else { continue }
                // Wet, with dry earth beside it: the line runs through here.
                let dryBeside = dug[y * width + x - 1] * water < threshold || dug[y * width + x + 1] * water < threshold
                    || dug[(y - 1) * width + x] * water < threshold || dug[(y + 1) * width + x] * water < threshold
                guard dryBeside else { continue }
                let cx = (CGFloat(x) + 0.5) * cell, cy = (CGFloat(y) + 0.5) * cell
                let d = (cx - p.x) * (cx - p.x) + (cy - p.y) * (cy - p.y)
                if d < bestD { bestD = d; best = CGPoint(x: cx, y: cy) }
            }
        }
        return best
    }

    /// The direction from a shore point out of the water, so a plant rooted
    /// there stands on the earth side of the line.
    func outward(at p: CGPoint, water: Float) -> CGVector {
        let step = cell * 3
        let dx = depth(at: CGPoint(x: p.x + step, y: p.y)) - depth(at: CGPoint(x: p.x - step, y: p.y))
        let dy = depth(at: CGPoint(x: p.x, y: p.y + step)) - depth(at: CGPoint(x: p.x, y: p.y - step))
        let len = max(0.0001, (dx * dx + dy * dy).squareRoot())
        // Depth rises into the water, so out of it is down the gradient.
        return CGVector(dx: CGFloat(-dx / len), dy: CGFloat(-dy / len))
    }

    // MARK: - Saving

    /// The mask as bytes into the saved plot.
    func encode(into state: inout PlotState) {
        var bytes = [UInt8](repeating: 0, count: dug.count)
        for i in dug.indices { bytes[i] = UInt8(max(0, min(255, (dug[i] * 255).rounded()))) }
        state.dig = Data(bytes)
        state.digWidth = width
        state.digHeight = height
    }

    /// A field from the saved plot over this world. A save from a screen of
    /// another size is resampled onto this one, so the hollow keeps its
    /// shape and place as a fraction of the plot.
    convenience init?(state: PlotState, world: CGSize) {
        guard state.digWidth > 0, state.digHeight > 0, state.dig.count == state.digWidth * state.digHeight else { return nil }
        self.init(world: world)
        let sw = state.digWidth, sh = state.digHeight
        let bytes = [UInt8](state.dig)
        if sw == width, sh == height {
            for i in 0..<(sw * sh) { dug[i] = Float(bytes[i]) / 255 }
        } else {
            for y in 0..<height {
                let sy = min(sh - 1, Int((CGFloat(y) + 0.5) / CGFloat(height) * CGFloat(sh)))
                for x in 0..<width {
                    let sx = min(sw - 1, Int((CGFloat(x) + 0.5) / CGFloat(width) * CGFloat(sw)))
                    dug[y * width + x] = Float(bytes[sy * sw + sx]) / 255
                }
            }
        }
        dirtyRect = (0, 0, width - 1, height - 1)
    }
}
