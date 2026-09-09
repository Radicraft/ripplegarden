import Metal
import MetalKit
import simd

/// Anything that has to read as a body rather than a cut-out: a can, a
/// bottle, a stone, a log. Everything else on the pond is paper, but a can
/// that bends with the water looks wrong and a stone drawn flat reads as a
/// disc pasted on the pond, so these few things get a real mesh, toon shaded
/// with an ink rim so they still sit in the woodblock print.
///
/// Layout mirrors `SolidInstance` in Shaders.metal.
struct SolidInstance {
    var position: SIMD2<Float>   // world points on the water plane
    /// Points above the plane the axis sits. Negative puts the body under
    /// the water, where it is drawn into the floor instead.
    var lift: Float
    /// Heading of the long axis on the plane. A koi swims along its spine
    /// rather than a heading, so its slot carries the wag phase instead.
    var yaw: Float
    /// Rotation about the long axis. A stone does not roll, so its slot
    /// carries the seed of its lumps instead; a koi's is how far it banks.
    var roll: Float
    /// Which of the batch's textures paints the body, 1 based. 0 = none.
    var texture: UInt32 = 0
    /// Surface slope under it, the body banks with it. A koi has no slope
    /// to sit on, so x is its wag amplitude instead.
    var tilt: SIMD2<Float>
    var length: Float            // points
    var radius: Float            // points
    var shape: UInt32            // 0 can, 1 bottle, 2 stone, 3 log, 4 disc, 5 koi
    var alpha: Float
    var colourA: SIMD4<Float>    // main body colour
    var colourB: SIMD4<Float>    // band / cap / moss / cut wood colour
    /// Which spine in the shared buffer bends this body, or -1 for a body
    /// that stands on its own axis.
    var spine: Int32 = -1
    var pad0: Float = 0
    var pad1: Float = 0
    var pad2: Float = 0
}

/// Mirrors `SolidParams` in Shaders.metal.
struct SolidParams {
    /// xyz direction toward the light, in the sprites' screen frame. w is
    /// points per unit of depth, for the haze on a body under the water.
    var light: SIMD4<Float>
    /// rgb woodblock line colour.
    var ink: SIMD4<Float>
    /// x slope to bank gain, y far plane in points, z specular gain, w rim width.
    var gains: SIMD4<Float>
    /// x: 1 draws into the floor's own texture, where a body under the water
    /// is laid at the point the line of sight crosses the surface, so the
    /// water refracts and lights it like everything else on the bed. yzw is
    /// the colour the pond swallows a deep body into.
    var flags: SIMD4<Float> = .zero
}

/// One mesh vertex. Positions are normalised: x runs -0.5 to 0.5 along the
/// long axis, y and z sit on the unit circle, and the shader scales them by
/// the instance's length and radius. Normals are the normals of that
/// normalised shape; the shader divides them by the same scale, which is
/// what turns them back into the normals of the real body.
struct SolidVertex {
    var px: Float, py: Float, pz: Float
    var nx: Float, ny: Float, nz: Float
    /// 0 at one end of the axis, 1 at the other.
    var v: Float
    /// Angle around the axis, 0 to 2 pi.
    var ang: Float
    /// 0 body, 1 metal end / sawn end, 2 clear neck, 3 cap.
    var part: Float
    /// 0 on the axis, 1 at the widest point of this ring.
    var rad: Float
    /// How far this vertex was pushed out of the smooth shape, -1 to 1. The
    /// bark ridges carry it; the fragment darkens the crevices with it. A
    /// stone's is worked out in the shader, since its lumps are per stone.
    var bump: Float = 0
}

/// A ring of the turned profile: where it sits along the axis, how wide it
/// is, and what it is made of.
private struct Ring {
    var v: Float
    var radius: Float
    var part: Float
}

/// Builds the two bodies as surfaces of revolution and hands them to the
/// batch as one buffer with a range per shape.
enum SolidMesh {

    static let segments = 24

