import CoreGraphics
import Foundation
import simd

/// The frozen pond: one sheet of black ice over the surface.
///
/// The sheet is a Voronoi diagram. Every blow on it (a `strike`) drops a
/// radial spray of seeds: one at the point, three along each of five to eight
/// spokes, a rim of seeds a little further out that stands for the sheet
/// around the blow, and a few long runners that carry a crack far past the
/// hole. Each cell of the diagram is a shard, and every edge between two
/// cells is a crack, drawn on the GPU as an exact distance field, so the
/// cracks and the shards are the same thing and always agree.
///
/// Two masks over the world, one cell per world point, go to the renderer:
/// `cells` (1 ice, 0 open water) and `scuff` (0..1, frost a finger has wiped).
final class IceField {
    let width: Int
    let height: Int
    let cellSize: CGFloat
    /// 1 ice, 0 open water.
    private(set) var cells: [Float]
    /// 0 untouched frost, 1 wiped clean by a finger.
    private(set) var scuff: [Float]
    /// Every seed of the diagram, laid out for the GPU.
    private(set) var seeds: [IceSeedGPU] = []
    /// Every blow, in the order they landed.
    private(set) var strikes: [IceStrikeGPU] = []
    /// Which slice of `seeds` belongs to each strike.
    private(set) var strikeSeeds: [Range<Int>] = []
    /// The masks have changed and want uploading.
    private(set) var dirty = true
    /// The diagram itself has changed: the crack field wants re-baking. A
    /// finger scuffing frost dirties the masks but not this.
    private(set) var cracksDirty = true
    private var rng: UInt32 = 11
    /// Shards that have given way and are going under: their cells and the
    /// clock when they broke. Their mask value slides from just under the
    /// ice threshold down to open water over a second, and the shader draws
    /// the slab flooding and sinking as it goes.
    private var sinking: [(cells: [Int32], start: Float)] = []
    static let sinkSeconds: Float = 1.1
    static let sinkStart: Float = 0.49

    /// The GPU buffers hold this much; past it the oldest strike is dropped.
    private let seedCap = 4000
    private let strikeCap = 250

    init(world: CGSize, cellSize: CGFloat = 1) {
        self.cellSize = cellSize
        width = max(8, Int(world.width / cellSize))
        height = max(8, Int(world.height / cellSize))
        cells = Array(repeating: 1, count: width * height)
        scuff = Array(repeating: 0, count: width * height)
    }

    var fraction: Float { cells.reduce(0, +) / Float(cells.count) }

    func markClean() { dirty = false }
    func markCracksClean() { cracksDirty = false }

    private func noise() -> Float {
        rng = rng &* 1664525 &+ 1013904223
        return Float(rng >> 8) / Float(1 << 24)
    }

    /// A signed wobble of half-width `a`.
    private func wobble(_ a: Float) -> Float { (noise() - 0.5) * 2 * a }

    // MARK: - Reading the masks

    func ice(at p: CGPoint) -> Float {
        let x = Int(p.x / cellSize), y = Int(p.y / cellSize)
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return cells[y * width + x]
    }

    /// How wiped the frost is here: 0 untouched, 1 glassy.
    func scuffValue(at p: CGPoint) -> Float {
        let x = Int(p.x / cellSize), y = Int(p.y / cellSize)
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return scuff[y * width + x]
    }

    private func isIce(_ x: Float, _ y: Float) -> Bool {
        let ix = Int(x / Float(cellSize)), iy = Int(y / Float(cellSize))
        guard ix >= 0, iy >= 0, ix < width, iy < height else { return false }
        return cells[iy * width + ix] > 0.5
    }

