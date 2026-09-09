import Metal
import MetalKit
import simd
import ImageIO
import CoreGraphics

/// Layout mirrors `SpriteInstance` in Shaders.metal.
struct SpriteInstance {
    var center: SIMD2<Float>
    var size: SIMD2<Float>
    var rotation: Float = 0
    var alpha: Float = 1
    var depth: Float = 0
    var wave: Float = 0
    var waveAmp: Float = 0
    var mode: UInt32 = 0
    var pad: SIMD2<Float> = .zero
    var tint: SIMD4<Float> = [1, 1, 1, 1]

    enum Mode: UInt32 {
        case plain = 0, floater = 1, submerged = 2, shadow = 3
    }
    static let flipX: UInt32 = 8
    /// Draw the silhouette ink-dark: the paper's cut edge, laid just under.
    static let ink: UInt32 = 16
    /// Rooted pondweed that leans with the water.
    static let weed: UInt32 = 32
    /// Stands up from its root on the surface plane (reeds).
    static let stands: UInt32 = 64
    /// Only visible where the ice mask says ice (fractures).
    static let maskIce: UInt32 = 128
}

struct SpriteParams {
    var viewport: SIMD4<Float>
    var gains: SIMD4<Float>
    var floorTint: SIMD4<Float>
    var light: SIMD4<Float>
    var relief: SIMD4<Float>
    var camera: SIMD4<Float>
    var haze: SIMD4<Float>
    var screen: SIMD4<Float>
    var view: SIMD4<Float>
}

/// A sprite the game wants drawn this frame.
struct Sprite {
    var texture: String
    var gpu: SpriteInstance

    init(_ texture: String, at center: CGPoint, size: CGSize, rotation: Float = 0,
         mode: SpriteInstance.Mode = .plain, alpha: Float = 1, flipX: Bool = false,
         depth: Float = 0, wave: Float = 0, waveAmp: Float = 0, tint: SIMD4<Float> = [1, 1, 1, 1],
         spine: Int? = nil, z: Float = 0, weed: Bool = false, stands: Bool = false) {
        self.texture = texture
        gpu = SpriteInstance(center: SIMD2(Float(center.x), Float(center.y)),
                             size: SIMD2(Float(size.width), Float(size.height)),
                             rotation: rotation, alpha: alpha, depth: depth,
                             wave: wave, waveAmp: waveAmp,
                             mode: mode.rawValue | (flipX ? SpriteInstance.flipX : 0) | (weed ? SpriteInstance.weed : 0) | (stands ? SpriteInstance.stands : 0),
                             pad: SIMD2(Float((spine ?? -1) + 1), z),
                             tint: tint)
    }
}

/// Textures by resource name, loaded once. Art lives as loose PNGs in the
/// bundle so a piece can be swapped by dropping in a file.
final class TextureCache {
    private let loader: MTKTextureLoader
    private var cache: [String: MTLTexture] = [:]
    private var sizes: [String: CGSize] = [:]

    init(device: MTLDevice) {
        self.device = device
        loader = MTKTextureLoader(device: device)
    }

    private var normals: [String: MTLTexture] = [:]
    private let device: MTLDevice

