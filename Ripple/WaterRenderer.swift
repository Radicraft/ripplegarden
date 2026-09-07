import Metal
import MetalKit
import simd

// Layouts below must stay in step with the structs in Shaders.metal.

struct Splat {
    var pos: SIMD2<Float>
    var radius: Float
    var amplitude: Float
}

struct SimParams {
    var size: SIMD2<UInt32>
    var c2: Float
    var damping: Float
    var edgeDamp: Float
    var edgeBand: UInt32
    var splatCount: UInt32
}

struct RenderParams {
    var size: SIMD2<UInt32>
    var viewport: SIMD2<Float>
    var refraction: Float
    var causticGain: Float
    var specGain: Float
    var time: Float
}

/// Every number worth arguing about, in one place.
enum Tuning {
    /// Cells along the longer screen axis. Higher is crisper and slower.
    static let gridLongSide = 640

    /// Wave speed squared. Must stay below 0.5 or the simulation explodes.
    static let c2: Float = 0.28

    /// Fraction of velocity kept each step. Closer to 1.0 means longer-lived ripples.
    static let damping: Float = 0.9965

    /// Extra damping in the border band, so the basin does not ring forever.
    static let edgeDamp: Float = 0.90
    static let edgeBand: UInt32 = 12

    /// Simulation steps per displayed frame. Raises apparent wave speed.
    static let substeps = 2

    /// A finger press, in cells and in height.
    static let tapRadius: Float = 14
    static let tapAmplitude: Float = -0.50

    /// A drag lays a fainter trail, one splat per this many points travelled.
    static let dragSpacing: CGFloat = 9
    static let dragAmplitude: Float = -0.22
    static let dragRadius: Float = 11

    static let refraction: Float = 0.085
    static let causticGain: Float = 34.0
    static let specGain: Float = 0.85

    static let maxSplatsPerFrame = 64
}

final class WaterRenderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let simPipeline: MTLComputePipelineState
    private let drawPipeline: MTLRenderPipelineState

    private var fieldA: MTLTexture?
    private var fieldB: MTLTexture?
    private var gridSize = SIMD2<UInt32>(0, 0)
    private var viewportSize = SIMD2<Float>(0, 0)

    private var splatBuffer: MTLBuffer
    private var pendingSplats: [Splat] = []

    private var startTime = CACurrentMediaTime()

    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }

        guard let stepFn = library.makeFunction(name: "wave_step"),
              let vertFn = library.makeFunction(name: "fullscreen_vertex"),
              let fragFn = library.makeFunction(name: "water_fragment") else { return nil }

        do {
            simPipeline = try device.makeComputePipelineState(function: stepFn)
        } catch {
            print("compute pipeline failed: \(error)")
            return nil
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertFn
        desc.fragmentFunction = fragFn
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        do {
            drawPipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            print("render pipeline failed: \(error)")
            return nil
        }

        guard let buf = device.makeBuffer(length: MemoryLayout<Splat>.stride * Tuning.maxSplatsPerFrame,
                                          options: .storageModeShared) else { return nil }
        splatBuffer = buf

        self.device = device
        self.queue = queue
        super.init()
    }

    // MARK: - Input

    /// `point` is in view coordinates; `size` is the view's bounds size.
    func addSplat(at point: CGPoint, in size: CGSize, radius: Float, amplitude: Float) {
        guard size.width > 0, size.height > 0, gridSize.x > 0 else { return }
        guard pendingSplats.count < Tuning.maxSplatsPerFrame else { return }

        let u = Float(point.x / size.width)
        let v = Float(point.y / size.height)
        let cell = SIMD2<Float>(u * Float(gridSize.x), v * Float(gridSize.y))
        pendingSplats.append(Splat(pos: cell, radius: radius, amplitude: amplitude))
    }

    func reset() {
        if let a = fieldA { zero(a) }
        if let b = fieldB { zero(b) }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        allocate(for: size)
    }

    func draw(in view: MTKView) {
        guard let src = fieldA, let dst = fieldB,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer() else { return }

        // --- simulate -------------------------------------------------------

        let count = min(pendingSplats.count, Tuning.maxSplatsPerFrame)
        if count > 0 {
            splatBuffer.contents()
                .withMemoryRebound(to: Splat.self, capacity: count) { ptr in
                    for i in 0..<count { ptr[i] = pendingSplats[i] }
                }
        }
        pendingSplats.removeAll(keepingCapacity: true)

        var read = src
        var write = dst

        for step in 0..<Tuning.substeps {
            // Touches are injected once, on the first substep only.
            var params = SimParams(size: gridSize,
                                   c2: Tuning.c2,
                                   damping: Tuning.damping,
                                   edgeDamp: Tuning.edgeDamp,
                                   edgeBand: Tuning.edgeBand,
                                   splatCount: step == 0 ? UInt32(count) : 0)

            guard let encoder = commands.makeComputeCommandEncoder() else { break }
            encoder.setComputePipelineState(simPipeline)
            encoder.setTexture(read, index: 0)
            encoder.setTexture(write, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<SimParams>.stride, index: 0)
            encoder.setBuffer(splatBuffer, offset: 0, index: 1)

            let w = simPipeline.threadExecutionWidth
            let h = max(1, simPipeline.maxTotalThreadsPerThreadgroup / w)
            encoder.dispatchThreads(MTLSize(width: Int(gridSize.x), height: Int(gridSize.y), depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
            encoder.endEncoding()

            swap(&read, &write)
        }

        // `read` now holds the newest state.
        fieldA = read
        fieldB = write

        // --- draw -----------------------------------------------------------

        var rp = RenderParams(size: gridSize,
                              viewport: viewportSize,
                              refraction: Tuning.refraction,
                              causticGain: Tuning.causticGain,
                              specGain: Tuning.specGain,
                              time: Float(CACurrentMediaTime() - startTime))

        if let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) {
            encoder.setRenderPipelineState(drawPipeline)
            encoder.setFragmentTexture(read, index: 0)
            encoder.setFragmentBytes(&rp, length: MemoryLayout<RenderParams>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        commands.present(drawable)
        commands.commit()
    }

    // MARK: - Resources

    private func allocate(for size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }

        let aspect = size.width / size.height
        let long = CGFloat(Tuning.gridLongSide)
        let w: Int, h: Int
        if aspect >= 1 {
            w = Int(long)
            h = max(2, Int((long / aspect).rounded()))
        } else {
            h = Int(long)
            w = max(2, Int((long * aspect).rounded()))
        }

        gridSize = SIMD2<UInt32>(UInt32(w), UInt32(h))
        viewportSize = SIMD2<Float>(Float(size.width), Float(size.height))

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float,
                                                            width: w,
                                                            height: h,
                                                            mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared

        fieldA = device.makeTexture(descriptor: desc)
        fieldB = device.makeTexture(descriptor: desc)
        reset()
    }

    private func zero(_ texture: MTLTexture) {
        let bytesPerRow = texture.width * MemoryLayout<Float>.size * 2
        let blank = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        blank.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, texture.width, texture.height),
                            mipmapLevel: 0,
                            withBytes: raw.baseAddress!,
                            bytesPerRow: bytesPerRow)
        }
    }
}