    /// A can: a straight tube with a chamfer into a flat lid at each end.
    /// Its natural proportion is 2.2 long for 1 across; the instance can
    /// stretch it.
    static func can() -> ([SolidVertex], [UInt16]) {
        let rings = [Ring(v: 0.00, radius: 0.86, part: 1),
                     Ring(v: 0.035, radius: 1.00, part: 1),
                     Ring(v: 0.06, radius: 1.00, part: 0),
                     Ring(v: 0.94, radius: 1.00, part: 0),
                     Ring(v: 0.965, radius: 1.00, part: 1),
                     Ring(v: 1.00, radius: 0.86, part: 1)]
        return revolve(rings, capStart: true, capEnd: true)
    }

    /// A bottle: body, a short cone shoulder, a narrower neck, a cap.
    static func bottle() -> ([SolidVertex], [UInt16]) {
        let rings = [Ring(v: 0.00, radius: 0.90, part: 0),
                     Ring(v: 0.03, radius: 1.00, part: 0),
                     Ring(v: 0.56, radius: 1.00, part: 0),
                     Ring(v: 0.71, radius: 0.42, part: 0),
                     Ring(v: 0.73, radius: 0.40, part: 2),
                     Ring(v: 0.90, radius: 0.40, part: 2),
                     Ring(v: 0.905, radius: 0.50, part: 3),
                     Ring(v: 1.00, radius: 0.50, part: 3)]
        return revolve(rings, capStart: true, capEnd: true)
    }

    static let stoneSegments = 20
    static let stoneRings = 14
    /// How flat a stone is: the up axis of the body against its width.
    static let stoneFlatten: Float = 0.65

    /// A stone: a lat/long sphere squashed into an ellipsoid. The lumps are
    /// not in this mesh. They are noise the vertex shader adds, seeded per
    /// stone off the instance, so a pond full of stones is a pond full of
    /// different stones out of the one buffer. The shader rebuilds these
    /// same proportions in `stonePoint`, so the two have to agree.
    static func stone() -> ([SolidVertex], [UInt16]) {
        var verts: [SolidVertex] = []
        var idx: [UInt16] = []
        let cols = stoneSegments + 1
        for i in 0..<stoneRings {
            let v = Float(i) / Float(stoneRings - 1)
            let phi = v * Float.pi
            let ring = sin(phi), axial = -cos(phi)
            for s in 0...stoneSegments {
                let a = Float(s) / Float(stoneSegments) * 2 * Float.pi
                let u = SIMD3<Float>(axial, cos(a) * ring, sin(a) * ring)
                let p = SIMD3<Float>(u.x * 0.5, u.y, u.z * stoneFlatten)
                // Normal of the ellipsoid: each axis divided by its own
                // half-width squared.
                let n = simd_normalize(SIMD3<Float>(p.x / 0.25, p.y, p.z / (stoneFlatten * stoneFlatten)))
                verts.append(SolidVertex(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z,
                                         v: v, ang: a, part: 0, rad: ring))
            }
        }
        for i in 0..<(stoneRings - 1) {
            for s in 0..<stoneSegments {
                let a = UInt16(i * cols + s), b = a + 1
                let c = UInt16((i + 1) * cols + s), d = c + 1
                idx += [a, c, b, b, c, d]
            }
        }
        return (verts, idx)
    }

