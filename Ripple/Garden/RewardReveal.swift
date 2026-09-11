import CoreGraphics
import Foundation
import UIKit
import simd

/// The reward moment (docs/garden-spec.md). Every level win: a deep swell
/// from the pond's centre with the season's colour thrown up, then the
/// drawn item rising from the deep inside a ring of light coloured by its
/// tier, turning slowly, its name and tier on the water under it. A tap, or
/// a few seconds, sends it diving for the garden's bank with a trail of
/// bubbles, and the petals it paid are shown for a moment.
///
/// The draw itself is `Inventory.shared.award(level:replay:using:)`.
///
/// The controller owns one of these per win, feeds it each frame and
/// applies what it asks for: splats into the real water, bubbles into the
/// garden, a gold tint on the bed, and its sprites and bodies into the
/// passes. Sounds and haptics are the controller's too; the reveal only
/// reports what just happened in `events`.
@MainActor
final class RewardReveal {

    struct Award {
        let item: CatalogueItem
        let rarity: Rarity
        let petals: Int
    }

    enum Stage {
        case waiting, burst, rising, shown, diving, counted, done
    }

    /// What just happened, for the controller to sound and shake.
    enum Event {
        case chord, revealNote, dive, petals
    }

    /// A body for the solids pass, and the painting it wears, if any. The
    /// controller hands the painting to the batch by index.
    struct Body {
        var instance: SolidInstance
        var painting: String?
    }

    // MARK: - Tunings

    /// Seconds the item takes to rise; gold takes longer.
    private var riseSeconds: Float { award.rarity == .superRare ? 2.6 : 1.6 }
    /// Seconds after the reveal begins before it dives on its own.
    private var autoDiveAt: Float { award.rarity == .superRare ? 5.5 : 5.0 }
    private static let diveSeconds: Float = 0.9
    private static let countSeconds: Float = 1.4
    private static let goldSeconds: Float = 4.0
    private static let ringRadius: CGFloat = 88
    private static let burstCount = 120
    private static let goldPetalCount = 60

    // MARK: - State

    let award: Award
    private(set) var stage: Stage = .waiting
    private(set) var events: [Event] = []
    /// Splats for the real water this frame, in world points.
    private(set) var splashes: [(at: CGPoint, radius: Float, amplitude: Float)] = []
    /// Bubbles to be let go from the bed this frame.
    private(set) var bubbles: [CGPoint] = []
    /// How gold the bed is this frame, 0 to 1.
    private(set) var bedGold: Float = 0

    private let textures: TextureCache
    private let world: CGSize
    /// Where the swell rises and the item with it.
    private let centre: CGPoint
    /// Where its name is written, under it.
    private let wordsAt: CGPoint
    /// The garden's bank, the side it dives for.
    private let bank: CGPoint
    private let seasonID: String
    private let petalTexture: String
    private let ringTexture: String?

    private var time: Float = 0
    private var stageTime: Float = 0
    private var goldClock: Float = -1
    private var particles: [Floater] = []
    private var goldPetals: [Floater] = []
    private var goldSpawned = 0
    /// The item's height in pond units: -1 the bed, 0 the surface.
    private var z: Float = -0.35
    private var position: CGPoint
    private var turn: Float = 0
    private var ringAlpha: Float = 0
    private var itemAlpha: Float = 0
    private var wordsAlpha: Float = 0
    private var countAlpha: Float = 0
    private var bubbleClock: Float = 0
    private var brokeSurface = false
    private var wordsKey: String?
    private var countKey: String?

