import Metal
import MetalKit
import simd

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
}

struct SpriteParams {
    var viewport: SIMD4<Float>
    var gains: SIMD4<Float>
    var floorTint: SIMD4<Float>
}

/// A sprite the game wants drawn this frame.
struct Sprite {
    var texture: String
    var gpu: SpriteInstance

    init(_ texture: String, at center: CGPoint, size: CGSize, rotation: Float = 0,
         mode: SpriteInstance.Mode = .plain, alpha: Float = 1, flipX: Bool = false,
         depth: Float = 0, wave: Float = 0, waveAmp: Float = 0, tint: SIMD4<Float> = [1, 1, 1, 1]) {
        self.texture = texture
        gpu = SpriteInstance(center: SIMD2(Float(center.x), Float(center.y)),
                             size: SIMD2(Float(size.width), Float(size.height)),
                             rotation: rotation, alpha: alpha, depth: depth,
                             wave: wave, waveAmp: waveAmp,
                             mode: mode.rawValue | (flipX ? SpriteInstance.flipX : 0),
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
        loader = MTKTextureLoader(device: device)
    }

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
    static let maxInstances = 768
    static let segments = 12

    let pipeline: MTLRenderPipelineState
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let instanceBuffer: MTLBuffer
    let indexCount: Int
    let textures: TextureCache
    private var cursor = 0

    init?(device: MTLDevice, library: MTLLibrary, pixelFormat: MTLPixelFormat, textures: TextureCache) {
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
        guard let p = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        pipeline = p

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
    func draw(_ sprites: [Sprite], encoder: MTLRenderCommandEncoder, params: SpriteParams, field: MTLTexture) {
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
        encoder.setVertexTexture(field, index: 0)
        encoder.setFragmentBytes(&p, length: MemoryLayout<SpriteParams>.stride, index: 0)

        var runStart = 0
        while runStart < count {
            let name = sprites[runStart].texture
            var runEnd = runStart + 1
            while runEnd < count, sprites[runEnd].texture == name { runEnd += 1 }
            if let tex = textures.texture(name) {
                encoder.setFragmentTexture(tex, index: 0)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint16,
                                              indexBuffer: indexBuffer, indexBufferOffset: 0,
                                              instanceCount: runEnd - runStart, baseVertex: 0,
                                              baseInstance: start + runStart)
            }
            runStart = runEnd
        }
    }
}
