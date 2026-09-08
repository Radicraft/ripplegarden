import SpriteKit
import UIKit

/// Everything drawn above the water: the season's flora at the edges, the
/// koi, the debris, and the petals that fall when the garden blooms. It has no
/// physics of its own; the controller moves the debris and tells the scene
/// where things are.
final class GardenScene: SKScene {

    private let koiLayer = SKNode()
    private let debrisLayer = SKNode()
    private let floraLayer = SKNode()
    private let fxLayer = SKNode()

    private var branchLeft: [SKSpriteNode] = []
    private var branchRight: [SKSpriteNode] = []
    private var bank: SKSpriteNode?
    private var petalEmitter: SKEmitterNode?
    private var debrisNodes: [Int: SKSpriteNode] = [:]
    private var koi: [Koi] = []
    private var season: Season?
    private(set) var bloomStage = 0
    private var lastTime: TimeInterval = 0

    override init() {
        super.init(size: CGSize(width: 393, height: 852))
        scaleMode = .resizeFill
        backgroundColor = .clear
        anchorPoint = .zero
        koiLayer.zPosition = 10
        debrisLayer.zPosition = 20
        floraLayer.zPosition = 30
        fxLayer.zPosition = 40
        addChild(koiLayer)
        addChild(debrisLayer)
        addChild(floraLayer)
        addChild(fxLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func didChangeSize(_ oldSize: CGSize) {
        layout()
    }

    /// UIKit point (origin top-left) to scene point (origin bottom-left).
    func scenePoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: size.height - p.y)
    }

    // MARK: - Season dressing

    func configure(season: Season) {
        guard self.season?.id != season.id || branchLeft.isEmpty else { return }
        self.season = season
        floraLayer.removeAllChildren()
        koiLayer.removeAllChildren()
        fxLayer.removeAllChildren()
        branchLeft = []
        branchRight = []
        koi = []

        for name in season.bloomImages {
            let l = SKSpriteNode(texture: Sprites.texture(name))
            l.anchorPoint = CGPoint(x: 0, y: 1)
            l.alpha = 0
            floraLayer.addChild(l)
            branchLeft.append(l)

            let r = SKSpriteNode(texture: Sprites.texture(name))
            r.anchorPoint = CGPoint(x: 0, y: 1)
            r.xScale = -1
            r.alpha = 0
            floraLayer.addChild(r)
            branchRight.append(r)
        }

        let b = SKSpriteNode(texture: Sprites.texture(season.bankImage))
        b.anchorPoint = CGPoint(x: 0.5, y: 0)
        floraLayer.addChild(b)
        bank = b

        let e = SKEmitterNode()
        e.particleTexture = Sprites.texture(season.petalImage)
        e.particleBirthRate = 0
        e.particleLifetime = 7
        e.particleLifetimeRange = 3
        e.emissionAngle = -.pi / 2
        e.emissionAngleRange = 0.7
        e.particleSpeed = 24
        e.particleSpeedRange = 12
        e.yAcceleration = -7
        e.xAcceleration = 3
        e.particleRotationRange = .pi * 2
        e.particleRotationSpeed = 1.1
        e.particleScale = 0.13
        e.particleScaleRange = 0.05
        e.particleAlpha = 0.95
        e.particleAlphaSpeed = -0.11
        e.zPosition = 41
        fxLayer.addChild(e)
        petalEmitter = e

        let looks: [(String, CGFloat)] = [("koi_1", 3 * .pi / 4), ("koi_2", .pi / 4)]
        for (i, (name, nose)) in looks.enumerated() {
            let k = Koi(texture: Sprites.texture(name), noseAngle: nose, seed: i)
            koiLayer.addChild(k.node)
            koi.append(k)
        }

        layout()
    }

    private func layout() {
        guard size.width > 0, let season else { return }
        let w = size.width, h = size.height

        for (i, node) in branchLeft.enumerated() {
            let side = w * 0.66
            node.size = CGSize(width: side, height: side)
            node.position = CGPoint(x: -8, y: h + 10)
            node.zPosition = CGFloat(i)
        }
        for (i, node) in branchRight.enumerated() {
            let side = w * 0.50
            node.size = CGSize(width: side, height: side)
            node.position = CGPoint(x: w + 8, y: h - 58)
            node.zPosition = CGFloat(i)
        }
        if let bank, let tex = bank.texture {
            let bw = w * 1.06
            bank.size = CGSize(width: bw, height: bw * tex.size().height / tex.size().width)
            bank.position = CGPoint(x: w / 2, y: -6)
        }
        petalEmitter?.position = CGPoint(x: w / 2, y: h + 12)
        petalEmitter?.particlePositionRange = CGVector(dx: w, dy: 0)
        _ = season
    }