    /// A normal map cut from the sprite's own silhouette: the alpha is
    /// blurred into a rounded height field, so every piece gets a bevelled
    /// edge and a little body without anyone having to paint one.
    func normal(_ name: String) -> MTLTexture? {
        if let t = normals[name] { return t }
        let cg: CGImage
        if let drawn = registered[name] {
            cg = drawn
        } else {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let loaded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            cg = loaded
        }
        let w = cg.width, h = cg.height
        var alpha = [UInt8](repeating: 0, count: w * h)
        alpha.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var field = alpha.map { Float($0) / 255 }
        let radius = max(2, Int(Double(max(w, h)) * 0.045))
        field = TextureCache.boxBlur(field, w: w, h: h, r: radius)
        field = TextureCache.boxBlur(field, w: w, h: h, r: radius)
        // Only the inside counts as body; outside the silhouette stays flat.
        for i in 0..<(w * h) where alpha[i] == 0 { field[i] *= 0.6 }

        let strength = Float(radius) * 1.1
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let l = field[y * w + max(0, x - 1)], r = field[y * w + min(w - 1, x + 1)]
                let u = field[max(0, y - 1) * w + x], d = field[min(h - 1, y + 1) * w + x]
                let dx = (r - l) * 0.5 * strength, dy = (d - u) * 0.5 * strength
                let len = (dx * dx + dy * dy + 1).squareRoot()
                let nx = -dx / len, ny = -dy / len, nz = 1 / len
                let i = (y * w + x) * 4
                out[i] = UInt8(max(0, min(255, (nx * 0.5 + 0.5) * 255)))
                out[i + 1] = UInt8(max(0, min(255, (ny * 0.5 + 0.5) * 255)))
                out[i + 2] = UInt8(max(0, min(255, (nz * 0.5 + 0.5) * 255)))
                out[i + 3] = UInt8(max(0, min(255, field[y * w + x] * 255)))
            }
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        out.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: w * 4)
        }
        normals[name] = tex
        return tex
    }

    /// Separable box blur with running sums, so a big radius costs the same
    /// as a small one.
    private static func boxBlur(_ src: [Float], w: Int, h: Int, r: Int) -> [Float] {
        var tmp = [Float](repeating: 0, count: w * h)
        var dst = [Float](repeating: 0, count: w * h)
        let span = Float(2 * r + 1)
        for y in 0..<h {
            var sum: Float = 0
            for x in -r...r { sum += src[y * w + max(0, min(w - 1, x))] }
            for x in 0..<w {
                tmp[y * w + x] = sum / span
                let outX = max(0, min(w - 1, x - r)), inX = max(0, min(w - 1, x + r + 1))
                sum += src[y * w + inX] - src[y * w + outX]
            }
        }
        for x in 0..<w {
            var sum: Float = 0
            for y in -r...r { sum += tmp[max(0, min(h - 1, y)) * w + x] }
            for y in 0..<h {
                dst[y * w + x] = sum / span
                let outY = max(0, min(h - 1, y - r)), inY = max(0, min(h - 1, y + r + 1))
                sum += tmp[inY * w + x] - tmp[outY * w + x]
            }
        }
        return dst
    }

    /// Images drawn at run time (labels on washi), kept for their normals.
    private var registered: [String: CGImage] = [:]

    /// Puts an image drawn at run time into the cache under a name, so it
    /// is drawn like any sprite, relief and all.
    func register(_ name: String, image: CGImage) {
        guard let t = try? loader.newTexture(cgImage: image, options: [.SRGB: false, .generateMipmaps: true]) else { return }
        cache[name] = t
        sizes[name] = CGSize(width: t.width, height: t.height)
        registered[name] = image
        normals[name] = nil
    }

    func has(_ name: String) -> Bool { cache[name] != nil }

    func texture(_ name: String) -> MTLTexture? {
        if let t = cache[name] { return t }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let t = try? loader.newTexture(URL: url, options: [.SRGB: false, .generateMipmaps: true]) else {
            return nil
        }
        cache[name] = t
        sizes[name] = CGSize(width: t.width, height: t.height)
        return t
    }

    /// Pixel size, for keeping a sprite's aspect.
    func size(_ name: String) -> CGSize {
        if let s = sizes[name] { return s }
        _ = texture(name)
        return sizes[name] ?? CGSize(width: 1, height: 1)
    }
}

/// Draws lists of sprites with one mesh and one draw call per texture run.
final class SpriteBatch {
    static let maxInstances = 6144
    static let segments = 24

    let pipeline: MTLRenderPipelineState
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let instanceBuffer: MTLBuffer
    let indexCount: Int
    let textures: TextureCache
    private var cursor = 0

