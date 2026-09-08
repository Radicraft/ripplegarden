import Metal
import MetalKit
import simd
import os

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
    var shallowSpeed: Float
    var wallCount: UInt32
    var pad0: Float = 0
    var pad1: Float = 0
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
    var waterTint: SIMD4<Float>
    var style: SIMD4<Float>
    var inkColour: SIMD4<Float>
    var view: SIMD4<Float>
    var world: SIMD4<Float>
}

struct FloorParams {
    var viewport: SIMD4<Float>
    var deep: SIMD4<Float>
    var mid: SIMD4<Float>
    var shallow: SIMD4<Float>
    var mosaic: SIMD4<Float>
    var siltColour: SIMD4<Float>
    var camera: SIMD4<Float>
    var bed: SIMD4<Float>
    var view: SIMD4<Float>
}

struct SiltParams {
    var viewport: SIMD4<Float>
    var size: SIMD4<Float>
    var gains: SIMD4<Float>
    var mosaic: SIMD4<Float>
    var coverCount: UInt32
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
    var pad2: UInt32 = 0
}

enum WaterStyle {
    case photographic, woodblock
}

/// What the pond floor looks like this level.
struct FloorLook {
    var deep: SIMD3<Float>
    var mid: SIMD3<Float>
    var shallow: SIMD3<Float>
    var waterTint: SIMD3<Float>
    var waterTintStrength: Float
    var siltColour: SIMD3<Float>
    var mosaicCentre: SIMD2<Float>
    var mosaicRadius: Float
    var mosaicImage: String
    /// The painted pond bed, if the season has one.
    var bedImage: String = ""

    static let plain = FloorLook(deep: [0.012, 0.046, 0.066], mid: [0.036, 0.120, 0.142],
                                 shallow: [0.082, 0.208, 0.226], waterTint: [1, 1, 1],
                                 waterTintStrength: 0, siltColour: [0.35, 0.33, 0.26],
                                 mosaicCentre: [0.5, 0.5], mosaicRadius: 0, mosaicImage: "")
}

/// Mirrors `CameraParams` in Shaders.metal.
struct CameraParams {
    var position: SIMD4<Float>
    var right: SIMD4<Float>
    var down: SIMD4<Float>
    var forward: SIMD4<Float>
    var focal: SIMD4<Float>
    var world: SIMD4<Float>
}

struct FieldSample {
    var height: Float
    var slope: SIMD2<Float>
    var velocity: Float
}

enum Tuning {
    static let gridLongSide = 640
    static let c2: Float = 0.28
    static let nonlinearity: Float = 0.55
    static let damping: Float = 0.9968
    static let edgeDamp: Float = 0.90
    static let edgeBand: UInt32 = 12
    static let shallowSpeed: Float = 0.30
    static let simStepsPerSecond: Double = 240
    static let maxStepsPerFrame = 8

    static let tapRadius: Float = 13
    static let tapAmplitude: Float = -0.42
    static let reboundDelay: TimeInterval = 0.075
    static let reboundScale: Float = -0.34
    static let holdChargeSeconds: Float = 1.1
    static let holdPressRate: Float = 1.5
    static let holdRadiusGrowth: Float = 2.6
    static let holdReleaseKick: Float = 0.55
    static let radiusWeightRange: ClosedRange<CGFloat> = 7.0...22.0
    static let weightAmplitudeRange: ClosedRange<Float> = 0.82...1.45
    static let weightRadiusRange: ClosedRange<Float> = 0.88...1.30
    static let dragSpacing: CGFloat = 9
    static let dragAmplitude: Float = -0.20
    static let dragRadius: Float = 10
    static let chargeCancelDistance: CGFloat = 6
    static let swellRadius: Float = 20
    static let swellAmplitudePerPoint: Float = -0.012
    static let swellAmplitudeCap: Float = -0.16
    static let swellSpacing: Float = 12

    static let breezeEnabled = true
    static let breezeInterval: ClosedRange<TimeInterval> = 1.6...4.2
    static let breezeAmplitude: Float = -0.022
    static let breezeRadius: ClosedRange<Float> = 45...95

    static let refraction: Float = 0.090
    static let causticGain: Float = 36.0
    static let specGain: Float = 0.90
    static let crestGain: Float = 0.30
    static let sparkleGain: Float = 0.55
    static let detailGain: Float = 26.0
    static let dispersion: Float = 0.22

    /// Silt: how strongly wave energy scours, the activity floor below which
    /// nothing happens (so the breeze never cleans the tile), and the pace.
    static let siltHeightGain: Float = 6.0
    static let siltLaplacianGain: Float = 30.0
    static let siltThreshold: Float = 0.14
    static let siltRate: Float = 0.9
    static let siltLongSide = 448
    static let siltReadEveryFrames = 12

    /// Floater response to the surface: lift per unit height difference,
    /// slide per unit slope, the height rise that counts as wet, bob gain.
    static let floaterLift: Float = 90
    static let floaterTilt: Float = 60
    static let floaterWetThreshold: Float = 0.05
    static let floaterBob: Float = 0.9