    // MARK: - Bloom

    /// Snaps or fades to a stage, 0 (bare) to 3 (full).
    func setBloom(stage: Int, animated: Bool) {
        let s = max(0, min(3, stage))
        bloomStage = s
        for (i, node) in branchLeft.enumerated() {
            let target: CGFloat = i == s ? 1 : 0
            if animated { node.run(.fadeAlpha(to: target, duration: 1.0)) } else { node.alpha = target }
        }
        for (i, node) in branchRight.enumerated() {
            let target: CGFloat = i == s ? 1 : 0
            if animated { node.run(.fadeAlpha(to: target, duration: 1.0)) } else { node.alpha = target }
        }
    }

    /// Blooms stage by stage up to the target, then lets petals fall.
    func bloom(to target: Int, duration: TimeInterval) {
        let t = max(0, min(3, target))
        guard t > bloomStage else { return }
        let steps = t - bloomStage
        let per = duration / Double(steps)
        var delay: TimeInterval = 0
        for stage in (bloomStage + 1)...t {
            let fadeIn: SKAction = .sequence([.wait(forDuration: delay),
                                              .group([.fadeAlpha(to: 1, duration: per * 0.85),
                                                      .sequence([.scale(to: 1.025, duration: per * 0.45),
                                                                 .scale(to: 1.0, duration: per * 0.45)])])])
            let fadeOut: SKAction = .sequence([.wait(forDuration: delay + per * 0.25),
                                               .fadeAlpha(to: 0, duration: per * 0.6)])
            branchLeft[stage].run(fadeIn)
            branchRight[stage].run(fadeIn)
            branchLeft[stage - 1].run(fadeOut)
            branchRight[stage - 1].run(fadeOut)
            delay += per
        }
        bloomStage = t

        if t == 3, let e = petalEmitter {
            e.run(.sequence([.wait(forDuration: duration * 0.55),
                             .run { e.particleBirthRate = 5 },
                             .wait(forDuration: 9),
                             .run { e.particleBirthRate = 0 }]))
        }
    }

    // MARK: - Debris

    func addDebris(_ d: Debris) {
        let node = SKSpriteNode(texture: Sprites.texture(d.sprite))
        let side = d.radius * 2
        if let tex = node.texture {
            let aspect = tex.size().height / max(1, tex.size().width)
            node.size = CGSize(width: side, height: side * aspect)
        } else {
            node.size = CGSize(width: side, height: side)
        }
        node.position = scenePoint(d.position)
        node.zRotation = d.angle
        node.alpha = 0
        node.setScale(0.6)
        node.run(.group([.fadeIn(withDuration: 0.5), .scale(to: 1, duration: 0.5)]))
        debrisLayer.addChild(node)
        debrisNodes[d.id] = node
    }

    func removeAllDebris() {
        debrisLayer.removeAllChildren()
        debrisNodes.removeAll()
    }

    func update(debris: [Debris]) {
        for d in debris where !d.cleared {
            guard let node = debrisNodes[d.id] else { continue }
            node.position = scenePoint(d.position)
            node.zRotation = d.angle
            // A crest lifts the piece a little toward the eye.
            let bob = 1.0 + CGFloat(max(-0.3, min(0.3, d.height * 0.9)))
            node.setScale(bob)
        }
    }

    /// The piece has reached the bank: it drifts the last stretch into the
    /// reeds and settles out of sight, with a few petals for company.
    func clear(_ d: Debris, in viewSize: CGSize) {
        guard let node = debrisNodes.removeValue(forKey: d.id) else { return }
        let p = d.position
        let toLeft = p.x, toRight = viewSize.width - p.x
        let toTop = p.y, toBottom = viewSize.height - p.y
        let m = min(toLeft, toRight, toTop, toBottom)
        var dir = CGVector(dx: 0, dy: 0)
        if m == toLeft { dir.dx = -1 } else if m == toRight { dir.dx = 1 }
        else if m == toTop { dir.dy = 1 } else { dir.dy = -1 }

        node.run(.sequence([
            .group([.move(by: CGVector(dx: dir.dx * 26, dy: dir.dy * 26), duration: 0.7),
                    .scale(to: 0.55, duration: 0.7),
                    .rotate(byAngle: 0.6, duration: 0.7),
                    .fadeOut(withDuration: 0.6)]),
            .removeFromParent()]))

        if let tex = petalEmitter?.particleTexture {
            let puff = SKEmitterNode()
            puff.particleTexture = tex
            puff.numParticlesToEmit = 4
            puff.particleBirthRate = 40
            puff.particleLifetime = 1.4
            puff.particleSpeed = 30
            puff.particleSpeedRange = 14
            puff.emissionAngleRange = .pi * 2
            puff.particleScale = 0.08
            puff.particleAlphaSpeed = -0.7
            puff.particleRotationSpeed = 2
            puff.position = node.position
            fxLayer.addChild(puff)
            puff.run(.sequence([.wait(forDuration: 2), .removeFromParent()]))
        }
    }