    /// `-reward common|rare|superRare` forces the tier of the next award.
    static let forcedTier: Rarity? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-reward"), i + 1 < args.count else { return nil }
        return Rarity(rawValue: args[i + 1])
    }()

    init(award: Award, textures: TextureCache, world: CGSize, centre: CGPoint, wordsAt: CGPoint,
         bank: CGPoint, seasonID: String, petalTexture: String) {
        self.award = award
        self.textures = textures
        self.world = world
        self.centre = centre
        self.wordsAt = wordsAt
        self.bank = bank
        self.seasonID = seasonID
        self.petalTexture = petalTexture
        position = centre
        ringTexture = Bundle.main.url(forResource: "ring_light", withExtension: "png") != nil ? "ring_light" : nil
    }

    var isDone: Bool { stage == .done }

    /// A tap may send it on its way once it is up, or nearly.
    var canDive: Bool {
        stage == .shown || (stage == .rising && stageTime > riseSeconds * 0.7)
    }

    // MARK: - The sequence

    /// The burst: the deep swell, the season's colour thrown up, the chord.
    func burst() {
        guard stage == .waiting else { return }
        stage = .burst
        stageTime = 0
        goldClock = 0
        splashes.append((centre, 60, -0.5))
        for k in 0..<12 {
            let a = CGFloat(k) / 12 * 2 * .pi
            let at = CGPoint(x: centre.x + cos(a) * 96, y: centre.y + sin(a) * 96 * 0.8)
            splashes.append((at, 16, -0.14))
        }
        for _ in 0..<RewardReveal.burstCount {
            particles.append(Floater.thrown(from: centre, texture: burstTexture(), tint: burstTint()))
        }
        events.append(.chord)
    }

    /// The reveal: the item begins its rise.
    func reveal() {
        guard stage == .burst || stage == .waiting else { return }
        if stage == .waiting { burst() }
        stage = .rising
        stageTime = 0
        z = -0.35
        if award.rarity != .common { events.append(.revealNote) }
    }

    /// Off to the bank. True if it went.
    @discardableResult
    func dive() -> Bool {
        guard canDive else { return false }
        stage = .diving
        stageTime = 0
        splashes.append((position, 24, -0.3))
        events.append(.dive)
        return true
    }

    /// Everything that has been asked for since the last frame is taken.
    func drain() {
        splashes.removeAll()
        bubbles.removeAll()
        events.removeAll()
    }

    func update(dt: Float) {
        time += dt
        stageTime += dt
        turn += dt * 0.55
        if goldClock >= 0 {
            goldClock += dt
            let up = min(1, goldClock / 0.35)
            let down = 1 - min(1, max(0, (goldClock - (RewardReveal.goldSeconds - 1.2)) / 1.2))
            bedGold = smooth(up) * smooth(down)
            if goldClock > RewardReveal.goldSeconds { bedGold = 0; goldClock = -1 }
        }
        for p in particles { p.update(dt: dt) }
        particles.removeAll { $0.gone }
        for p in goldPetals { p.update(dt: dt) }
        goldPetals.removeAll { $0.gone }

        switch stage {
        case .waiting, .burst, .done:
            break
        case .rising:
            let t = min(1, stageTime / riseSeconds)
            // Out of the dark quickly, then slowing as it breaks the surface.
            let eased = 1 - pow(1 - t, 3)
            z = -0.35 + 0.5 * eased
            ringAlpha = min(1, stageTime / 0.6)
            itemAlpha = min(1, stageTime / 0.4)
            // Breaking the surface lifts a little water with it.
            if !brokeSurface, z >= 0 {
                brokeSurface = true
                splashes.append((position, 18, -0.10))
            }
            shedGold(dt: dt)
            if t >= 1 {
                stage = .shown
                stageTime = riseSeconds
            }
        case .shown:
            z = 0.15 + 0.012 * sin(time * 1.7)
            wordsAlpha = min(1, wordsAlpha + dt * 2.5)
            shedGold(dt: dt)
            if stageTime >= autoDiveAt { dive() }
        case .diving:
            let t = min(1, stageTime / RewardReveal.diveSeconds)
            let eased = t * t
            position = CGPoint(x: centre.x + (bank.x - centre.x) * CGFloat(eased),
                               y: centre.y + (bank.y - centre.y) * CGFloat(eased))
            z = 0.15 - 1.1 * eased
            ringAlpha = max(0, 1 - t * 2.5)
            wordsAlpha = max(0, 1 - t * 3)
            itemAlpha = z < -0.7 ? max(0, 1 - (-0.7 - z) / 0.3) : 1
            bubbleClock += dt
            if z < 0, bubbleClock > 0.05 {
                bubbleClock = 0
                bubbles.append(position)
            }
            if t >= 1 {
                stage = .counted
                stageTime = 0
                events.append(.petals)
            }
        case .counted:
            let t = stageTime / RewardReveal.countSeconds
            countAlpha = t < 0.2 ? t / 0.2 : max(0, 1 - (t - 0.7) / 0.3)
            if stageTime >= RewardReveal.countSeconds { stage = .done }
        }
    }

    /// Gold petals come down on the water for as long as the item is up.
    private func shedGold(dt: Float) {
        guard award.rarity == .superRare, goldSpawned < RewardReveal.goldPetalCount else { return }
        let want = Int(Float(RewardReveal.goldPetalCount) * min(1, stageTime / riseSeconds))
        while goldSpawned < want {
            goldSpawned += 1
            goldPetals.append(Floater.falling(near: centre, spread: 230, texture: petalTexture,
                                              tint: [1.0, 0.84, 0.38, 1]))
        }
    }

    private func smooth(_ t: Float) -> Float { t * t * (3 - 2 * t) }

    // MARK: - What is thrown up

    /// The season's colour: petals in spring and summer, leaves in autumn,
    /// snow in winter, and a few motes of light among them.
    private func burstTexture() -> String {
        if Int.random(in: 0..<4) == 0 { return "mote" }
        switch seasonID {
        case "autumn": return "leaf_\(Int.random(in: 1...3))"
        case "winter": return Bool.random() ? "snow_2" : "snow_1"
        case "spring": return "petal_n_\(Int.random(in: 1...6))"
        case "summer": return "petal_\(Int.random(in: 1...3))"
        default: return petalTexture
        }
    }

    private func burstTint() -> SIMD4<Float> {
        switch seasonID {
        case "autumn": return [1.0, 0.86, 0.66, 1]
        case "winter": return [0.90, 0.96, 1.0, 1]
        case "spring": return [1.0, 0.90, 0.94, 1]
        default: return [1.0, 0.98, 0.82, 1]
        }
    }

    // MARK: - Drawing

    /// Sprites under the surface and on it, this frame.
    func sprites() -> (under: [Sprite], over: [Sprite]) {
        var under: [Sprite] = []
        var over: [Sprite] = []
        for p in particles + goldPetals {
            let s = p.sprite(textures: textures)
            over.append(s)
        }
        guard stage != .waiting, stage != .burst else { return (under, over) }

        let colour = award.rarity.colour
        // The ring of light, a floater on the surface, breathing.
        if ringAlpha > 0.01 {
            let breathe = CGFloat(1 + 0.06 * sin(time * 2.3))
            let r = RewardReveal.ringRadius * breathe
            if let ring = ringTexture {
                over.append(Sprite(ring, at: position, size: CGSize(width: r * 2, height: r * 2), rotation: turn * 0.3,
                                   mode: .floater, alpha: 0.85 * ringAlpha, tint: colour, z: 0))
            } else {
                // Motes are white light multiplied by their tint: the tier's
                // colour is lifted well over one so the ring reads as light,
                // not as dark dots.
                var glow = colour * 1.6 + SIMD4<Float>(0.15, 0.15, 0.15, 0)
                glow.w = 1
                over.append(Sprite("mote", at: position, size: CGSize(width: r * 2.6, height: r * 2.2),
                                   mode: .floater, alpha: 0.22 * ringAlpha, tint: glow, z: 0))
                let n = 22
                for k in 0..<n {
                    let a = CGFloat(k) / CGFloat(n) * 2 * .pi + CGFloat(turn) * 0.4
                    let twinkle = 0.75 + 0.25 * sin(time * 3.1 + Float(k) * 1.7)
                    let at = CGPoint(x: position.x + cos(a) * r, y: position.y + sin(a) * r * 0.82)
                    over.append(Sprite("mote", at: at, size: CGSize(width: 30, height: 30),
                                       mode: .floater, alpha: 0.8 * ringAlpha * twinkle, tint: glow, z: 0))
                }
            }
        }
        // The item itself, if it is a painting.
        if itemAlpha > 0.01, let s = itemSprite() {
            if z < 0 { under.append(s) } else {
                // Its shadow on the water, cast a little to the light's far side.
                let lift = CGFloat(z) * CGFloat(WaterRenderer.depthScale)
                over.append(Sprite("mote", at: CGPoint(x: position.x + lift * 0.3, y: position.y + lift * 0.5),
                                   size: CGSize(width: CGFloat(s.gpu.size.x) * 0.9, height: CGFloat(s.gpu.size.y) * 0.6),
                                   mode: .shadow, alpha: 0.3 * itemAlpha, z: 0))
                over.append(s)
            }
        }
        // Its name and tier, on the water under it.
        if wordsAlpha > 0.01 {
            let key = wordsTexture()
            let t = textures.size(key)
            let h: CGFloat = 56 * 1.9
            over.append(Sprite(key, at: wordsAt, size: CGSize(width: h * t.width / max(1, t.height), height: h),
                               mode: .floater, alpha: wordsAlpha, z: 0.08))
        }
        // What it paid, once it has gone.
        if countAlpha > 0.01 {
            let key = countTexture()
            let t = textures.size(key)
            let h: CGFloat = 22 * 1.9
            over.append(Sprite(key, at: wordsAt, size: CGSize(width: h * t.width / max(1, t.height), height: h),
                               mode: .floater, alpha: countAlpha, z: 0.08))
        }
        return (under, over)
    }

    /// Bodies under the surface and on it, this frame.
    func solids() -> (under: [Body], surface: [Body]) {
        guard stage != .waiting, stage != .burst, itemAlpha > 0.01, let body = itemBody() else { return ([], []) }
        return z < 0 ? ([body], []) : ([], [body])
    }

    /// Points across the item is shown at: its own size, kept where a mote
    /// still reads and a tree still fits in the ring.
    /// Shown big, whatever it will be in the pond: the reveal is the prize,
    /// and it fills most of the ring.
    private var shownSize: CGFloat { min(150, max(118, award.item.size)) }

    /// The item as a painting, or nil if it is a body. A koi is its painting,
    /// a feature its sprite if one is in the bundle, else a stone body.
    private func itemSprite() -> Sprite? {
        let item = award.item
        var name: String
        var stands = false
        switch item.art {
        case .sprite(let n, let s): name = n; stands = s
        case .koi(let t): name = t
        case .shoal(let t): name = t
        case .feature(let kind):
            guard Bundle.main.url(forResource: kind, withExtension: "png") != nil else { return nil }
            name = kind
        case .solid: return nil
        }
        let t = textures.size(name)
        let long = max(t.width, t.height)
        let across = shownSize
        var size = CGSize(width: across * t.width / max(1, long), height: across * t.height / max(1, long))
        let submerged = z < 0
        let haze = submerged ? min(0.35, -z * 0.6) : 0
        if stands {
            // A plant stands on its root and turns to show its sides.
            return Sprite(name, at: position, size: size, rotation: -.pi / 2 + 0.12 * sin(turn * 1.3),
                          mode: submerged ? .submerged : .plain, alpha: itemAlpha, depth: haze,
                          wave: time * 0.9, z: z, stands: true)
        }
        // Lying flat: it turns on the water like a leaf, narrowing as it
        // shows its edge, so the eye reads a thing with sides.
        size.width *= CGFloat(0.72 + 0.28 * abs(cos(turn * 0.8)))
        return Sprite(name, at: position, size: size, rotation: turn * 0.6,
                      mode: submerged ? .submerged : .plain, alpha: itemAlpha, depth: haze, z: z)
    }

    /// The item as a body, or nil if it is a painting. A feature with no
    /// painting of its own is shown as a stone.
    private func itemBody() -> Body? {
        let item = award.item
        var shape: UInt32
        var a: SIMD4<Float>, b: SIMD4<Float>
        var painting: String?
        switch item.art {
        case .solid(let s, let ca, let cb, let tex):
            shape = s; a = ca; b = cb; painting = tex
        case .feature(let kind):
            guard Bundle.main.url(forResource: kind, withExtension: "png") == nil else { return nil }
            shape = 2; a = [0.56, 0.58, 0.60, 1]; b = [0.36, 0.55, 0.30, 1]; painting = nil
        default: return nil
        }
        let across = Float(shownSize)
        let lift = z * WaterRenderer.depthScale
        let radius: Float, length: Float
        switch shape {
        case 3: radius = across * 0.17; length = across * 1.0
        case 4: radius = across * 0.5; length = 3
        case 6: radius = across * 0.08; length = across
        default: radius = across * 0.42; length = across * 0.6
        }
        let instance = SolidInstance(position: SIMD2(Float(position.x), Float(position.y)),
                                     lift: lift + (shape == 4 ? 1.5 : radius * 0.35),
                                     yaw: turn * 0.5,
                                     roll: shape == 2 ? 7.3 : (shape == 3 ? turn * 0.8 : 0),
                                     tilt: .zero,
                                     length: length, radius: radius, shape: shape,
                                     alpha: itemAlpha, colourA: a, colourB: b)
        return Body(instance: instance, painting: painting)
    }

    // MARK: - Words on the water

    private static let serifFace = "NewsreaderRoman-Light"
    private static let paper = UIColor(red: 0.949, green: 0.937, blue: 0.902, alpha: 1)

    private static func serif(_ points: CGFloat) -> UIFont {
        UIFont(name: serifFace, size: points) ?? UIFont.systemFont(ofSize: points, weight: .light)
    }

    /// The item's name over its tier, the tier in its colour, drawn once into
    /// a texture the sprite batch carries like the map's own words.
    private func wordsTexture() -> String {
        if let k = wordsKey { return k }
        let key = "reward_words_\(award.item.id)_\(award.rarity.rawValue)"
        wordsKey = key
        guard !textures.has(key) else { return key }
        let c = award.rarity.colour
        let tierColour = award.rarity == .common
            ? RewardReveal.paper.withAlphaComponent(0.78)
            : UIColor(red: CGFloat(min(1, c.x * 1.25 + 0.12)), green: CGFloat(min(1, c.y * 1.25 + 0.12)),
                      blue: CGFloat(min(1, c.z * 1.25 + 0.12)), alpha: 1)
        RewardReveal.draw(lines: [(award.item.name, 30, RewardReveal.paper), (award.rarity.name, 19, tierColour)],
                          key: key, textures: textures)
        return key
    }

    private func countTexture() -> String {
        if let k = countKey { return k }
        let key = "reward_petals_\(award.petals)"
        countKey = key
        guard !textures.has(key) else { return key }
        RewardReveal.draw(lines: [("+\(award.petals) petals", 22, RewardReveal.paper)], key: key, textures: textures)
        return key
    }

    /// Lines of serif set on a soft dark shade, centred, at twice the size
    /// they are shown at.
    private static func draw(lines: [(text: String, points: CGFloat, colour: UIColor)], key: String, textures: TextureCache) {
        let strings = lines.map { line in
            NSAttributedString(string: line.text, attributes: [.font: serif(line.points * 2), .foregroundColor: line.colour])
        }
        let sizes = strings.map { $0.size() }
        let pad: CGFloat = 24
        let gap: CGFloat = 10
        let width = ceil(sizes.map(\.width).max() ?? 1) + pad * 2
        let height = ceil(sizes.map(\.height).reduce(0, +)) + gap * CGFloat(max(0, lines.count - 1)) + pad * 2
        let size = CGSize(width: min(4096, width), height: min(4096, height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            var y = pad
            for (s, b) in zip(strings, sizes) {
                let x = (size.width - b.width) / 2
                ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 3), blur: 10,
                                        color: UIColor(red: 0.043, green: 0.086, blue: 0.071, alpha: 0.85).cgColor)
                s.draw(at: CGPoint(x: x, y: y))
                s.draw(at: CGPoint(x: x, y: y))
                ctx.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
                s.draw(at: CGPoint(x: x, y: y))
                y += b.height + gap
            }
        }
        if let cg = image.cgImage { textures.register(key, image: cg) }
    }
}

