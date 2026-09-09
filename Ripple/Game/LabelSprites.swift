import CoreGraphics
import UIKit

/// The map's own words. There is no paper on the water and nothing floats:
/// a level's number, the season names and the title are set straight onto
/// the scene in paper white, each drawn once into a texture the sprite batch
/// carries like anything else, so they ride the surface, scroll with the
/// pads and cost nothing at 120 frames a second.
///
/// Menus and hints are not made here; those are real type over the pond.
enum LabelSprites {

    /// Newsreader at weight 300, the face the whole interface reads in. If
    /// it fails to load the system serif stands in at the same size.
    private static let serifFace = "NewsreaderRoman-Light"
    private static let paper = UIColor(red: 0.949, green: 0.937, blue: 0.902, alpha: 1)
    private static let vermilion = UIColor(red: 0.776, green: 0.282, blue: 0.184, alpha: 1)

    /// How a level's word is set: shut, the next one to play, or done.
    enum MarkerState: String {
        case locked, open, done
        var alpha: CGFloat { self == .locked ? 0.45 : 1 }
        var rule: Bool { self == .open }
    }

    private static func serif(_ points: CGFloat) -> UIFont {
        UIFont(name: serifFace, size: points) ?? UIFont.systemFont(ofSize: points, weight: .light)
    }

    /// A word set on the scene, in paper white over a soft dark shade so it
    /// holds over pale ice and over dark summer water alike. Drawn at twice
    /// the size it is shown at, for the retina.
    private static func words(_ text: String, points: CGFloat, alpha: CGFloat,
                              rule: Bool, key: String, textures: TextureCache) -> String {
        if textures.has(key) { return key }
        let font = serif(points * 2)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: paper.withAlphaComponent(alpha)]
        let s = NSAttributedString(string: text, attributes: attrs)
        let b = s.size()
        let pad: CGFloat = 24
        let ruleGap: CGFloat = rule ? 14 : 0
        let size = CGSize(width: min(4096, ceil(b.width) + pad * 2),
                          height: min(4096, ceil(b.height) + pad * 2 + ruleGap))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            // The same soft shade the gear carries, so pale ink holds on a
            // busy bed without an outline round every letter. It is laid
            // twice: once is not enough over bright mist or over ice.
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 3), blur: 10,
                                    color: UIColor(red: 0.043, green: 0.086, blue: 0.071, alpha: 0.85).cgColor)
            s.draw(at: CGPoint(x: pad, y: pad))
            s.draw(at: CGPoint(x: pad, y: pad))
            ctx.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
            s.draw(at: CGPoint(x: pad, y: pad))
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 2), blur: 6,
                                    color: UIColor(red: 0.043, green: 0.086, blue: 0.071, alpha: 0.7).cgColor)
            if rule {
                // The one accent in the whole game: a 2 pt rule under the
                // pond the player is being invited into.
                vermilion.setFill()
                UIBezierPath(rect: CGRect(x: pad, y: pad + ceil(b.height) + 6,
                                          width: ceil(b.width), height: 4)).fill()
            }
        }
        if let cg = image.cgImage { textures.register(key, image: cg) }
        return key
    }

    /// A level's number word under its pad: "one" ... "six".
    static func marker(_ text: String, state: MarkerState, textures: TextureCache) -> String {
        words(text, points: 22, alpha: state.alpha, rule: state.rule,
              key: "label_mark_\(text)_\(state.rawValue)", textures: textures)
    }

    /// The season names and the title, on the mist, in the same face.
    static func caption(_ text: String, points: CGFloat, textures: TextureCache) -> String {
        words(text, points: points, alpha: 1, rule: false,
              key: "label_cap_\(text)_\(Int(points))", textures: textures)
    }
}
