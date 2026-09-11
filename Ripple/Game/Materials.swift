import Foundation
import simd

// The materials a level lays on the water (docs/gameplay-spec.md): the
// duckweed film and the whole-pond silt. The renderer does the work; this
// file holds the numbers and the GPU parameter mirror so they can be read
// without opening WaterRenderer.swift. The `Materials` methods themselves
// live on WaterRenderer, next to the textures they drive.

/// Mirrors `FilmParams` in Shaders.metal.
struct FilmParams {
    /// xy film texels, zw field texels.
    var size: SIMD4<Float>
    /// x drift per unit slope this step (field cells), y diffusion weight,
    /// z the depth below which a cell is shore, w the trailing-face weight.
    var gains: SIMD4<Float>
    /// x longest drift in one step (film texels), y how much of the excess
    /// over full density is kept each step, z 1 = reset the film.
    var misc: SIMD4<Float>
}

enum FilmTuning {
    /// Field cells of drift per second per unit of slope (height per cell).
    /// The debris feel a force of 125000 points per unit slope against a
    /// drag of 2.6/s, which carries a petal 20 to 30 points past a tap's
    /// ring. The weed is displaced directly, with no inertia, so a tenth of
    /// that: a ring's rising face (slope near 0.01 per cell for about
    /// fifteen sim steps) moves the film 8 or 9 cells, some 15 points, and
    /// a charged swell's wide ring, slower but far longer, shoves it 25 or
    /// more. Raise it if a tap's hole is too timid.
    static let filmGain: Float = 12000
    /// The trailing face of a wave pulls the weed back at this fraction of
    /// the leading face's push, the same Stokes drift the debris get.
    static let trailing: Float = 0.18
    /// Four-neighbour blur weight per sim step, water cells only. Keeps a
    /// parted edge soft without leaking the carpet to the shore. It runs
    /// 240 times a second, so this is about one texel squared a second: a
    /// tap's hole (six texels across) lasts ten seconds or so before the
    /// weed closes over it, unless the water keeps it open.
    static let diffusion: Float = 0.004
    /// Depth below which a cell is shore: the film is stranded there.
    static let shoreDepth: Float = 0.15
    /// Longest drift in one sim step, in film texels, so the back-trace
    /// never leaps over a bank.
    static let maxStep: Float = 1.5
    /// Weed heaped above full density settles back: the excess over 1 is
    /// multiplied by this each step (240 steps a second).
    static let excessKeep: Float = 0.94
    /// World points one repeat of `duckweed_tile.png` covers. The tile is
    /// 1024 px with about forty leaves across, so at one leaf per 8 points
    /// a repeat is 320 points.
    static let tilePoints: Float = 320
    /// The tile, if the art has landed; the shader draws its own leaves
    /// when it has not.
    static let tileName = "duckweed_tile"
    /// Below this density the carpet breaks into single leaves. Written
    /// into `duckweedOver` in Shaders.metal by hand; kept here for reference.
    static let breakBelow: Float = 0.35
}