    /// A log: a cylinder tapered toward one end, with bark. The bark is thin
    /// ridges running the length of it plus a slow wander in thickness, baked
    /// into the mesh, so every log is cut from the same piece of wood. Each
    /// end is a sawn disc; the fragment draws the grain on it.
    static func log() -> ([SolidVertex], [UInt16]) {
        let rows = 16, cols = segments + 1
        var verts: [SolidVertex] = []
        var idx: [UInt16] = []

        // Taper: 15 percent thinner at the far end.
        func profile(_ v: Float) -> Float { 1 - 0.15 * v }
        // Ridged noise: the creases of the ridges are where the noise peaks.
        // The ridges drift a little along the log so they are not dead
        // straight, and the bulge is the trunk's own thickness wandering.
        func bark(_ v: Float, _ ang: Float) -> Float {
            let twist = ang + v * 0.45
            let ridge = 1 - abs(2 * ringNoise(twist, period: 17, seed: 3) - 1)
            let fine = 1 - abs(2 * ringNoise(twist, period: 37, seed: 11) - 1)
            let bulge = axisNoise(v * 3.5, seed: 5)
            return (ridge - 0.5) * 1.4 + (fine - 0.5) * 0.6 + (bulge - 0.5) * 0.7
        }

        var pos = [SIMD3<Float>](repeating: .zero, count: rows * cols)
        var bumps = [Float](repeating: 0, count: rows * cols)
        var normals = [SIMD3<Float>](repeating: .zero, count: rows * cols)
        for i in 0..<rows {
            let v = Float(i) / Float(rows - 1)
            for s in 0...segments {
                let a = Float(s) / Float(segments) * 2 * Float.pi
                let b = bark(v, a)
                let r = profile(v) * (1 + 0.055 * b)
                pos[i * cols + s] = SIMD3(v - 0.5, cos(a) * r, sin(a) * r)
                bumps[i * cols + s] = b
            }
        }
        // Normals are the average of the faces round each vertex, since the
        // bark has no profile to take a slope from.
        for i in 0..<(rows - 1) {
            for s in 0..<segments {
                let a = i * cols + s, b = a + 1
                let c = (i + 1) * cols + s, d = c + 1
                for tri in [(a, c, b), (b, c, d)] {
                    let n = simd_cross(pos[tri.1] - pos[tri.0], pos[tri.2] - pos[tri.0])
                    normals[tri.0] += n
                    normals[tri.1] += n
                    normals[tri.2] += n
                }
                idx += [UInt16(a), UInt16(c), UInt16(b), UInt16(b), UInt16(c), UInt16(d)]
            }
        }
        // The seam column is the same edge as the first, so they share a
        // normal and no line shows down the length of the log.
        for i in 0..<rows {
            let n = normals[i * cols] + normals[i * cols + segments]
            normals[i * cols] = n
            normals[i * cols + segments] = n
        }
        for i in 0..<rows {
            let v = Float(i) / Float(rows - 1)
            for s in 0...segments {
                let k = i * cols + s
                let p = pos[k]
                var n = normals[k]
                // Outward is away from the axis, whichever way the faces wound.
                if simd_dot(n, SIMD3<Float>(0, p.y, p.z)) < 0 { n = -n }
                n = simd_length(n) > 1e-6 ? simd_normalize(n) : SIMD3(0, p.y, p.z)
                verts.append(SolidVertex(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z,
                                         v: v, ang: Float(s) / Float(segments) * 2 * Float.pi,
                                         part: 0, rad: 1, bump: bumps[k]))
            }
        }

        // The sawn ends. Their own vertices, so the disc is square to the
        // axis, and the rim follows the bark so the silhouette closes.
        func end(_ v: Float, facing: Float) {
            let centre = UInt16(verts.count)
            verts.append(SolidVertex(px: v - 0.5, py: 0, pz: 0, nx: facing, ny: 0, nz: 0,
                                     v: v, ang: 0, part: 1, rad: 0))
            for s in 0...segments {
                let a = Float(s) / Float(segments) * 2 * Float.pi
                let r = profile(v) * (1 + 0.055 * bark(v, a))
                verts.append(SolidVertex(px: v - 0.5, py: cos(a) * r, pz: sin(a) * r,
                                         nx: facing, ny: 0, nz: 0,
                                         v: v, ang: a, part: 1, rad: 1))
            }
            for s in 0..<segments {
                let a = centre + 1 + UInt16(s)
                idx += [centre, a, a + 1]
            }
        }
        end(0, facing: -1)
        end(1, facing: 1)
        return (verts, idx)
    }

    static let discCapRings = 4