// MARK: - What is thrown up and comes down

/// A petal, leaf, flake or mote in the air over the pond, coming down to
/// float on it and fade. Like the garden's `Droplet`, but lighter, and it
/// spins.
private final class Floater {
    private(set) var position: CGPoint
    private var velocity: CGVector
    private(set) var lift: CGFloat
    private var liftVel: CGFloat
    private var rotation: Float
    private let spin: Float
    let texture: String
    let tint: SIMD4<Float>
    let size: CGFloat
    private var phase: Float
    private var landedFor: Float = -1
    private let floatsFor: Float
    /// Points per second squared: a petal comes down slower than a drop.
    private let gravity: CGFloat

    /// Thrown up from the burst.
    static func thrown(from p: CGPoint, texture: String, tint: SIMD4<Float>) -> Floater {
        let angle = CGFloat.random(in: 0...(2 * .pi))
        let out = CGFloat.random(in: 26...130)
        let mote = texture == "mote"
        return Floater(at: CGPoint(x: p.x + CGFloat.random(in: -12...12), y: p.y + CGFloat.random(in: -10...10)),
                       velocity: CGVector(dx: cos(angle) * out, dy: sin(angle) * out * 0.75),
                       lift: 0, up: CGFloat.random(in: 110...260),
                       size: mote ? CGFloat.random(in: 5...9) : CGFloat.random(in: 10...16),
                       texture: texture, tint: tint, gravity: mote ? 180 : CGFloat.random(in: 150...230),
                       floatsFor: mote ? 0.4 : Float.random(in: 2.2...3.4))
    }