    // MARK: - Koi

    func koiHit(at point: CGPoint) -> Koi? {
        let p = scenePoint(point)
        return koi.first { $0.visible && hypot($0.node.position.x - p.x, $0.node.position.y - p.y) < 42 }
    }

    func dive(_ k: Koi) {
        k.dive(now: lastTime, quick: true)
    }

    override func update(_ currentTime: TimeInterval) {
        let dt = lastTime == 0 ? 1.0 / 60.0 : min(0.05, currentTime - lastTime)
        lastTime = currentTime
        for k in koi { k.update(dt: dt, now: currentTime, in: size) }
    }
}

/// A fish that wanders under the surface, shows itself for a while, and dives
/// when it feels like it or when it is tapped.
final class Koi {
    let node: SKSpriteNode
    private let noseAngle: CGFloat
    private(set) var visible = false
    private var heading: CGFloat
    private var target = CGPoint.zero
    private var stateUntil: TimeInterval = 0
    private var speed: CGFloat = 34
    private var started = false

    init(texture: SKTexture?, noseAngle: CGFloat, seed: Int) {
        node = SKSpriteNode(texture: texture)
        if let texture {
            let w: CGFloat = 78
            node.size = CGSize(width: w, height: w * texture.size().height / texture.size().width)
        }
        node.alpha = 0
        node.color = UIColor(red: 0.55, green: 0.8, blue: 0.85, alpha: 1)
        node.colorBlendFactor = 0.22
        self.noseAngle = noseAngle
        heading = CGFloat(seed) * 1.7
        stateUntil = 3 + Double(seed) * 4
    }

    func update(dt: TimeInterval, now: TimeInterval, in size: CGSize) {
        guard size.width > 0 else { return }
        if !started {
            started = true
            node.position = CGPoint(x: CGFloat.random(in: 80...(size.width - 80)),
                                    y: CGFloat.random(in: 140...(size.height - 160)))
            pickTarget(in: size)
        }
        if now > stateUntil {
            if visible { dive(now: now, quick: false) } else { surface(now: now, in: size) }
        }
        guard visible else { return }

        let dx = target.x - node.position.x, dy = target.y - node.position.y
        if hypot(dx, dy) < 30 { pickTarget(in: size) }
        let want = atan2(dy, dx)
        var diff = want - heading
        while diff > .pi { diff -= 2 * .pi }
        while diff < -.pi { diff += 2 * .pi }
        heading += max(-1.2 * dt, min(1.2 * dt, diff))
        node.position.x += cos(heading) * speed * dt
        node.position.y += sin(heading) * speed * dt
        node.zRotation = heading - noseAngle + sin(now * 5) * 0.05
    }

    private func pickTarget(in size: CGSize) {
        target = CGPoint(x: CGFloat.random(in: 70...(size.width - 70)),
                         y: CGFloat.random(in: 130...(size.height - 150)))
        speed = CGFloat.random(in: 26...44)
    }

    private func surface(now: TimeInterval, in size: CGSize) {
        visible = true
        node.position = CGPoint(x: CGFloat.random(in: 80...(size.width - 80)),
                                y: CGFloat.random(in: 140...(size.height - 160)))
        pickTarget(in: size)
        heading = atan2(target.y - node.position.y, target.x - node.position.x)
        node.run(.fadeAlpha(to: 0.82, duration: 1.6))
        stateUntil = now + Double.random(in: 7...13)
    }

    func dive(now: TimeInterval, quick: Bool) {
        guard visible else { return }
        visible = false
        speed = quick ? 90 : speed
        node.removeAllActions()
        node.run(.sequence([.fadeOut(withDuration: quick ? 0.35 : 1.4)]))
        stateUntil = now + Double.random(in: quick ? 6...11 : 4...9)
    }
}

/// Texture cache keyed by resource name. Art lives as loose PNGs in the
/// bundle, not in an asset catalog, so it can be swapped by dropping in files.
enum Sprites {
    private static var cache: [String: SKTexture] = [:]

    static func texture(_ name: String) -> SKTexture? {
        if let t = cache[name] { return t }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        let t = SKTexture(image: image)
        cache[name] = t
        return t
    }
}
