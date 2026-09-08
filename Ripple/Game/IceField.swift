import CoreGraphics
import Foundation

/// The frozen pond: one sheet of ice over the surface, kept as two masks
/// over the world at two points per cell: how much ice is here, and where
/// the sheet is fractured. Ice breaks the way ice does: a strike sends long
/// branching fractures across the sheet, and the sheet then gives way in
/// angular shards bounded by those fractures.
final class IceField {
    let width: Int
    let height: Int
    let cellSize: CGFloat
    private(set) var cells: [Float]      // 1 ice, 0 open water
    private(set) var cracks: [Float]     // 1 on a fracture line (the shards' boundaries)
    /// Every fracture as the path it took, in points, for drawing.
    private(set) var crackLines: [[CGPoint]] = []
    private(set) var dirty = true
    private var seed: UInt32 = 11

    init(world: CGSize, cellSize: CGFloat = 1) {
        self.cellSize = cellSize
        width = max(8, Int(world.width / cellSize))
        height = max(8, Int(world.height / cellSize))
        cells = Array(repeating: 1, count: width * height)
        cracks = Array(repeating: 0, count: width * height)
    }

    var fraction: Float { cells.reduce(0, +) / Float(cells.count) }

    func ice(at p: CGPoint) -> Float {
        let x = Int(p.x / cellSize), y = Int(p.y / cellSize)
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return cells[y * width + x]
    }

    func isCracked(near p: CGPoint, within: CGFloat) -> Bool {
        let cx = Int(p.x / cellSize), cy = Int(p.y / cellSize), rr = Int(within / cellSize)
        for y in max(0, cy - rr)...min(height - 1, cy + rr) {
            for x in max(0, cx - rr)...min(width - 1, cx + rr) where cracks[y * width + x] > 0.5 { return true }
        }
        return false
    }

    func markClean() { dirty = false }

    private func noise() -> Float {
        seed = seed &* 1664525 &+ 1013904223
        return Float(seed >> 8) / Float(1 << 24)
    }

    // MARK: - Fracture

    /// Draws one fracture: a line that wanders a little as it goes, forking
    /// now and then, until it runs its length, meets open water, or leaves
    /// the pond.
    private func fracture(from start: CGPoint, angle: Float, length: CGFloat, depth: Int = 0) {
        var x = Float(start.x / cellSize), y = Float(start.y / cellSize)
        var a = angle
        var travelled: Float = 0
        let total = Float(length / cellSize)
        let bias = noise() < 0.5 ? -1 : Float(1)
        var line: [CGPoint] = [start]
        defer { if line.count > 2 { crackLines.append(line) } }
        while travelled < total {
            let step: Float = 1.0
            // Nearly straight, with a kink now and then.
            a += (noise() - 0.5) * 0.03 + bias * 0.001
            if noise() < 0.01 { a += (noise() - 0.5) * 0.6 }
            x += cos(a) * step
            y += sin(a) * step
            travelled += step
            let ix = Int(x), iy = Int(y)
            guard ix >= 0, iy >= 0, ix < width, iy < height else { return }
            if cells[iy * width + ix] < 0.5 { return }          // reached open water
            cracks[iy * width + ix] = 1
            // Thicken so a flood cannot slip through a diagonal.
            if ix + 1 < width { cracks[iy * width + ix + 1] = 1 }
            if Int(travelled) % 6 == 0 { line.append(CGPoint(x: CGFloat(x) * cellSize, y: CGFloat(y) * cellSize)) }
            // A fork, rarely, that runs shorter.
            if depth < 2, noise() < 0.012 {
                fracture(from: CGPoint(x: CGFloat(x) * cellSize, y: CGFloat(y) * cellSize),
                         angle: a + (noise() < 0.5 ? -0.75 : 0.75) + (noise() - 0.5) * 0.3,
                         length: length * 0.45, depth: depth + 1)
            }
        }
    }

    /// A strike on solid ice: several long fractures radiate from the point,
    /// and a ring of shorter ones joins them a little way out, so the ice
    /// around the blow is already divided into shards.
    func strike(at p: CGPoint) {
        let n = 4 + Int(noise() * 3)
        let base = noise() * 2 * .pi
        var tips: [CGPoint] = []
        for k in 0..<n {
            let angle = base + Float(k) / Float(n) * 2 * .pi + (noise() - 0.5) * 0.5
            fracture(from: p, angle: angle, length: CGFloat(160 + noise() * 340))
            let ringR = CGFloat(55 + noise() * 45)
            tips.append(CGPoint(x: p.x + CGFloat(cos(angle)) * ringR, y: p.y + CGFloat(sin(angle)) * ringR))
        }
        // Chords between neighbouring radial fractures: the shard boundaries.
        for k in 0..<n {
            let a = tips[k], b = tips[(k + 1) % n]
            let dx = b.x - a.x, dy = b.y - a.y
            let len = hypot(dx, dy)
            fracture(from: a, angle: atan2(Float(dy), Float(dx)), length: len * 1.05)
        }
        dirty = true
    }

