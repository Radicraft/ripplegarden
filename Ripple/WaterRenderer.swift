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
    var nonlinearity: Float
    var splatCount: UInt32
}

struct RenderParams {
    var size: SIMD2<UInt32>
    var viewport: SIMD2<Float>
    var refraction: Float
    var causticGain: Float
    var specGain: Float
    var time: Float
    var crestGain: Float
    var sparkleGain: Float
    var detailGain: Float
    var dispersion: Float
}

struct FloorParams {
    var viewport: SIMD2<Float>
}

/// Every number worth arguing about, in one place.
enum Tuning {

    // --- simulation ---------------------------------------------------------

    /// Cells along the longer screen axis. Higher is crisper and slower.
    static let gridLongSide = 640

    /// Wave speed squared. Must stay below 0.5 or the simulation explodes.
    static let c2: Float = 0.28

    /// How much a crest outruns a trough. This is what makes two ripples
    /// collide rather than pass through each other untouched. Above about 0.9
    /// the steepening turns into visible chop.
    static let nonlinearity: Float = 0.55

    /// Fraction of velocity kept each step. Closer to 1.0 means longer-lived ripples.
    static let damping: Float = 0.9968

    /// Extra damping in the border band, so the basin does not ring forever.
    static let edgeDamp: Float = 0.90
    static let edgeBand: UInt32 = 12

    /// Simulation steps per SECOND, not per frame. Stepping per frame ties
    /// wave speed to the refresh rate, so water crawled at 60fps and sped up at
    /// 120, and slowed down again on any dropped frame. Wave speed is a design
    /// constant; it must not depend on how busy the GPU is.
    static let simStepsPerSecond: Double = 240

    /// Ceiling on catch-up steps after a stall, so a hitch cannot cascade.
    static let maxStepsPerFrame = 8

    // --- touch --------------------------------------------------------------

    /// A quick tap.
    static let tapRadius: Float = 13
    static let tapAmplitude: Float = -0.42

    /// The rebound crown a real droplet throws up, a moment after the dip.
    static let reboundDelay: TimeInterval = 0.075
    static let reboundScale: Float = -0.34   // negative of a negative: upward

    /// Holding still presses a bowl into the water. It deepens and widens the
    /// longer you hold, up to a cap, and rebounds into a big slow swell on lift.
    static let holdChargeSeconds: Float = 1.1   // time to reach a full charge
    static let holdPressRate: Float = 1.5       // depth added per second at full press
    static let holdRadiusGrowth: Float = 2.6    // radius multiplier at full charge
    static let holdReleaseKick: Float = 0.55    // extra shove on lift, scaled by charge

    /// Contact-patch size read from the touch, mapped to a 0...1 weight. This is
    /// area, not force; 3D Touch is gone on current hardware.
    static let radiusWeightRange: ClosedRange<CGFloat> = 7.0...22.0
    static let weightAmplitudeRange: ClosedRange<Float> = 0.82...1.45
    static let weightRadiusRange: ClosedRange<Float> = 0.88...1.30

    /// A drag lays a fainter trail, one splat per this many points travelled.
    static let dragSpacing: CGFloat = 9
    static let dragAmplitude: Float = -0.20
    static let dragRadius: Float = 10

    /// Movement beyond this many points cancels a charge. You cannot press and
    /// sweep at the same time.
    static let chargeCancelDistance: CGFloat = 6

    // --- ambience -----------------------------------------------------------

    /// A faint, very wide disturbance now and then, so untouched water is never
    /// perfectly dead.
    static let breezeEnabled = true
    static let breezeInterval: ClosedRange<TimeInterval> = 1.6...4.2
    static let breezeAmplitude: Float = -0.022
    static let breezeRadius: ClosedRange<Float> = 45...95

    // --- rendering ----------------------------------------------------------

    static let refraction: Float = 0.090
    static let causticGain: Float = 36.0
    static let specGain: Float = 0.90
    static let crestGain: Float = 0.30
    static let sparkleGain: Float = 0.55
    static let detailGain: Float = 26.0
    static let dispersion: Float = 0.22

