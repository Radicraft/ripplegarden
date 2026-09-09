import Metal
import MetalKit
import simd

/// Rubbish that has to read as a body rather than a cut-out: a can, a
/// bottle. Everything else on the pond is paper, but a can that bends with
/// the water looks wrong, so these few things get a real mesh, toon shaded
/// with an ink rim so they still sit in the woodblock print.
///
/// Layout mirrors `SolidInstance` in Shaders.metal.
struct SolidInstance {
    var position: SIMD2<Float>   // world points on the water plane
    var lift: Float              // points above the plane the axis sits
    var yaw: Float               // heading of the long axis on the plane
    var roll: Float              // rotation about the long axis
    var tilt: SIMD2<Float>       // surface slope under it, the body banks with it
    var length: Float            // points
    var radius: Float            // points
    var shape: UInt32            // 0 can, 1 bottle
    var alpha: Float
    var colourA: SIMD4<Float>    // main body colour
    var colourB: SIMD4<Float>    // band / cap colour
}

/// Mirrors `SolidParams` in Shaders.metal.
struct SolidParams {
    /// xyz direction toward the light, in the sprites' screen frame.
    var light: SIMD4<Float>
    /// rgb woodblock line colour.
    var ink: SIMD4<Float>
    /// x slope to bank gain, y far plane in points, z specular gain, w rim width.
    var gains: SIMD4<Float>
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
    /// 0 body, 1 metal end, 2 clear neck, 3 cap.
    var part: Float
    /// 0 on the axis, 1 at the widest point of this ring.
    var rad: Float
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
    static let maxInstances = 256

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
                                                      (3, .float, 28), (4, .float, 32), (5, .float, 36)]
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
        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        guard let ds = device.makeDepthStencilState(descriptor: dd) else { return nil }
        depthState = ds

        var verts: [SolidVertex] = []
        var idx: [UInt16] = []
        var built: [(offset: Int, count: Int, baseVertex: Int)] = []
        for (v, i) in [SolidMesh.can(), SolidMesh.bottle()] {
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

    /// Uploads the bodies and draws them, in runs by shape.
    func draw(_ solids: [SolidInstance], encoder: MTLRenderCommandEncoder,
              params: SolidParams, camera: inout CameraParams) {
        guard !solids.isEmpty else { return }
        // Grouped so one draw call covers every body of the same shape.
        let sorted = solids.sorted { $0.shape < $1.shape }
        let count = min(sorted.count, SolidBatch.maxInstances)
        instanceBuffer.contents().withMemoryRebound(to: SolidInstance.self, capacity: count) { ptr in
            for i in 0..<count { ptr[i] = sorted[i] }
        }

        var p = params
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 1)
        encoder.setVertexBytes(&p, length: MemoryLayout<SolidParams>.stride, index: 2)
        encoder.setVertexBytes(&camera, length: MemoryLayout<CameraParams>.stride, index: 4)
        encoder.setFragmentBytes(&p, length: MemoryLayout<SolidParams>.stride, index: 0)

        var runStart = 0
        while runStart < count {
            let shape = Int(sorted[runStart].shape)
            var runEnd = runStart + 1
            while runEnd < count, Int(sorted[runEnd].shape) == shape { runEnd += 1 }
            if shape < ranges.count {
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