    /// A thin disc: a lily pad, a bud on it, a bell on its float. The axis is
    /// the thickness, so the instance's `length` is how thick it is and its
    /// `radius` how wide. The top is a shallow dome and carries the painting;
    /// the rim and the underside are plain.
    static func disc() -> ([SolidVertex], [UInt16]) {
        var verts: [SolidVertex] = []
        var idx: [UInt16] = []
        // Dome height in thickness units: a pad three points thick stands
        // about one and a half proud at the middle.
        func dome(_ r: Float) -> Float { 0.5 + 0.55 * (1 - r * r) }

        var rows: [Int] = []
        for i in 0...discCapRings {
            let rr = Float(i) / Float(discCapRings)
            rows.append(verts.count)
            for s in 0...segments {
                let a = Float(s) / Float(segments) * 2 * Float.pi
                // The dome's slope, turned into the normal of it.
                let n = simd_normalize(SIMD3<Float>(1, 1.1 * rr * cos(a), 1.1 * rr * sin(a)))
                verts.append(SolidVertex(px: dome(rr), py: cos(a) * rr, pz: sin(a) * rr,
                                         nx: n.x, ny: n.y, nz: n.z, v: 0, ang: a, part: 0, rad: rr))
            }
        }
        for i in 0..<discCapRings {
            for s in 0..<segments {
                let a = UInt16(rows[i] + s), b = a + 1
                let c = UInt16(rows[i + 1] + s), d = c + 1
                idx += [a, c, b, b, c, d]
            }
        }

        // The rim, standing straight down from the edge of the dome.
        let rimTop = verts.count
        for (k, px) in [dome(1), Float(-0.5)].enumerated() {
            for s in 0...segments {
                let a = Float(s) / Float(segments) * 2 * Float.pi
                verts.append(SolidVertex(px: px, py: cos(a), pz: sin(a),
                                         nx: 0, ny: cos(a), nz: sin(a), v: Float(k), ang: a, part: 1, rad: 1))
            }
        }
        for s in 0..<segments {
            let a = UInt16(rimTop + s), b = a + 1
            let c = UInt16(rimTop + segments + 1 + s), d = c + 1
            idx += [a, c, b, b, c, d]
        }

        // The underside: a flat disc, its own normal, its own colour.
        let centre = UInt16(verts.count)
        verts.append(SolidVertex(px: -0.5, py: 0, pz: 0, nx: -1, ny: 0, nz: 0, v: 1, ang: 0, part: 2, rad: 0))
        for s in 0...segments {
            let a = Float(s) / Float(segments) * 2 * Float.pi
            verts.append(SolidVertex(px: -0.5, py: cos(a), pz: sin(a), nx: -1, ny: 0, nz: 0,
                                     v: 1, ang: a, part: 2, rad: 1))
        }
        for s in 0..<segments {
            let a = centre + 1 + UInt16(s)
            idx += [centre, a, a + 1]
        }
        return (verts, idx)
    }

    static let koiRings = 20
    static let koiSegments = 12
    /// How much thinner a fish is top to bottom than side to side.
    static let koiFlatten: Float = 0.8