    static let maxSplatsPerFrame = 96
}

/// A finger currently down: where it is, and how long it has been still.
private struct Hold {
    var position: CGPoint
    var viewSize: CGSize
    var weight: Float
    var charge: Float = 0      // 0...1
}

final class WaterRenderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let simPipeline: MTLComputePipelineState
    private let drawPipeline: MTLRenderPipelineState
    private let floorPipeline: MTLRenderPipelineState

    private var fieldA: MTLTexture?
    private var fieldB: MTLTexture?
    private var floorTexture: MTLTexture?
    private var needsFloorBake = true

    private var gridSize = SIMD2<UInt32>(0, 0)
    private var viewportSize = SIMD2<Float>(0, 0)

    private var splatBuffer: MTLBuffer
    private var pendingSplats: [Splat] = []
    private var scheduledSplats: [(fireAt: TimeInterval, splat: Splat)] = []

    private var holds: [Int: Hold] = [:]

    private let startTime = CACurrentMediaTime()
    private var lastFrameTime = CACurrentMediaTime()
    private var simAccumulator: Double = 0

    /// `-fps` prints a frame-time summary once a second. Off by default; this
    /// is the only way to tell a genuine 120fps from a capped simulation.
    private let logFrames = ProcessInfo.processInfo.arguments.contains("-fps")
    private var statWindowStart = CACurrentMediaTime()
    private var statFrames = 0
    private var statSteps = 0
    private var statWorstFrame: Double = 0
    private var nextBreezeTime = CACurrentMediaTime() + 1.5

    /// Called when a charged press is released, so the view can fire haptics.
    var onChargedRelease: ((Float) -> Void)?

    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }

        guard let stepFn = library.makeFunction(name: "wave_step"),
              let vertFn = library.makeFunction(name: "fullscreen_vertex"),
              let fragFn = library.makeFunction(name: "water_fragment"),
              let floorFn = library.makeFunction(name: "floor_fragment") else { return nil }

        do {
            simPipeline = try device.makeComputePipelineState(function: stepFn)

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertFn
            desc.fragmentFunction = fragFn
            desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            drawPipeline = try device.makeRenderPipelineState(descriptor: desc)

            let floorDesc = MTLRenderPipelineDescriptor()
            floorDesc.vertexFunction = vertFn
            floorDesc.fragmentFunction = floorFn
            floorDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            floorPipeline = try device.makeRenderPipelineState(descriptor: floorDesc)
        } catch {
            print("pipeline creation failed: \(error)")
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

    /// Maps a touch's contact-patch radius to a 0...1 weight.
    static func weight(forMajorRadius r: CGFloat) -> Float {
        let range = Tuning.radiusWeightRange
        let t = (r - range.lowerBound) / (range.upperBound - range.lowerBound)
        return Float(min(max(t, 0), 1))
    }

    private func lerp(_ range: ClosedRange<Float>, _ t: Float) -> Float {
        range.lowerBound + (range.upperBound - range.lowerBound) * t
    }

    private func cell(for point: CGPoint, in size: CGSize) -> SIMD2<Float>? {
        guard size.width > 0, size.height > 0, gridSize.x > 0 else { return nil }
        return SIMD2<Float>(Float(point.x / size.width) * Float(gridSize.x),
                            Float(point.y / size.height) * Float(gridSize.y))
    }

    func addSplat(at point: CGPoint, in size: CGSize, radius: Float, amplitude: Float) {
        guard pendingSplats.count < Tuning.maxSplatsPerFrame,
              let c = cell(for: point, in: size) else { return }
        pendingSplats.append(Splat(pos: c, radius: radius, amplitude: amplitude))
    }

    /// A finger goes down: an immediate dip, a droplet rebound just after, and
    /// the start of a charge if the finger stays put.
    func touchDown(id: Int, at point: CGPoint, in size: CGSize, weight w: Float) {
        let amp = Tuning.tapAmplitude * lerp(Tuning.weightAmplitudeRange, w)
        let rad = Tuning.tapRadius * lerp(Tuning.weightRadiusRange, w)

        addSplat(at: point, in: size, radius: rad, amplitude: amp)

        if let c = cell(for: point, in: size) {
            scheduledSplats.append((CACurrentMediaTime() + Tuning.reboundDelay,
                                    Splat(pos: c,
                                          radius: rad * 0.62,
                                          amplitude: amp * Tuning.reboundScale)))
        }
        holds[id] = Hold(position: point, viewSize: size, weight: w)
    }

    /// The finger moved. Lays a trail and cancels any charge in progress.
    func touchMoved(id: Int, to point: CGPoint, in size: CGSize) {
        guard var hold = holds[id] else { return }
        let dx = point.x - hold.position.x, dy = point.y - hold.position.y
        let distance = (dx * dx + dy * dy).squareRoot()

        if distance > Tuning.chargeCancelDistance { hold.charge = 0 }
        guard distance >= Tuning.dragSpacing else {
            holds[id] = hold
            return
        }

        // Lay splats along the segment so a fast flick draws a wake rather than
        // a dotted line.
        let steps = min(Int(distance / Tuning.dragSpacing), 8)
        for i in 1...max(steps, 1) {
            let t = CGFloat(i) / CGFloat(max(steps, 1))
            let q = CGPoint(x: hold.position.x + dx * t, y: hold.position.y + dy * t)
            addSplat(at: q, in: size, radius: Tuning.dragRadius, amplitude: Tuning.dragAmplitude)
        }
        hold.position = point
        hold.viewSize = size
        holds[id] = hold
    }

    /// The finger lifts. A charged bowl gets a shove on the way up, which is
    /// what turns a long press into a big slow swell.
    func touchUp(id: Int) {
        guard let hold = holds.removeValue(forKey: id) else { return }
        guard hold.charge > 0.05 else { return }

        let rad = Tuning.tapRadius * (1.0 + Tuning.holdRadiusGrowth * hold.charge)
        let amp = Tuning.tapAmplitude * Tuning.holdReleaseKick * hold.charge
        addSplat(at: hold.position, in: hold.viewSize, radius: rad, amplitude: amp)
        onChargedRelease?(hold.charge)
    }

    func cancelAll() { holds.removeAll() }

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
              let floorTexture,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer() else { return }

        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastFrameTime, 1.0 / 20.0))
        lastFrameTime = now

        if logFrames { recordFrame(now: now, dt: Double(dt)) }
        accumulateHolds(dt: dt)
        releaseScheduledSplats(now: now)
        maybeBreeze(now: now)

        // --- bake the floor, once per resize ---------------------------------

        if needsFloorBake {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = floorTexture
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
                var fp = FloorParams(viewport: viewportSize)
                encoder.setRenderPipelineState(floorPipeline)
                encoder.setFragmentBytes(&fp, length: MemoryLayout<FloorParams>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
            needsFloorBake = false
        }

        // --- simulate ---------------------------------------------------------

        simAccumulator += Double(dt)
        var steps = Int(simAccumulator * Tuning.simStepsPerSecond)
        if steps > Tuning.maxStepsPerFrame {
            steps = Tuning.maxStepsPerFrame
            simAccumulator = 0
        } else {
            simAccumulator -= Double(steps) / Tuning.simStepsPerSecond
        }

        // Touches queued during a frame that ran no steps must survive to the
        // next one, or a tap lands on nothing.
        var count = 0
        if steps > 0 {
            count = min(pendingSplats.count, Tuning.maxSplatsPerFrame)
            if count > 0 {
                splatBuffer.contents()
                    .withMemoryRebound(to: Splat.self, capacity: count) { ptr in
                        for i in 0..<count { ptr[i] = pendingSplats[i] }
                    }
            }
            pendingSplats.removeAll(keepingCapacity: true)
        }

        var read = src
        var write = dst

        for step in 0..<steps {
            // Touches are injected once, on the first substep only.
            var params = SimParams(size: gridSize,
                                   c2: Tuning.c2,
                                   damping: Tuning.damping,
                                   edgeDamp: Tuning.edgeDamp,
                                   edgeBand: Tuning.edgeBand,
                                   nonlinearity: Tuning.nonlinearity,
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

        statSteps += steps
        fieldA = read
        fieldB = write

        // --- draw -------------------------------------------------------------

        var rp = RenderParams(size: gridSize,
                              viewport: viewportSize,
                              refraction: Tuning.refraction,
                              causticGain: Tuning.causticGain,
                              specGain: Tuning.specGain,
                              time: Float(now - startTime),
                              crestGain: Tuning.crestGain,
                              sparkleGain: Tuning.sparkleGain,
                              detailGain: Tuning.detailGain,
                              dispersion: Tuning.dispersion)

        if let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) {
            encoder.setRenderPipelineState(drawPipeline)
            encoder.setFragmentTexture(read, index: 0)
            encoder.setFragmentTexture(floorTexture, index: 1)
            encoder.setFragmentBytes(&rp, length: MemoryLayout<RenderParams>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        commands.present(drawable)
        commands.commit()
    }

    private func recordFrame(now: TimeInterval, dt: Double) {
        statFrames += 1
        statWorstFrame = max(statWorstFrame, dt)
        let elapsed = now - statWindowStart
        guard elapsed >= 1.0 else { return }

        let fps = Double(statFrames) / elapsed
        let stepsPerSecond = Double(statSteps) / elapsed
        print(String(format: "[ripple] %.1f fps | %.0f sim steps/s (target %.0f) | worst frame %.1f ms",
                     fps, stepsPerSecond, Tuning.simStepsPerSecond, statWorstFrame * 1000))

        statWindowStart = now
        statFrames = 0
        statSteps = 0
        statWorstFrame = 0
    }

    // MARK: - Per-frame input work

    /// A finger resting on the surface keeps pressing it down. The charge
    /// approaches 1 rather than running away, so the bowl settles at a depth
    /// instead of drilling a hole.
    private func accumulateHolds(dt: Float) {
        guard !holds.isEmpty else { return }
        for (id, var hold) in holds {
            hold.charge = min(1.0, hold.charge + dt / Tuning.holdChargeSeconds)

            let press = Tuning.holdPressRate * dt * (1.0 - hold.charge * 0.65)
            let radius = Tuning.tapRadius * (1.0 + Tuning.holdRadiusGrowth * hold.charge)
            addSplat(at: hold.position, in: hold.viewSize,
                     radius: radius,
                     amplitude: -press * lerp(Tuning.weightAmplitudeRange, hold.weight))

            holds[id] = hold
        }
    }

    private func releaseScheduledSplats(now: TimeInterval) {
        guard !scheduledSplats.isEmpty else { return }
        var remaining: [(fireAt: TimeInterval, splat: Splat)] = []
        for entry in scheduledSplats {
            if entry.fireAt <= now {
                if pendingSplats.count < Tuning.maxSplatsPerFrame { pendingSplats.append(entry.splat) }
            } else {
                remaining.append(entry)
            }
        }
        scheduledSplats = remaining
    }

    private func maybeBreeze(now: TimeInterval) {
        guard Tuning.breezeEnabled, now >= nextBreezeTime, gridSize.x > 0 else { return }
        nextBreezeTime = now + TimeInterval.random(in: Tuning.breezeInterval)

        let pos = SIMD2<Float>(Float.random(in: 0...Float(gridSize.x)),
                               Float.random(in: 0...Float(gridSize.y)))
        pendingSplats.append(Splat(pos: pos,
                                   radius: Float.random(in: Tuning.breezeRadius),
                                   amplitude: Tuning.breezeAmplitude))
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
                                                            width: w, height: h,
                                                            mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        fieldA = device.makeTexture(descriptor: desc)
        fieldB = device.makeTexture(descriptor: desc)

        // The floor is static, so it is baked once, at full resolution. Baking
        // it at half size blurred the grain into fog.
        let floorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: max(2, Int(size.width)),
            height: max(2, Int(size.height)),
            mipmapped: false)
        floorDesc.usage = [.shaderRead, .renderTarget]
        floorDesc.storageMode = .private
        floorTexture = device.makeTexture(descriptor: floorDesc)
        needsFloorBake = true

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