    /// Coming down from high up, drifting.
    static func falling(near p: CGPoint, spread: CGFloat, texture: String, tint: SIMD4<Float>) -> Floater {
        let a = CGFloat.random(in: 0...(2 * .pi)), r = spread * sqrt(CGFloat.random(in: 0...1))
        return Floater(at: CGPoint(x: p.x + cos(a) * r, y: p.y + sin(a) * r * 0.8),
                       velocity: CGVector(dx: CGFloat.random(in: -14...14), dy: CGFloat.random(in: -10...10)),
                       lift: CGFloat.random(in: 200...380), up: 0,
                       size: CGFloat.random(in: 11...16), texture: texture, tint: tint,
                       gravity: CGFloat.random(in: 40...70), floatsFor: Float.random(in: 3...4.5))
    }

    private init(at p: CGPoint, velocity: CGVector, lift: CGFloat, up: CGFloat, size: CGFloat,
                 texture: String, tint: SIMD4<Float>, gravity: CGFloat, floatsFor: Float) {
        position = p
        self.velocity = velocity
        self.lift = lift
        liftVel = up
        self.size = size
        self.texture = texture
        self.tint = tint
        self.gravity = gravity
        self.floatsFor = floatsFor
        rotation = Float.random(in: 0...(2 * .pi))
        spin = Float.random(in: -3...3)
        phase = Float.random(in: 0...(2 * .pi))
    }