    /// The nearest ice cell to a point, if any within `range`.
    func nearestIce(to p: CGPoint, range: CGFloat) -> CGPoint? {
        let cx = Int(p.x / cellSize), cy = Int(p.y / cellSize)
        let rr = Int(range / cellSize)
        var best: (Int, Int, Int)?
        let step = 2
        var y = max(0, cy - rr)
        while y <= min(height - 1, cy + rr) {
            var x = max(0, cx - rr)
            while x <= min(width - 1, cx + rr) {
                if cells[y * width + x] > 0.5 {
                    let d2 = (x - cx) * (x - cx) + (y - cy) * (y - cy)
                    if d2 <= rr * rr, best == nil || d2 < best!.2 { best = (x, y, d2) }
                }
                x += step
            }
            y += step
        }
        guard let b = best else { return nil }
        return CGPoint(x: (CGFloat(b.0) + 0.5) * cellSize, y: (CGFloat(b.1) + 0.5) * cellSize)
    }

    /// Is this point on the sheet but close to open water?
    func isEdge(at p: CGPoint, within: CGFloat) -> Bool {
        guard ice(at: p) > 0.5 else { return false }
        let cx = Int(p.x / cellSize), cy = Int(p.y / cellSize), rr = Int(within / cellSize)
        var y = max(0, cy - rr)
        while y <= min(height - 1, cy + rr) {
            var x = max(0, cx - rr)
            while x <= min(width - 1, cx + rr) {
                if cells[y * width + x] < 0.5 { return true }
                x += 2
            }
            y += 2
        }
        return false
    }

    // MARK: - The diagram

    /// Every seed a point could belong to: the seeds of the strikes whose
    /// centre lies within `ring × 3` of it. The GPU uses the same rule, so
    /// the CPU's idea of a shard and the drawn one always agree.
    func nearestSeed(at p: CGPoint) -> Int? {
        let px = Float(p.x), py = Float(p.y)
        var best = -1
        var bestD = Float.greatestFiniteMagnitude
        for (si, s) in strikes.enumerated() {
            let dx = px - s.centre.x, dy = py - s.centre.y
            let far = s.ring * 3.0
            guard dx * dx + dy * dy < far * far else { continue }
            for i in strikeSeeds[si] {
                let e = seeds[i].pos
                let ex = px - e.x, ey = py - e.y
                let d = ex * ex + ey * ey
                if d < bestD { bestD = d; best = i }
            }
        }
        return best >= 0 ? best : nil
    }

    /// How far this point is from the nearest visible crack, and how strong
    /// that crack is. The crack between two cells is their bisector: with `a`
    /// the nearest seed, the distance to the edge it shares with `b` is the
    /// distance from the point to the plane halfway between them.
    func crack(at p: CGPoint) -> (dist: Float, strength: Float) {
        guard !strikes.isEmpty, let ai = nearestSeed(at: p) else { return (1e9, 0) }
        let a = seeds[ai]
        let px = Float(p.x), py = Float(p.y)
        var best = Float.greatestFiniteMagnitude
        var bestStrength: Float = 0
        for (si, s) in strikes.enumerated() {
            let sdx = px - s.centre.x, sdy = py - s.centre.y
            let far = s.ring * 3.0
            guard sdx * sdx + sdy * sdy < far * far else { continue }
            for i in strikeSeeds[si] where i != ai {
                let b = seeds[i]
                let strength = max(a.strength, b.strength)
                guard strength > 0.01 else { continue }        // sheet meeting sheet: no crack
                let dx = b.pos.x - a.pos.x, dy = b.pos.y - a.pos.y
                let len = (dx * dx + dy * dy).squareRoot()
                guard len > 0.0001 else { continue }
                let mx = (a.pos.x + b.pos.x) * 0.5 - px, my = (a.pos.y + b.pos.y) * 0.5 - py
                let d = (mx * dx + my * dy) / len
                guard d < best else { continue }
                // The edge only shows within the reach of whichever of the two
                // seeds reaches further, measured from that seed's own strike.
                let outer = a.reach >= b.reach ? a : b
                let os = strikes[min(max(0, Int(outer.strike)), max(0, strikes.count - 1))]
                let odx = px - os.centre.x, ody = py - os.centre.y
                let limit = os.ring * outer.reach
                guard odx * odx + ody * ody < limit * limit else { continue }
                best = d
                bestStrength = strength
            }
        }
        return (best, bestStrength)
    }