    init?(device: MTLDevice, library: MTLLibrary, pixelFormat: MTLPixelFormat,
          depthFormat: MTLPixelFormat, textures: TextureCache) {
        guard let vfn = library.makeFunction(name: "sprite_vertex"),
              let ffn = library.makeFunction(name: "sprite_fragment") else { return nil }

        let vdesc = MTLVertexDescriptor()
        vdesc.attributes[0].format = .float2
        vdesc.attributes[0].offset = 0
        vdesc.attributes[0].bufferIndex = 0
        vdesc.layouts[0].stride = MemoryLayout<SIMD2<Float>>.stride

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
        // Sprites never sort by depth, but the pass they draw into has a depth
        // attachment for the solids, so the pipeline has to name its format.
        desc.depthAttachmentPixelFormat = depthFormat
        do { pipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { print("sprite pipeline failed: \(error)"); return nil }

        // A strip of quads: two columns, segments + 1 rows.
        var verts: [SIMD2<Float>] = []
        for row in 0...SpriteBatch.segments {
            let v = Float(row) / Float(SpriteBatch.segments)
            verts.append(SIMD2(0, v))
            verts.append(SIMD2(1, v))
        }
        var idx: [UInt16] = []
        for row in 0..<SpriteBatch.segments {
            let a = UInt16(row * 2), b = a + 1, c = a + 2, d = a + 3
            idx += [a, b, c, b, d, c]
        }
        guard let vb = device.makeBuffer(bytes: verts, length: MemoryLayout<SIMD2<Float>>.stride * verts.count, options: .storageModeShared),
              let ib = device.makeBuffer(bytes: idx, length: MemoryLayout<UInt16>.stride * idx.count, options: .storageModeShared),
              let inst = device.makeBuffer(length: MemoryLayout<SpriteInstance>.stride * SpriteBatch.maxInstances, options: .storageModeShared)
        else { return nil }
        vertexBuffer = vb
        indexBuffer = ib
        instanceBuffer = inst
        indexCount = idx.count
        self.textures = textures
    }

    /// Call once per frame before any draw.
    func beginFrame() { cursor = 0 }

    /// Uploads the sprites and draws them in order, in runs by texture.
    func draw(_ sprites: [Sprite], encoder: MTLRenderCommandEncoder, params: SpriteParams, field: MTLTexture, spines: MTLBuffer, camera: inout CameraParams, ice: MTLTexture? = nil) {
        guard !sprites.isEmpty else { return }
        let start = cursor
        let count = min(sprites.count, SpriteBatch.maxInstances - start)
        guard count > 0 else { return }

        instanceBuffer.contents().advanced(by: start * MemoryLayout<SpriteInstance>.stride)
            .withMemoryRebound(to: SpriteInstance.self, capacity: count) { ptr in
                for i in 0..<count { ptr[i] = sprites[i].gpu }
            }
        cursor += count

        var p = params
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 1)
        encoder.setVertexBytes(&p, length: MemoryLayout<SpriteParams>.stride, index: 2)
        encoder.setVertexBuffer(spines, offset: 0, index: 3)
        encoder.setVertexBytes(&camera, length: MemoryLayout<CameraParams>.stride, index: 4)
        encoder.setVertexTexture(field, index: 0)
        encoder.setFragmentBytes(&p, length: MemoryLayout<SpriteParams>.stride, index: 0)
        if let ice { encoder.setFragmentTexture(ice, index: 2) }

        var runStart = 0
        while runStart < count {
            let name = sprites[runStart].texture
            var runEnd = runStart + 1
            while runEnd < count, sprites[runEnd].texture == name { runEnd += 1 }
            if let tex = textures.texture(name) {
                encoder.setFragmentTexture(tex, index: 0)
                encoder.setFragmentTexture(textures.normal(name) ?? tex, index: 1)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint16,
                                              indexBuffer: indexBuffer, indexBufferOffset: 0,
                                              instanceCount: runEnd - runStart, baseVertex: 0,
                                              baseInstance: start + runStart)
            }
            runStart = runEnd
        }
    }
}