    var landed: Bool { landedFor >= 0 }
    var gone: Bool { landedFor > floatsFor + 1.5 }

    var alpha: Float {
        guard landed else { return 1 }
        return max(0, 1 - max(0, landedFor - floatsFor) / 1.5)
    }

    func update(dt: Float) {
        let d = CGFloat(dt)
        if landed {
            landedFor += dt
            // On the water it only drifts.
            position.x += velocity.dx * d * 0.15
            position.y += velocity.dy * d * 0.15
            return
        }
        phase += dt * 2.6
        // A falling petal slips sideways as it rocks.
        position.x += (velocity.dx + CGFloat(sin(phase)) * 22) * d
        position.y += velocity.dy * d
        rotation += spin * dt
        liftVel -= gravity * d
        // Air holds a petal back: it never falls faster than a flutter.
        liftVel = max(liftVel, -120)
        lift += liftVel * d
        if lift <= 0 {
            lift = 0
            landedFor = 0
        }
    }

    func sprite(textures: TextureCache) -> Sprite {
        let t = textures.size(texture)
        let long = max(t.width, t.height)
        let s = CGSize(width: size * t.width / max(1, long), height: size * t.height / max(1, long))
        if landed {
            return Sprite(texture, at: position, size: s, rotation: rotation, mode: .floater, alpha: alpha, tint: tint, z: 0)
        }
        var z = Float(lift) / WaterRenderer.depthScale
        // The band the canopy fades in is stepped over.
        if abs(z - 0.9) < 0.007 { z = 0.91 }
        return Sprite(texture, at: position, size: s, rotation: rotation, mode: .plain, alpha: 1, tint: tint, z: z)
    }
}

// MARK: - Who hands out the award

/// The draw goes through `Inventory.shared`; this only adds the forced tier
/// for a screenshot, which the real draw knows nothing about.
@MainActor
enum RewardSource {

    static func award(level: String, replay: Bool, using rng: inout SystemRandomNumberGenerator)
        -> (item: CatalogueItem, rarity: Rarity, petals: Int) {
        let drawn = Inventory.shared.award(level: level, replay: replay, using: &rng)
        guard let forced = RewardReveal.forcedTier, drawn.rarity != forced else { return drawn }
        // `-reward`: shown as an item of that tier, paid as that tier would
        // be. What the inventory recorded is the honest draw.
        let item = Catalogue.items(of: forced).randomElement(using: &rng)
            ?? CatalogueItem(id: drawn.item.id, name: drawn.item.name, category: drawn.item.category,
                             rarity: forced, art: drawn.item.art, placement: drawn.item.placement, size: drawn.item.size)
        return (item, forced, (replay ? PetalPay.replay : PetalPay.firstWin) + forced.petalBonus)
    }
}