    /// The sheet gives way around a point: every cell reachable from it
    /// without crossing a fracture, out to a limit, opens. Between two
    /// fractures that gives a wedge; between many, a shard. Returns the area
    /// opened, in points squared.
    @discardableResult
    func breakThrough(at p: CGPoint, limit: CGFloat) -> CGFloat {
        var cx = Int(p.x / cellSize), cy = Int(p.y / cellSize)
        guard cx >= 0, cy >= 0, cx < width, cy < height, cells[cy * width + cx] > 0.5 else { return 0 }
        // A tap right on a fracture: step into the shard beside it.
        if cracks[cy * width + cx] > 0.5 {
            var found = false
            for r in 1...8 where !found {
                for (dx, dy) in [(r, 0), (-r, 0), (0, r), (0, -r), (r, r), (-r, -r), (r, -r), (-r, r)] {
                    let nx = cx + dx, ny = cy + dy
                    if nx >= 0, ny >= 0, nx < width, ny < height, cracks[ny * width + nx] < 0.5, cells[ny * width + nx] > 0.5 {
                        cx = nx; cy = ny; found = true; break
                    }
                }
            }
            if !found { return 0 }
        }
        let r = Int(limit / cellSize)
        var opened = 0
        var stack = [(cx, cy)]
        var seen = Set<Int>()
        seen.insert(cy * width + cx)
        while let (x, y) = stack.popLast() {
            let i = y * width + x
            let dx = x - cx, dy = y - cy
            if dx * dx + dy * dy > r * r { continue }
            if cells[i] < 0.5 { continue }
            cells[i] = 0
            opened += 1
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                let j = ny * width + nx
                if seen.contains(j) { continue }
                seen.insert(j)
                if cracks[j] > 0.5 { cells[j] = 0; continue }   // the fracture is the shard's edge
                stack.append((nx, ny))
            }
        }
        // Fractures that now border open water are spent.
        dirty = true
        return CGFloat(opened) * cellSize * cellSize
    }

    /// A wave from open water reaches the sheet: a fracture runs in from the
    /// edge, and a small piece between fractures gives way.
    func bite(nearestTo p: CGPoint, range: CGFloat) -> CGPoint? {
        guard let edge = nearestIce(to: p, range: range) else { return nil }
        let away = atan2(Float(edge.y - p.y), Float(edge.x - p.x))
        // Only fracture fresh ice, and not every time; a spot already split
        // just gives way along what is there.
        if !isCracked(near: edge, within: 60), noise() < 0.4 {
            fracture(from: edge, angle: away + (noise() - 0.5) * 0.8, length: CGFloat(120 + noise() * 200))
        }
        let inward = CGPoint(x: edge.x + CGFloat(cos(away)) * 8, y: edge.y + CGFloat(sin(away)) * 8)
        breakThrough(at: inward, limit: CGFloat(30 + noise() * 30))
        dirty = true
        return edge
    }

    /// The nearest ice cell to a point, if any within `range`.
    func nearestIce(to p: CGPoint, range: CGFloat) -> CGPoint? {
        let cx = Int(p.x / cellSize), cy = Int(p.y / cellSize)
        let rr = Int(range / cellSize)
        var best: (Int, Int, Int)?
        let stride = 2
        var y = max(0, cy - rr)
        while y <= min(height - 1, cy + rr) {
            var x = max(0, cx - rr)
            while x <= min(width - 1, cx + rr) {
                if cells[y * width + x] > 0.5 {
                    let d2 = (x - cx) * (x - cx) + (y - cy) * (y - cy)
                    if d2 <= rr * rr, best == nil || d2 < best!.2 { best = (x, y, d2) }
                }
                x += stride
            }
            y += stride
        }
        guard let b = best else { return nil }
        return CGPoint(x: (CGFloat(b.0) + 0.5) * cellSize, y: (CGFloat(b.1) + 0.5) * cellSize)
    }

    /// Is this point on the sheet but close to open water?
    func isEdge(at p: CGPoint, within: CGFloat) -> Bool {
        guard ice(at: p) > 0.5 else { return false }
        let cx = Int(p.x / cellSize), cy = Int(p.y / cellSize), rr = Int(within / cellSize)
        for y in stride(from: max(0, cy - rr), through: min(height - 1, cy + rr), by: 2) {
            for x in stride(from: max(0, cx - rr), through: min(width - 1, cx + rr), by: 2) where cells[y * width + x] < 0.5 {
                return true
            }
        }
        return false
    }
}