    /// A koi's body: a spindle turned along its length, flattened a little.
    /// `v` runs 0 at the tail to 1 at the nose, which is the same way the
    /// spine samples run, so the vertex shader lays each ring on the path the
    /// head actually swam. `ang` is measured from the back, so the painting
    /// wraps round the body from the spine down to the belly on either side.
    static func koi() -> ([SolidVertex], [UInt16]) {
        let rows = koiRings, cols = koiSegments + 1
        var verts: [SolidVertex] = []
        var idx: [UInt16] = []

        // Widest a little behind the shoulder, nothing at the nose, a thin
        // stalk at the tail.
        func profile(_ v: Float) -> Float {
            if v >= 0.6 {
                let t = (1 - v) / 0.4
                return 0.5 * pow(sin(t * Float.pi / 2), 0.8)
            }
            return 0.15 + 0.35 * pow(v / 0.6, 0.7)
        }

        var pos = [SIMD3<Float>](repeating: .zero, count: rows * cols)
        var normals = [SIMD3<Float>](repeating: .zero, count: rows * cols)
        for i in 0..<rows {
            let v = Float(i) / Float(rows - 1)
            let r = profile(v)
            for s in 0...koiSegments {
                let a = Float(s) / Float(koiSegments) * 2 * Float.pi
                pos[i * cols + s] = SIMD3(v - 0.5, sin(a) * r, cos(a) * r * koiFlatten)
            }
        }
        for i in 0..<(rows - 1) {
            for s in 0..<koiSegments {
                let a = i * cols + s, b = a + 1
                let c = (i + 1) * cols + s, d = c + 1
                for tri in [(a, c, b), (b, c, d)] {
                    let n = simd_cross(pos[tri.1] - pos[tri.0], pos[tri.2] - pos[tri.0])
                    normals[tri.0] += n
                    normals[tri.1] += n
                    normals[tri.2] += n
                }
                idx += [UInt16(a), UInt16(c), UInt16(b), UInt16(b), UInt16(c), UInt16(d)]
            }
        }
        // The seam column is the same edge as the first: one normal between
        // them, or a line shows down the fish.
        for i in 0..<rows {
            let n = normals[i * cols] + normals[i * cols + koiSegments]
            normals[i * cols] = n
            normals[i * cols + koiSegments] = n
        }
        for i in 0..<rows {
            let v = Float(i) / Float(rows - 1)
            for s in 0...koiSegments {
                let k = i * cols + s
                let p = pos[k]
                var n = normals[k]
                if simd_dot(n, SIMD3<Float>(0, p.y, p.z)) < 0 { n = -n }
                n = simd_length(n) > 1e-6 ? simd_normalize(n) : SIMD3(0, p.y, p.z)
                verts.append(SolidVertex(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z,
                                         v: v, ang: Float(s) / Float(koiSegments) * 2 * Float.pi,
                                         part: 0, rad: 1))
            }
        }

        // The tail end is cut off square, so nothing is seen inside it.
        let r0 = profile(0)
        let centre = UInt16(verts.count)
        verts.append(SolidVertex(px: -0.5, py: 0, pz: 0, nx: -1, ny: 0, nz: 0, v: 0, ang: 0, part: 1, rad: 0))
        for s in 0...koiSegments {
            let a = Float(s) / Float(koiSegments) * 2 * Float.pi
            verts.append(SolidVertex(px: -0.5, py: sin(a) * r0, pz: cos(a) * r0 * koiFlatten,
                                     nx: -1, ny: 0, nz: 0, v: 0, ang: a, part: 1, rad: 1))
        }
        for s in 0..<koiSegments {
            let a = centre + 1 + UInt16(s)
            idx += [centre, a, a + 1]
        }
        return (verts, idx)
    }

    /// Value noise round a circle: `period` samples spread over the turn and
    /// smoothly joined, so the seam meets itself.
    private static func ringNoise(_ ang: Float, period: Int, seed: UInt32) -> Float {
        let t = ang / (2 * Float.pi) * Float(period)
        let i = Int(floor(t))
        let f = t - Float(i)
        let s = f * f * (3 - 2 * f)
        func at(_ k: Int) -> Float { hash(UInt32(((k % period) + period) % period), seed) }
        return at(i) + (at(i + 1) - at(i)) * s
    }

    /// Value noise along a line, for anything that wanders down the axis.
    private static func axisNoise(_ t: Float, seed: UInt32) -> Float {
        let i = Int(floor(t))
        let f = t - Float(i)
        let s = f * f * (3 - 2 * f)
        let a = hash(UInt32(bitPattern: Int32(i)), seed)
        let b = hash(UInt32(bitPattern: Int32(i + 1)), seed)
        return a + (b - a) * s
    }

    private static func hash(_ i: UInt32, _ seed: UInt32) -> Float {
        var x = i &* 374761393 &+ seed &* 668265263
        x = (x ^ (x >> 13)) &* 1274126177
        return Float((x ^ (x >> 16)) & 0xFFFF) / 65535
    }

