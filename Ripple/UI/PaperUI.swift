import SwiftUI

/// The materials the interface is allowed: paper white on an ink scrim, one
/// vermilion accent, and two faces.
///
/// The serif is Newsreader at weight 300, the variable font from Google
/// Fonts, used for the few words that are read: a level's name, "Seasons to
/// come", "The pond is clear.", the hints. Every word that is pressed is set
/// in the system face, which is Apple's own answer to legibility in a game.
/// If the bundled face fails to load the system serif stands in at the same
/// size, so nothing moves.
enum Ink {
    /// Paper white. 13.8:1 on the scrim.
    static let paper = Color(red: 0.949, green: 0.937, blue: 0.902)
    /// The scrim's own colour, which is the composited value the design
    /// asks for rather than an alpha: the pond is pulled down under it and
    /// this laid over, so the result lands here whatever the season.
    static let scrim = Color(red: 0.090, green: 0.145, blue: 0.122)
    /// The veil under a hint, which is mixed over a pond at full brightness.
    static let veil = Color(red: 0.043, green: 0.086, blue: 0.071)
    /// The koi's colour. A hairline and a switch only, never a word: 3.3:1
    /// carries a 2pt rule and fails body text.
    static let vermilion = Color(red: 0.776, green: 0.282, blue: 0.184)
    /// The line between rows. Decorative; the rows read without it.
    static let hairline = Color(red: 0.949, green: 0.937, blue: 0.902).opacity(0.14)
    /// Secondary text: the disclosure, Terms, Privacy. 7.8:1.
    static let dim = 0.72

    private static let serifFace = "NewsreaderRoman-Light"
    private static let hasSerif = UIFont(name: serifFace, size: 12) != nil

    /// The words that are read.
    static func serif(_ size: CGFloat) -> Font {
        hasSerif ? .custom(serifFace, fixedSize: size) : .system(size: size, weight: .light, design: .serif)
    }

    /// The words that are pressed.
    static func label(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular)
    }
}

/// The six roles the whole game is set in, and nothing else. Sizes are in
/// points and none is under 15.
enum Size {
    /// "Ripple Garden".
    static let display: CGFloat = 40
    /// A screen's one word: "Seasons to come", "The pond is clear.".
    static let word: CGFloat = 28
    /// Hints, a level's goal, what is left.
    static let prose: CGFloat = 20
    /// Anything operable.
    static let row: CGFloat = 19
    /// The subscription disclosure.
    static let body: CGFloat = 17
    /// Terms and Privacy.
    static let legal: CGFloat = 15
}

/// Loose PNGs from the bundle, kept once they are read.
enum Art {
    private static var cache: [String: UIImage] = [:]
    static func image(_ name: String) -> UIImage? {
        if let i = cache[name] { return i }
        guard let path = Bundle.main.path(forResource: name, ofType: "png"), let i = UIImage(contentsOfFile: path) else { return nil }
        cache[name] = i
        return i
    }
}

/// The one icon the game has, in a 44pt target. A system glyph, because an
/// invented mark costs the player a guess and buys nothing.
struct GlyphButton: View {
    let symbol: String
    /// Where it was pressed, so a menu can drop its ring in the real water
    /// at the place the player asked from.
    var action: (CGPoint) -> Void

    @State private var centre: CGPoint = .zero

    var body: some View {
        Button { action(centre) } label: {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Ink.paper.opacity(0.72))
                // The bank is pale in summer, so the glyph carries its own
                // shade rather than trusting the water behind it.
                .shadow(color: Ink.veil.opacity(0.65), radius: 5, y: 1)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .background {
                    GeometryReader { g in
                        Color.clear.onAppear {
                            let f = g.frame(in: .global)
                            centre = CGPoint(x: f.midX, y: f.midY)
                        }
                    }
                }
        }
        .buttonStyle(.plain)
    }
}