    /// The most recent strike whose ring this point lies inside and which
    /// still has shards to give: a second tap there takes the whole of it out.
    func strikeIndex(containing p: CGPoint) -> Int? {
        let px = Float(p.x), py = Float(p.y)
        var i = strikes.count - 1
        while i >= 0 {
            let s = strikes[i]
            let dx = px - s.centre.x, dy = py - s.centre.y
            if dx * dx + dy * dy < s.ring * s.ring,
               strikeSeeds[i].contains(where: { seeds[$0].strength > 0.9 && seeds[$0].broken < 0.5 }) {
                return i
            }
            i -= 1
        }
        return nil
    }

    // MARK: - Striking

    /// A blow on the sheet. Seeds go down radially about the point: the
    /// shards they make are the pieces that will give way, the rim seeds are
    /// the sheet around them (their mutual edges never show), and the runners
    /// carry two or three of the spoke cracks far out past the hole, tapering.
    /// Returns the index of the strike.
    @discardableResult
    func strike(at p: CGPoint, ring: CGFloat, time: Float = 0) -> Int {
        prune()
        let index = strikes.count
        let start = seeds.count
        let r = Float(ring)
        let cx = Float(p.x), cy = Float(p.y)
        strikes.append(IceStrikeGPU(centre: SIMD2(cx, cy), ring: r, time: time))

        func add(_ x: Float, _ y: Float, _ strength: Float, _ reach: Float) {
            // A shard that would land in a hole already open is not there.
            if strength > 0.9, !isIce(x, y) { return }
            seeds.append(IceSeedGPU(pos: SIMD2(x, y), strength: strength, reach: reach,
                                    strike: Float(index), broken: 0))
        }

        // The seed at the blow itself, nudged a little, but never nudged off
        // the sheet: it is the shard the tap is meant to take out.
        var c0 = SIMD2(cx + wobble(3), cy + wobble(3))
        if !isIce(c0.x, c0.y) { c0 = SIMD2(cx, cy) }
        add(c0.x, c0.y, 1, 1.3)

        let n = 5 + Int(noise() * 3.999)                       // 5...8 spokes
        let base = noise() * 2 * .pi
        var spokes: [Float] = []
        for k in 0..<n {
            let a = base + Float(k) / Float(n) * 2 * .pi + wobble(0.35)
            spokes.append(a)
            for f in [Float(0.28), 0.58, 0.9] {
                let rr = r * f * (1 + wobble(0.2))
                let aa = a + wobble(0.12)
                add(cx + cos(aa) * rr, cy + sin(aa) * rr, 1, 1.3)
            }
        }
        // The rim: the sheet around the blow. Strength 0, so rim-to-rim edges
        // are invisible and the breakable region is an angular polygon, never
        // a circle.
        for k in 0..<n {
            let a1 = spokes[k]
            var a2 = spokes[(k + 1) % n]
            if a2 <= a1 { a2 += 2 * .pi }
            for a in [a1, (a1 + a2) * 0.5] {
                let rr = r * (1.35 + wobble(0.15))
                add(cx + cos(a) * rr, cy + sin(a) * rr, 0, 1.3)
            }
        }
        // Runners: a pair of seeds either side of a spoke, well out, whose
        // mutual edge continues that spoke's crack across the sheet.
        var used = Set<Int>()
        for _ in 0..<(2 + Int(noise() * 1.999)) {
            let k = min(n - 1, Int(noise() * Float(n)))
            guard used.insert(k).inserted else { continue }
            let a = spokes[k]
            for f in [Float(1.9), 2.5] {
                for side in [Float(-0.14), 0.14] {
                    add(cx + cos(a + side) * r * f, cy + sin(a + side) * r * f, 0.55, 2.8)
                }
            }
        }
        strikeSeeds.append(start..<seeds.count)
        dirty = true
        cracksDirty = true
        return index
    }