    /// Turns a profile on a lathe. Each ring gets `segments + 1` vertices so
    /// the seam has its own pair and the angle runs a clean 0 to 2 pi.
    private static func revolve(_ rings: [Ring], capStart: Bool, capEnd: Bool) -> ([SolidVertex], [UInt16]) {
        var verts: [SolidVertex] = []
        var idx: [UInt16] = []
        let cols = segments + 1

        // Slope of the profile at each ring, for the normal. A ring shared by
        // two spans takes the span it faces, so a chamfer keeps its own edge.
        for (i, r) in rings.enumerated() {
            let prev = rings[max(0, i - 1)], next = rings[min(rings.count - 1, i + 1)]
            let dv = (i == 0) ? (next.v - r.v) : (r.v - prev.v)
            let dr = (i == 0) ? (next.radius - r.radius) : (r.radius - prev.radius)
            let slope = dv > 1e-6 ? dr / dv : 0
            for s in 0...segments {
                let a = Float(s) / Float(segments) * 2 * Float.pi
                let cy = cos(a), cz = sin(a)
                // The surface is y^2 + z^2 = R(x)^2, so the normal leans back
                // along the axis by the profile's slope.
                let n = simd_normalize(SIMD3<Float>(-slope, cy, cz))
                verts.append(SolidVertex(px: r.v - 0.5, py: cy * r.radius, pz: cz * r.radius,
                                         nx: n.x, ny: n.y, nz: n.z,
                                         v: r.v, ang: a, part: r.part, rad: 1))
            }
        }
        for i in 0..<(rings.count - 1) {
            for s in 0..<segments {
                let a = UInt16(i * cols + s), b = a + 1
                let c = UInt16((i + 1) * cols + s), d = c + 1
                idx += [a, c, b, b, c, d]
            }
        }

        // Flat lids. A centre vertex plus its own ring, so the lid's normal
        // is square to the axis and does not smear into the wall.
        func lid(_ r: Ring, facing: Float) {
            let centre = UInt16(verts.count)
            verts.append(SolidVertex(px: r.v - 0.5, py: 0, pz: 0, nx: facing, ny: 0, nz: 0,
                                     v: r.v, ang: 0, part: r.part, rad: 0))
            for s in 0...segments {
                let a = Float(s) / Float(segments) * 2 * Float.pi
                verts.append(SolidVertex(px: r.v - 0.5, py: cos(a) * r.radius, pz: sin(a) * r.radius,
                                         nx: facing, ny: 0, nz: 0,
                                         v: r.v, ang: a, part: r.part, rad: 1))
            }
            for s in 0..<segments {
                let a = centre + 1 + UInt16(s)
                idx += [centre, a, a + 1]
            }
        }
        if capStart, let first = rings.first { lid(first, facing: -1) }
        if capEnd, let last = rings.last { lid(last, facing: 1) }
        return (verts, idx)
    }
}

/// Draws the solid bodies, one draw call per run of the same shape. Built in
/// the style of `SpriteBatch`: one instance buffer filled per frame, one
/// pipeline, no per-piece state.
final class SolidBatch {
    static let maxInstances = 1024

    let pipeline: MTLRenderPipelineState
    let depthState: MTLDepthStencilState
    private let vertexBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer
    private let instanceBuffer: MTLBuffer
    /// Per shape: where its indices start, how many there are, and the vertex
    /// its indices are relative to.
    private let ranges: [(offset: Int, count: Int, baseVertex: Int)]

