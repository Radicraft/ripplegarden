import simd

/// One Voronoi seed of the fractured sheet, laid out for the GPU (32 bytes,
/// mirrored by `IceSeed` in Shaders.metal). A shard is the Voronoi cell of a
/// seed; a crack is the edge between two cells. `strength` is how visible the
/// edges of this cell are (inner shards 1, the surrounding sheet 0, long
/// runner cracks ~0.6): an edge shows at max(strength) of its two seeds.
/// `reach` is how far from the strike centre, in ring multiples, this seed's
/// edges are allowed to show before they taper to nothing.
struct IceSeedGPU {
    var pos: SIMD2<Float>      // world points
    var strength: Float
    var reach: Float
    var strike: Float          // index into the strikes array
    var broken: Float          // 1 when the shard has gone (open water)
    var pad: SIMD2<Float> = .zero
}

/// One blow on the sheet (16 bytes, mirrored by `IceStrike` in Shaders.metal).
/// `time` is the renderer clock (`WaterRenderer.clock`) when it landed, so
/// the fragment can race the cracks outward from it and let them creep after.
struct IceStrikeGPU {
    var centre: SIMD2<Float>   // world points
    var ring: Float            // radius of the breakable region, world points
    var time: Float
}