    /// The struck region gives way: every shard of the strike goes, and the
    /// mask opens over exactly those cells. Returns each shard that went, at
    /// its seed, with the area it covered, so one chunk can be spawned per
    /// shard.
    func breakOut(_ index: Int, time: Float = 0) -> [(centre: CGPoint, area: CGFloat)] {
        guard index >= 0, index < strikes.count else { return [] }
        let st = strikes[index]
        var brokenSeeds: [Int] = []
        for i in strikeSeeds[index] where seeds[i].strength > 0.9 && seeds[i].broken < 0.5 {
            seeds[i].broken = 1
            brokenSeeds.append(i)
        }
        guard !brokenSeeds.isEmpty else { return [] }

        // Only the strike's own box is rasterised: the shards cannot reach
        // further than their rim.
        let cs = Float(cellSize)
        let reach = st.ring * 1.4
        let x0 = max(0, Int((st.centre.x - reach) / cs)), x1 = min(width - 1, Int((st.centre.x + reach) / cs))
        let y0 = max(0, Int((st.centre.y - reach) / cs)), y1 = min(height - 1, Int((st.centre.y + reach) / cs))
        guard x0 <= x1, y0 <= y1 else { return [] }

        // The strikes whose seeds could win a cell anywhere in the box.
        var cand: [(cx: Float, cy: Float, farSq: Float, lo: Int, hi: Int)] = []
        for (si, s) in strikes.enumerated() {
            let far = s.ring * 3.0
            let dx = max(0, abs(s.centre.x - st.centre.x) - reach)
            let dy = max(0, abs(s.centre.y - st.centre.y) - reach)
            guard dx * dx + dy * dy < far * far else { continue }
            let range = strikeSeeds[si]
            guard !range.isEmpty else { continue }
            cand.append((s.centre.x, s.centre.y, far * far, range.lowerBound, range.upperBound))
        }

        var areas = [Int: Int]()
        var sunk: [Int32] = []
        let sinkStart = IceField.sinkStart
        seeds.withUnsafeBufferPointer { sp in
            cells.withUnsafeMutableBufferPointer { cp in
                func nearest(_ px: Float, _ py: Float) -> Int {
                    var best = -1
                    var bestD = Float.greatestFiniteMagnitude
                    for c in cand {
                        let sdx = px - c.cx, sdy = py - c.cy
                        if sdx * sdx + sdy * sdy >= c.farSq { continue }
                        var k = c.lo
                        while k < c.hi {
                            let e = sp[k].pos
                            let ex = px - e.x, ey = py - e.y
                            let d = ex * ex + ey * ey
                            if d < bestD { bestD = d; best = k }
                            k += 1
                        }
                    }
                    return best
                }
                // A Voronoi cell is convex, so a block of texels whose four
                // corners all belong to one seed belongs to it entirely: only
                // the blocks a shard edge crosses are walked texel by texel.
                let block = 8
                var by = y0
                while by <= y1 {
                    let by1 = min(y1, by + block - 1)
                    var bx = x0
                    while bx <= x1 {
                        let bx1 = min(x1, bx + block - 1)
                        let lx = (Float(bx) + 0.5) * cs, hx = (Float(bx1) + 0.5) * cs
                        let ly = (Float(by) + 0.5) * cs, hy = (Float(by1) + 0.5) * cs
                        let a = nearest(lx, ly)
                        let uniform = a >= 0 && nearest(hx, ly) == a && nearest(lx, hy) == a && nearest(hx, hy) == a
                        if uniform {
                            if sp[a].broken > 0.5 {
                                for y in by...by1 {
                                    let row = y * width
                                    for x in bx...bx1 where cp[row + x] >= 0.5 {
                                        cp[row + x] = sinkStart
                                        sunk.append(Int32(row + x))
                                        areas[a, default: 0] += 1
                                    }
                                }
                            }
                        } else {
                            for y in by...by1 {
                                let py = (Float(y) + 0.5) * cs
                                let row = y * width
                                for x in bx...bx1 {
                                    let i = row + x
                                    if cp[i] < 0.5 { continue }
                                    let best = nearest((Float(x) + 0.5) * cs, py)
                                    guard best >= 0, sp[best].broken > 0.5 else { continue }
                                    cp[i] = sinkStart
                                    sunk.append(Int32(i))
                                    areas[best, default: 0] += 1
                                }
                            }
                        }
                        bx += block
                    }
                    by += block
                }
            }
        }
        // Nothing small is left behind: any scrap of sheet the break has cut
        // off from the rest goes under with it.
        sunk += orphans(near: st.centre, within: st.ring * 2.4, maxArea: 12000)
        if !sunk.isEmpty { sinking.append((sunk, time)) }
        dirty = true
        cracksDirty = true
        let cellArea = cellSize * cellSize
        return brokenSeeds.compactMap { i in
            guard let n = areas[i], n > 0 else { return nil }
            let pos = seeds[i].pos
            return (CGPoint(x: CGFloat(pos.x), y: CGFloat(pos.y)), CGFloat(n) * cellArea)
        }
    }

