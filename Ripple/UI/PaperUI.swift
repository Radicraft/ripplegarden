import SwiftUI

/// Paper, ink and stone: the materials the interface is allowed.
///
/// Type is Shippori Mincho B1, an OFL Mincho whose Latin is a fine
/// transitional serif. The bundled faces are subset to Latin so the whole
/// family costs a few hundred kilobytes instead of forty megabytes. If a face
/// fails to load for any reason the system serif stands in at the same size,
/// so nothing moves.
enum Ink {
    static let paper = Color(red: 0.965, green: 0.945, blue: 0.900)
    static let ink = Color(red: 0.106, green: 0.106, blue: 0.106)
    static let blossom = Color(red: 0.93, green: 0.55, blue: 0.65)
    static let stone = Color(red: 0.74, green: 0.73, blue: 0.71)
    static let stoneDark = Color(red: 0.20, green: 0.23, blue: 0.24)

    private static let titleFace = "ShipporiMinchoB1-Regular"
    private static let labelFace = "ShipporiMinchoB1-Medium"
    private static let bodyFace = "ShipporiMincho-Regular"

    private static func loaded(_ name: String) -> Bool {
        UIFont(name: name, size: 12) != nil
    }

    private static let hasTitle = loaded(titleFace)
    private static let hasLabel = loaded(labelFace)
    private static let hasBody = loaded(bodyFace)

    /// Names, headings, the game's own voice.
    static func title(_ size: CGFloat) -> Font {
        hasTitle ? .custom(titleFace, fixedSize: size) : .system(size: size, weight: .regular, design: .serif)
    }

    /// Small type that has to hold its own over moving water.
    static func label(_ size: CGFloat) -> Font {
        hasLabel ? .custom(labelFace, fixedSize: size) : .system(size: size, weight: .medium, design: .serif)
    }

    /// Sentences.
    static func body(_ size: CGFloat) -> Font {
        hasBody ? .custom(bodyFace, fixedSize: size) : .system(size: size, design: .serif)
    }
}

/// Loose PNGs from the bundle, kept once they are read. The stones the HUD
/// wears are the only art the SwiftUI layer still draws.
enum Art {
    private static var cache: [String: UIImage] = [:]
    static func image(_ name: String) -> UIImage? {
        if let i = cache[name] { return i }
        guard let path = Bundle.main.path(forResource: name, ofType: "png"), let i = UIImage(contentsOfFile: path) else { return nil }
        cache[name] = i
        return i
    }
}

/// The face of a river stone, stretched to whatever it has to carry.
struct StoneFace: View {
    var dark: Bool

    var body: some View {
        Group {
            if let image = Art.image(dark ? "button_stone_dark" : "button_stone") {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Capsule().fill(dark ? Ink.stoneDark : Ink.stone)
            }
        }
        .allowsHitTesting(false)
    }
}

/// A small round pebble for the corner marks: back, and the leaf.
struct StoneIconButton: View {
    let symbol: String
    var diameter: CGFloat = 34
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.44, weight: .medium))
                .foregroundStyle(Ink.ink.opacity(0.85))
                .shadow(color: .white.opacity(0.6), radius: 0.7, y: 0.8)
                .frame(width: diameter, height: diameter)
                .background {
                    StoneFace(dark: false)
                        .scaledToFill()
                        .frame(width: diameter, height: diameter)
                        .clipShape(Circle())
                }
        }
        .buttonStyle(PebblePress())
    }
}

/// The same sink, for buttons that are not label-on-stone.
struct PebblePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .shadow(color: .black.opacity(pressed ? 0.14 : 0.28), radius: pressed ? 3 : 7, y: pressed ? 2 : 5)
            .offset(y: pressed ? 2 : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.62), value: pressed)
    }
}