    init?(device: MTLDevice, library: MTLLibrary, pixelFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) {
        guard let vfn = library.makeFunction(name: "solid_vertex"),
              let ffn = library.makeFunction(name: "solid_fragment") else { print("solid functions missing"); return nil }

        let vdesc = MTLVertexDescriptor()
        let formats: [(Int, MTLVertexFormat, Int)] = [(0, .float3, 0), (1, .float3, 12), (2, .float, 24),
                                                      (3, .float, 28), (4, .float, 32), (5, .float, 36),
                                                      (6, .float, 40)]
        for (i, format, offset) in formats {
            vdesc.attributes[i].format = format
            vdesc.attributes[i].offset = offset
            vdesc.attributes[i].bufferIndex = 0
        }
        vdesc.layouts[0].stride = MemoryLayout<SolidVertex>.stride

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.vertexDescriptor = vdesc
        desc.colorAttachments[0].pixelFormat = pixelFormat
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        desc.depthAttachmentPixelFormat = depthFormat
        do { pipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { print("solid pipeline failed: \(error)"); return nil }

        // The solids are the only thing in the frame that has to sort against
        // itself, so they are the only thing that reads and writes depth.
        // Equal passes, so a crossfade drawn as two bodies in the same place
        // (a bud closing over a bud opening) still shows both.
        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .lessEqual
        dd.isDepthWriteEnabled = true
        guard let ds = device.makeDepthStencilState(descriptor: dd) else { return nil }
        depthState = ds

        var verts: [SolidVertex] = []
        var idx: [UInt16] = []
        var built: [(offset: Int, count: Int, baseVertex: Int)] = []
        for (v, i) in [SolidMesh.can(), SolidMesh.bottle(), SolidMesh.stone(), SolidMesh.log(),
                       SolidMesh.disc(), SolidMesh.koi()] {
            built.append((offset: idx.count * MemoryLayout<UInt16>.stride, count: i.count, baseVertex: verts.count))
            verts += v
            idx += i
        }
        ranges = built

        guard let vb = device.makeBuffer(bytes: verts, length: MemoryLayout<SolidVertex>.stride * verts.count, options: .storageModeShared),
              let ib = device.makeBuffer(bytes: idx, length: MemoryLayout<UInt16>.stride * idx.count, options: .storageModeShared),
              let inst = device.makeBuffer(length: MemoryLayout<SolidInstance>.stride * SolidBatch.maxInstances, options: .storageModeShared)
        else { return nil }
        vertexBuffer = vb
        indexBuffer = ib
        instanceBuffer = inst
    }

    /// Uploads the bodies and draws them, in runs by shape and painting.
    /// `textures` is the batch's small painting list, indexed 1 based by the
    /// instance; `blank` fills the slot for a body that wears none, since a
    /// draw with nothing bound there is an error.
    private var cursor = 0

    /// Called once a frame before any draw: the instance buffer starts over.
    func beginFrame() { cursor = 0 }

    func draw(_ solids: [SolidInstance], encoder: MTLRenderCommandEncoder,
              params: SolidParams, camera: inout CameraParams,
              spines: MTLBuffer, textures: [MTLTexture] = [], blank: MTLTexture? = nil) {
        guard !solids.isEmpty else { return }
        // Grouped so one draw call covers every body of the same shape wearing
        // the same painting. Each draw in a frame takes its own stretch of the
        // instance buffer, or a later draw would overwrite an earlier one
        // before the GPU had drawn it.
        let sorted = solids.sorted { ($0.shape, $0.texture) < ($1.shape, $1.texture) }
        let count = min(sorted.count, SolidBatch.maxInstances - cursor)
        guard count > 0 else { return }
        let base = cursor
        cursor += count
        instanceBuffer.contents().advanced(by: base * MemoryLayout<SolidInstance>.stride)
            .withMemoryRebound(to: SolidInstance.self, capacity: count) { ptr in
            for i in 0..<count { ptr[i] = sorted[i] }
        }

        var p = params
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(instanceBuffer, offset: base * MemoryLayout<SolidInstance>.stride, index: 1)
        encoder.setVertexBytes(&p, length: MemoryLayout<SolidParams>.stride, index: 2)
        encoder.setVertexBuffer(spines, offset: 0, index: 3)
        encoder.setVertexBytes(&camera, length: MemoryLayout<CameraParams>.stride, index: 4)
        encoder.setFragmentBytes(&p, length: MemoryLayout<SolidParams>.stride, index: 0)

        var runStart = 0
        while runStart < count {
            let shape = Int(sorted[runStart].shape)
            let tex = sorted[runStart].texture
            var runEnd = runStart + 1
            while runEnd < count, Int(sorted[runEnd].shape) == shape, sorted[runEnd].texture == tex { runEnd += 1 }
            // Something is always bound: the fragment names a painting
            // whether or not this body wears one.
            let painting = (tex > 0 && Int(tex) <= textures.count) ? textures[Int(tex) - 1] : blank
            if let painting { encoder.setFragmentTexture(painting, index: 0) }
            if shape < ranges.count, painting != nil {
                let r = ranges[shape]
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: r.count, indexType: .uint16,
                                              indexBuffer: indexBuffer, indexBufferOffset: r.offset,
                                              instanceCount: runEnd - runStart, baseVertex: r.baseVertex,
                                              baseInstance: runStart)
            }
            runStart = runEnd
        }
    }
}