    static let maxSplatsPerFrame = 96
    static let maxProbes = 96
    static let maxWalls = 16
    static let maxCovers = 64
    static let maxSpines = 8
}

private struct Hold {
    var position: CGPoint
    var viewSize: CGSize
    var weight: Float
    var charge: Float = 0
    var order: Int
}

final class WaterRenderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let simPipeline: MTLComputePipelineState
    private let probePipeline: MTLComputePipelineState
    private let siltPipeline: MTLComputePipelineState
    private let siltSumPipeline: MTLComputePipelineState
    private let drawPipeline: MTLRenderPipelineState
    private let floorBasePipeline: MTLRenderPipelineState
    private let floorComposePipeline: MTLRenderPipelineState
    private let floorBatch: SpriteBatch
    private let surfaceBatch: SpriteBatch
    let textures: TextureCache

    private var fieldA: MTLTexture?
    private var fieldB: MTLTexture?
    private var depthTexture: MTLTexture?
    private var floorBase: MTLTexture?
    private var floorTexture: MTLTexture?
    private var siltA: MTLTexture?
    private var siltB: MTLTexture?
    private var mosaicTexture: MTLTexture?
    private var blankMosaic: MTLTexture?
    private var needsFloorBake = true
    private var needsSiltReset = true

    private(set) var gridSize = SIMD2<UInt32>(0, 0)
    /// The view's bounds in points, known once the first frame draws.
    private(set) var viewSizePoints: CGSize?
    /// The pond is bigger than the screen; the view looks at part of it.
    static let worldScale: CGFloat = 1.4
    var worldSizePoints: CGSize? {
        viewSizePoints.map { CGSize(width: $0.width * WaterRenderer.worldScale, height: $0.height * WaterRenderer.worldScale) }
    }
    /// Screen points per world point, and the world point at the screen centre.
    var zoom: Float = 0.9
    var viewCentre = SIMD2<Float>(0, 0)
    private var viewCentreSet = false
    private var viewportSize = SIMD2<Float>(0, 0)
    private var screenPixels = SIMD2<Float>(0, 0)
    private var siltSize = SIMD2<Int>(0, 0)

    private var splatBuffer: MTLBuffer
    private var pendingSplats: [Splat] = []
    private var scheduledSplats: [(fireAt: TimeInterval, splat: Splat)] = []

    private var probeBuffer: MTLBuffer
    private var resultBuffer: MTLBuffer
    private var probeCount = 0
    private let resultLock = OSAllocatedUnfairLock(initialState: [SIMD4<Float>]())

    private var wallBuffer: MTLBuffer
    private var coverBuffer: MTLBuffer
    private var siltRowBuffer: MTLBuffer
    private var spineBuffer: MTLBuffer
    private let siltLock = OSAllocatedUnfairLock(initialState: Float(1))
    private var frameIndex = 0

    private var holds: [Int: Hold] = [:]
    private var holdOrder = 0
    private var swellLast: (a: CGPoint, b: CGPoint)?
    private var swellActive = false

    private let startTime = CACurrentMediaTime()
    private var lastFrameTime = CACurrentMediaTime()
    private var simAccumulator: Double = 0

    private let logFrames = ProcessInfo.processInfo.arguments.contains("-fps")
    private var statWindowStart = CACurrentMediaTime()
    private var statFrames = 0
    private var statSteps = 0
    private var statWorstFrame: Double = 0
    private var nextBreezeTime = CACurrentMediaTime() + 1.5

    // --- what the game sets ---------------------------------------------------

    var style: WaterStyle = .photographic
    var onChargedRelease: ((Float) -> Void)?
    var onSwellStart: (() -> Void)?
    var onFrame: ((Float) -> Void)?
    var depthPainter: ((Int, Int) -> [Float])?

    var floorLook = FloorLook.plain {
        didSet {
            loadMosaic(named: floorLook.mosaicImage)
            bedTexture = floorLook.bedImage.isEmpty ? nil : textures.texture(floorLook.bedImage)
            needsFloorBake = true
        }
    }
    private var bedTexture: MTLTexture?

    /// Lateral camera offset in points. The surface stays fixed on screen;
    /// everything above or below it parallaxes against it.
    var camera = SIMD2<Float>(0, 0)
    /// Camera height above the surface, in units where surface to bed is 1.
    static let cameraHeight: Float = 4.5
    static let cameraShiftGain: Float = 3.0
    /// The pitched camera: how far off vertical it looks, how far away it
    /// sits, and how many points a pond unit of depth is.
    static let cameraPitch: Float = 0.32
    static let cameraDistance: Float = 1500
    static let depthScale: Float = 260

    /// The camera for this frame, from the view centre, the zoom and the
    /// small orbit the breath and the phone's tilt give it.
    func cameraParams(screenPoints: SIMD2<Float>, worldPoints: SIMD2<Float>) -> CameraParams {
        let pitch = WaterRenderer.cameraPitch + camera.y * 0.0012
        let yaw = camera.x * 0.0018
        let dist = WaterRenderer.cameraDistance
        let V = SIMD3(viewCentre.x, viewCentre.y, 0)
        let C = V + dist * SIMD3(sin(pitch) * sin(yaw), sin(pitch) * cos(yaw), cos(pitch))
        let f = simd_normalize(V - C)
        let r = simd_normalize(simd_cross(SIMD3<Float>(0, 0, 1), f))
        let d = simd_normalize(simd_cross(r, f))
        return CameraParams(position: SIMD4(C, 0), right: SIMD4(r, 0), down: SIMD4(d, 0), forward: SIMD4(f, 0),
                            focal: SIMD4(zoom * dist, WaterRenderer.depthScale, screenPoints.x, screenPoints.y),
                            world: SIMD4(worldPoints.x, worldPoints.y, 0, 0))
    }

    /// Screen point to the surface point under it.
    func worldPoint(screen: CGPoint) -> CGPoint {
        guard let sp = viewSizePoints, let wp = worldSizePoints else { return screen }
        let c = cameraParams(screenPoints: SIMD2(Float(sp.width), Float(sp.height)), worldPoints: SIMD2(Float(wp.width), Float(wp.height)))
        let o = (SIMD2(Float(screen.x), Float(screen.y)) - SIMD2(Float(sp.width), Float(sp.height)) * 0.5) / c.focal.x
        let dir = SIMD3(c.forward.x, c.forward.y, c.forward.z) + SIMD3(c.right.x, c.right.y, c.right.z) * o.x + SIMD3(c.down.x, c.down.y, c.down.z) * o.y
        let t = -c.position.z / min(dir.z, -0.05)
        let P = SIMD3(c.position.x, c.position.y, c.position.z) + dir * t
        return CGPoint(x: CGFloat(P.x), y: CGFloat(P.y))
    }

    /// Surface point to screen point.
    func screenPoint(world: CGPoint) -> CGPoint {
        guard let sp = viewSizePoints, let wp = worldSizePoints else { return world }
        let c = cameraParams(screenPoints: SIMD2(Float(sp.width), Float(sp.height)), worldPoints: SIMD2(Float(wp.width), Float(wp.height)))
        let d = SIMD3(Float(world.x), Float(world.y), 0) - SIMD3(c.position.x, c.position.y, c.position.z)
        let depth = max(simd_dot(d, SIMD3(c.forward.x, c.forward.y, c.forward.z)), 1)
        let sx = simd_dot(d, SIMD3(c.right.x, c.right.y, c.right.z)) * c.focal.x / depth + Float(sp.width) / 2
        let sy = simd_dot(d, SIMD3(c.down.x, c.down.y, c.down.z)) * c.focal.x / depth + Float(sp.height) / 2
        return CGPoint(x: CGFloat(sx), y: CGFloat(sy))
    }

    /// Heavy floaters and rocks that waves should bounce off, in points.
    var walls: [(centre: CGPoint, radius: CGFloat)] = []
    /// Things shading the floor from the scouring, in unit uv with radius as
    /// a fraction of height.
    var siltCovers: [SIMD4<Float>] = []
    /// Sprites drawn into the floor (under the water) and over it, per frame.
    var submergedSprites: [Sprite] = []
    var surfaceSprites: [Sprite] = []
    /// 13 points per spined sprite: xy position in points, zw unit tangent
    /// toward the head; row 12 is the head.
    var spines: [SIMD4<Float>] = []

    /// Fraction of silt left over the mosaic, 1 = untouched. Updated a few
    /// times a second.
    var siltRemaining: Float { siltLock.withLock { $0 } }
    private var siltArea: Float = 1

    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }

        guard let stepFn = library.makeFunction(name: "wave_step"),
              let probeFn = library.makeFunction(name: "sample_field"),
              let siltFn = library.makeFunction(name: "silt_erode"),
              let siltSumFn = library.makeFunction(name: "silt_rowsum"),
              let vertFn = library.makeFunction(name: "fullscreen_vertex"),
              let fragFn = library.makeFunction(name: "water_fragment"),
              let baseFn = library.makeFunction(name: "floor_base_fragment"),
              let composeFn = library.makeFunction(name: "floor_compose_fragment") else { return nil }

        do {
            simPipeline = try device.makeComputePipelineState(function: stepFn)
            probePipeline = try device.makeComputePipelineState(function: probeFn)
            siltPipeline = try device.makeComputePipelineState(function: siltFn)
            siltSumPipeline = try device.makeComputePipelineState(function: siltSumFn)

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertFn
            desc.fragmentFunction = fragFn
            desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            drawPipeline = try device.makeRenderPipelineState(descriptor: desc)

            let baseDesc = MTLRenderPipelineDescriptor()
            baseDesc.vertexFunction = vertFn
            baseDesc.fragmentFunction = baseFn
            baseDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            floorBasePipeline = try device.makeRenderPipelineState(descriptor: baseDesc)

            let composeDesc = MTLRenderPipelineDescriptor()
            composeDesc.vertexFunction = vertFn
            composeDesc.fragmentFunction = composeFn
            composeDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            floorComposePipeline = try device.makeRenderPipelineState(descriptor: composeDesc)
        } catch {
            print("pipeline creation failed: \(error)")
            return nil
        }

        textures = TextureCache(device: device)
        guard let fs = SpriteBatch(device: device, library: library, pixelFormat: .bgra8Unorm, textures: textures),
              let ss = SpriteBatch(device: device, library: library, pixelFormat: view.colorPixelFormat, textures: textures)
        else { return nil }
        floorBatch = fs
        surfaceBatch = ss

        guard let buf = device.makeBuffer(length: MemoryLayout<Splat>.stride * Tuning.maxSplatsPerFrame, options: .storageModeShared),
              let pbuf = device.makeBuffer(length: MemoryLayout<SIMD2<Float>>.stride * Tuning.maxProbes, options: .storageModeShared),
              let rbuf = device.makeBuffer(length: MemoryLayout<SIMD4<Float>>.stride * Tuning.maxProbes, options: .storageModeShared),
              let wbuf = device.makeBuffer(length: MemoryLayout<SIMD4<Float>>.stride * Tuning.maxWalls, options: .storageModeShared),
              let cbuf = device.makeBuffer(length: MemoryLayout<SIMD4<Float>>.stride * Tuning.maxCovers, options: .storageModeShared),
              let sbuf = device.makeBuffer(length: MemoryLayout<Float>.stride * 2048, options: .storageModeShared),
              let spbuf = device.makeBuffer(length: MemoryLayout<SIMD4<Float>>.stride * 13 * Tuning.maxSpines, options: .storageModeShared)
        else { return nil }
        splatBuffer = buf
        probeBuffer = pbuf
        resultBuffer = rbuf
        wallBuffer = wbuf
        coverBuffer = cbuf
        siltRowBuffer = sbuf
        spineBuffer = spbuf

        self.device = device
        self.queue = queue
        super.init()

        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead
        blankMosaic = device.makeTexture(descriptor: d)
        var zero: UInt32 = 0
        blankMosaic?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 4)
    }

    // MARK: - Coordinates

    static func weight(forMajorRadius r: CGFloat) -> Float {
        let range = Tuning.radiusWeightRange
        let t = (r - range.lowerBound) / (range.upperBound - range.lowerBound)
        return Float(min(max(t, 0), 1))
    }

    private func lerp(_ range: ClosedRange<Float>, _ t: Float) -> Float {
        range.lowerBound + (range.upperBound - range.lowerBound) * t
    }

    func cell(for point: CGPoint, in size: CGSize) -> SIMD2<Float>? {
        guard size.width > 0, size.height > 0, gridSize.x > 0 else { return nil }
        return SIMD2<Float>(Float(point.x / size.width) * Float(gridSize.x),
                            Float(point.y / size.height) * Float(gridSize.y))
    }

    // MARK: - Input

    func addSplat(at point: CGPoint, in size: CGSize, radius: Float, amplitude: Float) {
        guard pendingSplats.count < Tuning.maxSplatsPerFrame,
              let c = cell(for: point, in: size) else { return }
        pendingSplats.append(Splat(pos: c, radius: radius, amplitude: amplitude))
    }

    func touchDown(id: Int, at point: CGPoint, in size: CGSize, weight w: Float) {
        let amp = Tuning.tapAmplitude * lerp(Tuning.weightAmplitudeRange, w)
        let rad = Tuning.tapRadius * lerp(Tuning.weightRadiusRange, w)
        addSplat(at: point, in: size, radius: rad, amplitude: amp)
        if let c = cell(for: point, in: size) {
            scheduledSplats.append((CACurrentMediaTime() + Tuning.reboundDelay,
                                    Splat(pos: c, radius: rad * 0.62, amplitude: amp * Tuning.reboundScale)))
        }
        holdOrder += 1
        holds[id] = Hold(position: point, viewSize: size, weight: w, order: holdOrder)
        if holds.count >= 2 { swellLast = nil; swellActive = false }
    }

    func touchMoved(id: Int, to point: CGPoint, in size: CGSize) {
        guard var hold = holds[id] else { return }
        if holds.count >= 2 {
            hold.position = point
            hold.viewSize = size
            hold.charge = 0
            holds[id] = hold
            return
        }
        let dx = point.x - hold.position.x, dy = point.y - hold.position.y
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance > Tuning.chargeCancelDistance { hold.charge = 0 }
        guard distance >= Tuning.dragSpacing else {
            holds[id] = hold
            return
        }
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

    func touchUp(id: Int) {
        guard let hold = holds.removeValue(forKey: id) else { return }
        if holds.count < 2 { swellLast = nil; swellActive = false }
        guard hold.charge > 0.05 else { return }
        let rad = Tuning.tapRadius * (1.0 + Tuning.holdRadiusGrowth * hold.charge)
        let amp = Tuning.tapAmplitude * Tuning.holdReleaseKick * hold.charge
        addSplat(at: hold.position, in: hold.viewSize, radius: rad, amplitude: amp)
        onChargedRelease?(hold.charge)
    }

    func charge(of id: Int) -> Float { holds[id]?.charge ?? 0 }
    func cancelAll() { holds.removeAll(); swellLast = nil; swellActive = false }

    func reset() {
        if let a = fieldA { zero(a) }
        if let b = fieldB { zero(b) }
        needsSiltReset = true
        siltLock.withLock { $0 = 1 }
    }

    // MARK: - Probes

    func setProbes(_ cells: [SIMD2<Float>]) {
        let n = min(cells.count, Tuning.maxProbes)
        probeCount = n
        guard n > 0 else { return }
        probeBuffer.contents().withMemoryRebound(to: SIMD2<Float>.self, capacity: n) { ptr in
            for i in 0..<n { ptr[i] = cells[i] }
        }
    }

    func latestSamples() -> [FieldSample] {
        resultLock.withLock { raw in
            raw.map { FieldSample(height: $0.x, slope: SIMD2($0.y, $0.z), velocity: $0.w) }
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        allocate(for: size)
    }

    func draw(in view: MTKView) {
        guard let src = fieldA, let dst = fieldB,
              let depthTexture, let floorBase, let floorTexture,
              let siltA, let siltB,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer() else { return }

        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastFrameTime, 1.0 / 20.0))
        lastFrameTime = now
        frameIndex += 1
        viewSizePoints = view.bounds.size

        if logFrames { recordFrame(now: now, dt: Double(dt)) }
        onFrame?(dt)
        accumulateHolds(dt: dt)
        accumulateSwell()
        releaseScheduledSplats(now: now)
        maybeBreeze(now: now)

        let pointScale = screenPixels.x / Float(max(view.bounds.width, 1))
        let pointsViewport = viewportSize / pointScale                    // world size in points
        let screenPoints = screenPixels / pointScale
        if !viewCentreSet { viewCentre = pointsViewport * 0.5; viewCentreSet = true }
        var cam = cameraParams(screenPoints: screenPoints, worldPoints: pointsViewport)

        // --- floor base, once ---------------------------------------------------

        if needsFloorBake {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = floorBase
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
                var fp = floorParams()
                encoder.setRenderPipelineState(floorBasePipeline)
                encoder.setFragmentBytes(&fp, length: MemoryLayout<FloorParams>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
            needsFloorBake = false
        }
        if needsSiltReset {
            fill(siltA, value: 1)
            fill(siltB, value: 1)
            needsSiltReset = false
        }

        // --- simulate -----------------------------------------------------------

        simAccumulator += Double(dt)
        var steps = Int(simAccumulator * Tuning.simStepsPerSecond)
        if steps > Tuning.maxStepsPerFrame {
            steps = Tuning.maxStepsPerFrame
            simAccumulator = 0
        } else {
            simAccumulator -= Double(steps) / Tuning.simStepsPerSecond
        }

        var count = 0
        if steps > 0 {
            count = min(pendingSplats.count, Tuning.maxSplatsPerFrame)
            if count > 0 {
                splatBuffer.contents().withMemoryRebound(to: Splat.self, capacity: count) { ptr in
                    for i in 0..<count { ptr[i] = pendingSplats[i] }
                }
            }
            pendingSplats.removeAll(keepingCapacity: true)
        }

        let wallCount = min(walls.count, Tuning.maxWalls)
        if wallCount > 0 {
            let size = CGSize(width: CGFloat(pointsViewport.x), height: CGFloat(pointsViewport.y))
            wallBuffer.contents().withMemoryRebound(to: SIMD4<Float>.self, capacity: wallCount) { ptr in
                for i in 0..<wallCount {
                    let c = cell(for: walls[i].centre, in: size) ?? .zero
                    let r = Float(walls[i].radius / size.width) * Float(gridSize.x)
                    ptr[i] = SIMD4(c.x, c.y, r, 0.18)
                }
            }
        }

        var read = src
        var write = dst
        for step in 0..<steps {
            var params = SimParams(size: gridSize, c2: Tuning.c2, damping: Tuning.damping,
                                   edgeDamp: Tuning.edgeDamp, edgeBand: Tuning.edgeBand,
                                   nonlinearity: Tuning.nonlinearity,
                                   splatCount: step == 0 ? UInt32(count) : 0,
                                   shallowSpeed: Tuning.shallowSpeed, wallCount: UInt32(wallCount))
            guard let encoder = commands.makeComputeCommandEncoder() else { break }
            encoder.setComputePipelineState(simPipeline)
            encoder.setTexture(read, index: 0)
            encoder.setTexture(write, index: 1)
            encoder.setTexture(depthTexture, index: 2)
            encoder.setBytes(&params, length: MemoryLayout<SimParams>.stride, index: 0)
            encoder.setBuffer(splatBuffer, offset: 0, index: 1)
            encoder.setBuffer(wallBuffer, offset: 0, index: 2)
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

        // --- silt ---------------------------------------------------------------

        var sp = siltParams(dt: dt)
        let coverCount = min(siltCovers.count, Tuning.maxCovers)
        if coverCount > 0 {
            coverBuffer.contents().withMemoryRebound(to: SIMD4<Float>.self, capacity: coverCount) { ptr in
                for i in 0..<coverCount { ptr[i] = siltCovers[i] }
            }
        }
        sp.coverCount = UInt32(coverCount)
        if steps > 0, let encoder = commands.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(siltPipeline)
            encoder.setTexture(siltA, index: 0)
            encoder.setTexture(siltB, index: 1)
            encoder.setTexture(read, index: 2)
            encoder.setBytes(&sp, length: MemoryLayout<SiltParams>.stride, index: 0)
            encoder.setBuffer(coverBuffer, offset: 0, index: 1)
            let w = siltPipeline.threadExecutionWidth
            let h = max(1, siltPipeline.maxTotalThreadsPerThreadgroup / w)
            encoder.dispatchThreads(MTLSize(width: siltSize.x, height: siltSize.y, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
            encoder.endEncoding()
            self.siltA = siltB
            self.siltB = siltA
        }
        let silt = self.siltA ?? siltA

        if frameIndex % Tuning.siltReadEveryFrames == 0, floorLook.mosaicRadius > 0,
           let encoder = commands.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(siltSumPipeline)
            encoder.setTexture(silt, index: 0)
            encoder.setBuffer(siltRowBuffer, offset: 0, index: 0)
            encoder.setBytes(&sp, length: MemoryLayout<SiltParams>.stride, index: 1)
            encoder.dispatchThreads(MTLSize(width: siltSize.y, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
            encoder.endEncoding()
            let rows = siltRowBuffer, n = siltSize.y, area = siltArea, lock = siltLock
            commands.addCompletedHandler { _ in
                let total = rows.contents().withMemoryRebound(to: Float.self, capacity: n) { ptr in
                    (0..<n).reduce(Float(0)) { $0 + ptr[$1] }
                }
                lock.withLock { $0 = min(1, total / max(area, 1)) }
            }
        }

        // --- probe --------------------------------------------------------------

        let probes = probeCount
        if probes > 0, let encoder = commands.makeComputeCommandEncoder() {
            var n = UInt32(probes)
            encoder.setComputePipelineState(probePipeline)
            encoder.setTexture(read, index: 0)
            encoder.setBuffer(probeBuffer, offset: 0, index: 0)
            encoder.setBuffer(resultBuffer, offset: 0, index: 1)
            encoder.setBytes(&n, length: MemoryLayout<UInt32>.size, index: 2)
            encoder.dispatchThreads(MTLSize(width: probes, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: min(probes, 32), height: 1, depth: 1))
            encoder.endEncoding()
            let results = resultBuffer, lock = resultLock
            commands.addCompletedHandler { _ in
                let copy = results.contents().withMemoryRebound(to: SIMD4<Float>.self, capacity: probes) { ptr in
                    Array(UnsafeBufferPointer(start: ptr, count: probes))
                }
                lock.withLock { $0 = copy }
            }
        }

        // --- floor compose: base + mosaic under silt, then submerged sprites ----

        var spriteParams = SpriteParams(
            viewport: SIMD4(pointsViewport.x, pointsViewport.y, 0, 0),
            gains: SIMD4(Tuning.floaterLift, Tuning.floaterTilt, Tuning.floaterWetThreshold, Tuning.floaterBob),
            floorTint: SIMD4(floorLook.mid * 2.2, 1),
            light: SIMD4(-0.40, -0.56, 0.72, 0),
            relief: style == .woodblock ? SIMD4(0.55, 0.16, 0.28, 0.55) : SIMD4(0.35, 0.10, 0.15, 0.35),
            camera: SIMD4(camera.x, camera.y, WaterRenderer.cameraHeight, WaterRenderer.cameraShiftGain),
            haze: SIMD4(floorLook.deep * 0.9, 1),
            screen: SIMD4(screenPoints.x, screenPoints.y, zoom, 1),
            view: SIMD4(viewCentre.x, viewCentre.y, 0, 0))

        let spineCount = min(spines.count, 13 * Tuning.maxSpines)
        if spineCount > 0 {
            spineBuffer.contents().withMemoryRebound(to: SIMD4<Float>.self, capacity: spineCount) { ptr in
                for i in 0..<spineCount { ptr[i] = spines[i] }
            }
        }

        do {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = floorTexture
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
                var fp = floorParams()
                encoder.setRenderPipelineState(floorComposePipeline)
                encoder.setFragmentTexture(floorBase, index: 0)
                encoder.setFragmentTexture(mosaicTexture ?? blankMosaic, index: 1)
                encoder.setFragmentTexture(silt, index: 2)
                encoder.setFragmentTexture(depthTexture, index: 3)
                encoder.setFragmentTexture(bedTexture ?? blankMosaic, index: 4)
                encoder.setFragmentBytes(&fp, length: MemoryLayout<FloorParams>.stride, index: 0)
                encoder.setFragmentBytes(&cam, length: MemoryLayout<CameraParams>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

                floorBatch.beginFrame()
                floorBatch.draw(submergedSprites, encoder: encoder, params: spriteParams, field: read, spines: spineBuffer, camera: &cam)
                encoder.endEncoding()
            }
        }

        // --- water, then whatever floats on it ----------------------------------

        var rp = RenderParams(size: gridSize, viewport: screenPixels,
                              refraction: Tuning.refraction, causticGain: Tuning.causticGain,
                              specGain: Tuning.specGain, time: Float(now - startTime),
                              crestGain: Tuning.crestGain, sparkleGain: Tuning.sparkleGain,
                              detailGain: Tuning.detailGain, dispersion: Tuning.dispersion,
                              waterTint: SIMD4(floorLook.waterTint, floorLook.waterTintStrength),
                              style: SIMD4(style == .woodblock ? 1 : 0, 0, 0, 0),
                              inkColour: SIMD4(0.106, 0.106, 0.106, 1),
                              view: SIMD4(zoom, viewCentre.x * pointScale, viewCentre.y * pointScale, 0),
                              world: SIMD4(viewportSize.x, viewportSize.y, 0, 0))

        if let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) {
            encoder.setRenderPipelineState(drawPipeline)
            encoder.setFragmentTexture(read, index: 0)
            encoder.setFragmentTexture(floorTexture, index: 1)
            encoder.setFragmentTexture(depthTexture, index: 2)
            encoder.setFragmentBytes(&rp, length: MemoryLayout<RenderParams>.stride, index: 0)
            encoder.setFragmentBytes(&cam, length: MemoryLayout<CameraParams>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            spriteParams.screen.w = 0
            surfaceBatch.beginFrame()
            surfaceBatch.draw(surfaceSprites, encoder: encoder, params: spriteParams, field: read, spines: spineBuffer, camera: &cam)
            encoder.endEncoding()
        }

        commands.present(drawable)
        commands.commit()
    }

    private func floorParams() -> FloorParams {
        let look = floorLook
        let scale = screenPixels.x / Float(max(1, viewSizePoints?.width ?? 1))
        return FloorParams(viewport: SIMD4(viewportSize.x, viewportSize.y, 0, 0),
                           deep: SIMD4(look.deep, 1), mid: SIMD4(look.mid, 1), shallow: SIMD4(look.shallow, 1),
                           mosaic: SIMD4(look.mosaicCentre.x, look.mosaicCentre.y, look.mosaicRadius, 1),
                           siltColour: SIMD4(look.siltColour, 1),
                           camera: SIMD4(camera.x * scale, camera.y * scale, WaterRenderer.cameraHeight, WaterRenderer.cameraShiftGain),
                           bed: SIMD4(bedTexture == nil ? 0 : 0.9, 1.0, Float(CACurrentMediaTime() - startTime), 0),
                           view: SIMD4(viewCentre.x * scale, viewCentre.y * scale, 0, 0))
    }

    private func siltParams(dt: Float) -> SiltParams {
        let look = floorLook
        return SiltParams(viewport: SIMD4(viewportSize.x, viewportSize.y, 0, 0),
                          size: SIMD4(Float(siltSize.x), Float(siltSize.y), 0, 0),
                          gains: SIMD4(Tuning.siltHeightGain, Tuning.siltLaplacianGain, Tuning.siltThreshold, Tuning.siltRate * dt),
                          mosaic: SIMD4(look.mosaicCentre.x, look.mosaicCentre.y, look.mosaicRadius, 0),
                          coverCount: 0)
    }

    private func recordFrame(now: TimeInterval, dt: Double) {
        statFrames += 1
        statWorstFrame = max(statWorstFrame, dt)
        let elapsed = now - statWindowStart
        guard elapsed >= 1.0 else { return }
        print(String(format: "[ripple] %.1f fps | %.0f sim steps/s (target %.0f) | worst frame %.1f ms",
                     Double(statFrames) / elapsed, Double(statSteps) / elapsed,
                     Tuning.simStepsPerSecond, statWorstFrame * 1000))
        statWindowStart = now
        statFrames = 0
        statSteps = 0
        statWorstFrame = 0
    }

    // MARK: - Per-frame input work

    private func accumulateHolds(dt: Float) {
        guard !holds.isEmpty, holds.count < 2 else { return }
        for (id, var hold) in holds {
            hold.charge = min(1.0, hold.charge + dt / Tuning.holdChargeSeconds)
            let press = Tuning.holdPressRate * dt * (1.0 - hold.charge * 0.65)
            let radius = Tuning.tapRadius * (1.0 + Tuning.holdRadiusGrowth * hold.charge)
            addSplat(at: hold.position, in: hold.viewSize, radius: radius,
                     amplitude: -press * lerp(Tuning.weightAmplitudeRange, hold.weight))
            holds[id] = hold
        }
    }

    private func accumulateSwell() {
        guard holds.count >= 2 else { return }
        let pair = holds.values.sorted { $0.order < $1.order }.suffix(2)
        guard let a = pair.first, let b = pair.last else { return }
        defer { swellLast = (a.position, b.position) }
        guard let last = swellLast else { return }
        let moved = max(hypot(a.position.x - last.a.x, a.position.y - last.a.y),
                        hypot(b.position.x - last.b.x, b.position.y - last.b.y))
        guard moved > 0.8 else { return }
        if !swellActive {
            swellActive = true
            onSwellStart?()
        }
        let amp = max(Tuning.swellAmplitudePerPoint * Float(moved), Tuning.swellAmplitudeCap)
        guard let ca = cell(for: a.position, in: a.viewSize),
              let cb = cell(for: b.position, in: b.viewSize) else { return }
        let length = simd_distance(ca, cb)
        let n = max(1, min(Int(length / Tuning.swellSpacing), 24))
        for i in 0...n {
            let t = Float(i) / Float(n)
            guard pendingSplats.count < Tuning.maxSplatsPerFrame else { break }
            pendingSplats.append(Splat(pos: ca + (cb - ca) * t, radius: Tuning.swellRadius, amplitude: amp))
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
        let pos = SIMD2<Float>(Float.random(in: 0...Float(gridSize.x)), Float.random(in: 0...Float(gridSize.y)))
        pendingSplats.append(Splat(pos: pos, radius: Float.random(in: Tuning.breezeRadius), amplitude: Tuning.breezeAmplitude))
    }

    // MARK: - Resources

    private func allocate(for screenSize: CGSize) {
        guard screenSize.width > 0, screenSize.height > 0 else { return }
        // Everything simulated and baked covers the world, not the screen.
        let size = CGSize(width: screenSize.width * WaterRenderer.worldScale, height: screenSize.height * WaterRenderer.worldScale)
        let aspect = size.width / size.height

        func dims(long: Int) -> (Int, Int) {
            if aspect >= 1 { return (long, max(2, Int((CGFloat(long) / aspect).rounded()))) }
            return (max(2, Int((CGFloat(long) * aspect).rounded())), long)
        }
        let (w, h) = dims(long: Tuning.gridLongSide)
        gridSize = SIMD2<UInt32>(UInt32(w), UInt32(h))
        viewportSize = SIMD2<Float>(Float(size.width), Float(size.height))     // world, in pixels
        screenPixels = SIMD2<Float>(Float(screenSize.width), Float(screenSize.height))

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        fieldA = device.makeTexture(descriptor: desc)
        fieldB = device.makeTexture(descriptor: desc)

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: w, height: h, mipmapped: false)
        depthDesc.usage = .shaderRead
        depthDesc.storageMode = .shared
        depthTexture = device.makeTexture(descriptor: depthDesc)
        rebuildDepth()

        let (sw, sh) = dims(long: Tuning.siltLongSide)
        siltSize = SIMD2(sw, sh)
        let siltDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: sw, height: sh, mipmapped: false)
        siltDesc.usage = [.shaderRead, .shaderWrite]
        siltDesc.storageMode = .shared
        siltA = device.makeTexture(descriptor: siltDesc)
        siltB = device.makeTexture(descriptor: siltDesc)
        needsSiltReset = true
        // Texels inside the mosaic circle, for normalising the readback.
        let r = floorLook.mosaicRadius * Float(sh)
        siltArea = max(1, Float.pi * r * r)

        for tex in [floorBase, floorTexture] { _ = tex }
        let floorDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                 width: max(2, Int(size.width)), height: max(2, Int(size.height)),
                                                                 mipmapped: false)
        floorDesc.usage = [.shaderRead, .renderTarget]
        floorDesc.storageMode = .private
        floorBase = device.makeTexture(descriptor: floorDesc)
        floorTexture = device.makeTexture(descriptor: floorDesc)
        needsFloorBake = true

        reset()
    }

    /// Recomputes the silt normaliser after the look changes.
    func mosaicChanged() {
        let r = floorLook.mosaicRadius * Float(siltSize.y)
        siltArea = max(1, Float.pi * r * r)
    }

    func rebuildDepth() {
        guard let depthTexture else { return }
        let w = depthTexture.width, h = depthTexture.height
        var values = depthPainter?(w, h) ?? Array(repeating: 1, count: w * h)
        if values.count != w * h { values = Array(repeating: 1, count: w * h) }
        values.withUnsafeBytes { raw in
            depthTexture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                                 withBytes: raw.baseAddress!, bytesPerRow: w * 4)
        }
    }

    private func loadMosaic(named name: String) {
        guard !name.isEmpty else { mosaicTexture = nil; return }
        mosaicTexture = textures.texture(name)
        mosaicChanged()
    }

    private func zero(_ texture: MTLTexture) {
        let bytesPerRow = texture.width * MemoryLayout<Float>.size * 2
        let blank = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        blank.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: bytesPerRow)
        }
    }

    private func fill(_ texture: MTLTexture, value: Float) {
        let half = Float16(value)
        let bytesPerRow = texture.width * 2
        var data = [Float16](repeating: half, count: texture.width * texture.height)
        data.withUnsafeMutableBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: bytesPerRow)
        }
    }
}