    /// Islands of ice inside a box that are smaller than `maxArea` and do
    /// not reach the box's edge: they are marked sinking and returned.
    private func orphans(near c: SIMD2<Float>, within reach: Float, maxArea: Int) -> [Int32] {
        let cs = Float(cellSize)
        let x0 = max(0, Int((c.x - reach) / cs)), x1 = min(width - 1, Int((c.x + reach) / cs))
        let y0 = max(0, Int((c.y - reach) / cs)), y1 = min(height - 1, Int((c.y + reach) / cs))
        guard x0 < x1, y0 < y1 else { return [] }
        let bw = x1 - x0 + 1, bh = y1 - y0 + 1
        var seen = [Bool](repeating: false, count: bw * bh)
        var out: [Int32] = []
        var stack: [Int] = []
        var comp: [Int32] = []
        for ly in 0..<bh {
            for lx in 0..<bw {
                let li = ly * bw + lx
                if seen[li] { continue }
                seen[li] = true
                let gi = (y0 + ly) * width + (x0 + lx)
                if cells[gi] < 0.5 { continue }
                comp.removeAll(keepingCapacity: true)
                stack.removeAll(keepingCapacity: true)
                stack.append(li)
                var touchesEdge = false
                while let j = stack.popLast() {
                    let jx = j % bw, jy = j / bw
                    comp.append(Int32((y0 + jy) * width + (x0 + jx)))
                    if jx == 0 || jy == 0 || jx == bw - 1 || jy == bh - 1 { touchesEdge = true }
                    if comp.count > maxArea { break }
                    for (nx, ny) in [(jx - 1, jy), (jx + 1, jy), (jx, jy - 1), (jx, jy + 1)] {
                        guard nx >= 0, ny >= 0, nx < bw, ny < bh else { continue }
                        let ni = ny * bw + nx
                        if seen[ni] { continue }
                        seen[ni] = true
                        if cells[(y0 + ny) * width + (x0 + nx)] >= 0.5 { stack.append(ni) }
                    }
                }
                if comp.count > maxArea || touchesEdge {
                    // Too big to be a scrap: mark the rest of it seen and move on.
                    while let j = stack.popLast() {
                        let jx = j % bw, jy = j / bw
                        for (nx, ny) in [(jx - 1, jy), (jx + 1, jy), (jx, jy - 1), (jx, jy + 1)] {
                            guard nx >= 0, ny >= 0, nx < bw, ny < bh else { continue }
                            let ni = ny * bw + nx
                            if seen[ni] { continue }
                            seen[ni] = true
                            if cells[(y0 + ny) * width + (x0 + nx)] >= 0.5 { stack.append(ni) }
                        }
                    }
                    continue
                }
                for i in comp { cells[Int(i)] = IceField.sinkStart }
                out += comp
            }
        }
        return out
    }

