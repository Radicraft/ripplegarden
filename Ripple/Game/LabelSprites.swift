import CoreGraphics
import UIKit

/// Words on the water. Level names are painted onto a scrap of washi and
/// the season names and title straight onto the air in paper ink, each
/// once, into a texture the sprite batch draws like anything else: they
/// ride the surface and move with the camera, never a layer stuck on the
/// glass over the pond.
enum LabelSprites {

    private static let chipFace = "ShipporiMinchoB1-Medium"
    private static let captionFace = "ShipporiMinchoB1-Regular"
    private static let bodyFace = "ShipporiMincho-Regular"
    private static let ink = UIColor(red: 0.106, green: 0.106, blue: 0.106, alpha: 1)
    private static let paper = UIColor(red: 0.965, green: 0.945, blue: 0.900, alpha: 1)
    private static let blossom = UIColor(red: 0.93, green: 0.55, blue: 0.65, alpha: 1)

    /// A washi chip carrying a level's name; a blossom dot when it is done.
    /// Returns the texture name. Drawn at 2x for the retina.
    static func chip(_ text: String, done: Bool, textures: TextureCache, wide: Bool = false) -> String {
        let name = "label_chip_\(text)_\(done ? 1 : 0)_\(wide ? "w" : "n")"
        if textures.has(name) { return name }
        let size = wide ? CGSize(width: 320, height: 84) : CGSize(width: 180, height: 76)
        let renderer = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = false; return f }())
        let image = renderer.image { ctx in
            if let washi = UIImage(named: "washi_card") ?? bundleImage("washi_card") {
                washi.draw(in: CGRect(origin: .zero, size: size))
            } else {
                paper.setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4), cornerRadius: 10).fill()
            }
            let font = UIFont(name: chipFace, size: 30) ?? UIFont.systemFont(ofSize: 30, weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
            let s = NSAttributedString(string: text, attributes: attrs)
            let b = s.size()
            s.draw(at: CGPoint(x: (size.width - b.width) / 2, y: (size.height - b.height) / 2 - 1))
            if done {
                blossom.setFill()
                UIBezierPath(ovalIn: CGRect(x: size.width - 34, y: 16, width: 12, height: 12)).fill()
            }
        }
        if let cg = image.cgImage { textures.register(name, image: cg) }
        return name
    }

    /// A caption in paper ink with a soft shadow, on nothing.
    static func caption(_ text: String, points: CGFloat, textures: TextureCache) -> String {
        let name = "label_cap_\(text)_\(Int(points))"
        if textures.has(name) { return name }
        let font = UIFont(name: captionFace, size: points * 2) ?? UIFont.systemFont(ofSize: points * 2, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: paper]
        let s = NSAttributedString(string: text, attributes: attrs)
        let b = s.size()
        // Long words are cut rather than asking for a texture no device takes.
        let size = CGSize(width: min(4096, ceil(b.width) + 40), height: min(4096, ceil(b.height) + 40))
        let renderer = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = false; return f }())
        let image = renderer.image { ctx in
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 4), blur: 12, color: UIColor.black.withAlphaComponent(0.45).cgColor)
            s.draw(at: CGPoint(x: 20, y: 20))
        }
        if let cg = image.cgImage { textures.register(name, image: cg) }
        return name
    }

    /// Body copy in paper ink: centred, wrapped to a width, one soft shadow
    /// under the lot. This is what the menus and the hints are written in.
    /// `width` and `points` are in the same units the caption uses; the
    /// picture is drawn at twice that.
    static func words(_ text: String, points: CGFloat, textures: TextureCache, width: CGFloat) -> String {
        let name = "label_words_\(text)_\(Int(points))_\(Int(width))"
        if textures.has(name) { return name }
        let font = UIFont(name: bodyFace, size: points * 2) ?? UIFont.systemFont(ofSize: points * 2, weight: .regular)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineSpacing = points * 0.28
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: paper, .paragraphStyle: style]
        let s = NSAttributedString(string: text, attributes: attrs)
        let wrap = min(3800, max(80, width * 2))
        let bounds = s.boundingRect(with: CGSize(width: wrap, height: 4000),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let size = CGSize(width: wrap + 40, height: min(4096, ceil(bounds.height) + 40))
        let renderer = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = false; return f }())
        let image = renderer.image { ctx in
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 4), blur: 12, color: UIColor.black.withAlphaComponent(0.45).cgColor)
            s.draw(with: CGRect(x: 20, y: 20, width: wrap, height: size.height - 40),
                   options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
        if let cg = image.cgImage { textures.register(name, image: cg) }
        return name
    }

    private static func bundleImage(_ name: String) -> UIImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}