    /// A tap on a small island of ice, one already cut off from the sheet,
    /// takes the whole island under in one go: it would be tedious to have
    /// to crack every scrap. Returns the island's area, or nil if the ice
    /// here is part of something larger than `maxArea`.
    func sinkIsland(at p: CGPoint, maxArea: Int, time: Float) -> CGFloat? {
        let x = Int(p.x / cellSize), y = Int(p.y / cellSize)
        guard x >= 0, y >= 0, x < width, y < height, cells[y * width + x] >= 0.5 else { return nil }
        var seen = Set<Int>()
        var stack = [y * width + x]
        var comp: [Int32] = []
        seen.insert(y * width + x)
        while let i = stack.popLast() {
            comp.append(Int32(i))
            if comp.count > maxArea { return nil }
            let cx = i % width, cy = i / width
            for (nx, ny) in [(cx - 1, cy), (cx + 1, cy), (cx, cy - 1), (cx, cy + 1)] {
                guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                let j = ny * width + nx
                if seen.contains(j) || cells[j] < 0.5 { continue }
                seen.insert(j)
                stack.append(j)
            }
        }
        for i in comp { cells[Int(i)] = IceField.sinkStart }
        sinking.append((comp, time))
        dirty = true
        return CGFloat(comp.count) * cellSize * cellSize
    }

    /// The level is done: whatever ice is left goes under with it.
    func sinkAll(time: Float) {
        var comp: [Int32] = []
        for i in 0..<cells.count where cells[i] >= 0.5 {
            cells[i] = IceField.sinkStart
            comp.append(Int32(i))
        }
        guard !comp.isEmpty else { return }
        sinking.append((comp, time))
        dirty = true
    }

    /// Once a frame: the broken shards go under. Their mask value falls
    /// from `sinkStart` to nothing over `sinkSeconds`, then they are gone.
    func settle(clock: Float) {
        guard !sinking.isEmpty else { return }
        var keep: [(cells: [Int32], start: Float)] = []
        cells.withUnsafeMutableBufferPointer { cp in
            for shard in sinking {
                let t = (clock - shard.start) / IceField.sinkSeconds
                if t >= 1 {
                    for i in shard.cells { cp[Int(i)] = 0 }
                } else {
                    let v = IceField.sinkStart * (1 - max(0, t))
                    for i in shard.cells { cp[Int(i)] = v }
                    keep.append(shard)
                }
            }
        }
        sinking = keep
        dirty = true
    }

    // MARK: - The finger on the sheet

    /// A finger dragged over the sheet wipes the frost off it.
    func paintScuff(at p: CGPoint, radius: CGFloat, amount: Float) {
        let cx = Int(p.x / cellSize), cy = Int(p.y / cellSize)
        let rr = max(1, Int(radius / cellSize))
        let x0 = max(0, cx - rr), x1 = min(width - 1, cx + rr)
        let y0 = max(0, cy - rr), y1 = min(height - 1, cy + rr)
        guard x0 <= x1, y0 <= y1 else { return }
        let fr = Float(rr)
        for y in y0...y1 {
            let dy = Float(y - cy)
            let row = y * width
            for x in x0...x1 {
                let dx = Float(x - cx)
                let d2 = (dx * dx + dy * dy) / (fr * fr)
                if d2 > 1 { continue }
                let fall = 1 - d2                       // soft at the rim
                let i = row + x
                scuff[i] = min(1, scuff[i] + amount * fall)
            }
        }
        dirty = true
    }

    // MARK: - Housekeeping

    /// The GPU holds a fixed number of seeds and strikes. Long after a hole
    /// opens its cracks are of no interest, so the oldest strike goes first.
    private func prune() {
        while strikes.count > 1, seeds.count > seedCap - 96 || strikes.count >= strikeCap {
            let range = strikeSeeds[0]
            let n = range.count
            seeds.removeSubrange(range)
            strikes.removeFirst()
            strikeSeeds.removeFirst()
            for i in 0..<strikeSeeds.count {
                strikeSeeds[i] = (strikeSeeds[i].lowerBound - n)..<(strikeSeeds[i].upperBound - n)
            }
            for i in 0..<seeds.count { seeds[i].strike -= 1 }
        }
    }
}
