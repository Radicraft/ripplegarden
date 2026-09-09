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

// MARK: - Washi

/// The two cuts of paper the game keeps: a square sheet and a tall one. Left
/// to itself the card takes whichever cut is nearest its own shape, so the
/// torn edge never has to stretch far.
enum PaperCut {
    case wide
    case tall

    var art: String { self == .wide ? "washi_card" : "washi_tall" }
}

/// A sheet of handmade paper, deckled edges and all.
struct PaperSheet: View {
    var cut: PaperCut? = nil
    var opacity: Double = 1

    var body: some View {
        GeometryReader { geo in
            let chosen = cut ?? (geo.size.height > geo.size.width * 1.2 ? PaperCut.tall : .wide)
            Group {
                if let image = Art.image(chosen.art) {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .brightness(0.05)
                        .saturation(0.8)
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Ink.paper)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .opacity(opacity)
        .allowsHitTesting(false)
    }
}

/// Anything the game says, said on a piece of paper. The inset keeps the
/// words clear of the torn edge.
struct PaperCard<Content: View>: View {
    var cut: PaperCut? = nil
    var inset: CGFloat = 26
    var opacity: Double = 1
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, inset)
            .padding(.vertical, inset * 0.85)
            .background(PaperSheet(cut: cut, opacity: opacity))
    }
}

/// A torn scrap, for one or two words over the water.
struct PaperChip<Content: View>: View {
    var opacity: Double = 1
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(PaperSheet(cut: .wide, opacity: opacity))
    }
}

// MARK: - Stones

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

/// Words cut into stone: a light face carries ink, a dark face carries paper,
/// and a hairline of the opposite tone seats the letters in the groove.
private struct Engraving: ViewModifier {
    let dark: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(dark ? Ink.paper.opacity(0.95) : Ink.ink.opacity(0.9))
            .shadow(color: dark ? .black.opacity(0.75) : .white.opacity(0.7), radius: 0.7, y: dark ? -0.8 : 0.8)
    }
}

/// Every button in the garden is a stone you press into the water. It sinks
/// two points and its shadow softens under it.
struct StoneButtonStyle: ButtonStyle {
    var dark: Bool = false
    var size: CGFloat = 17
    var hPad: CGFloat = 24
    var vPad: CGFloat = 11

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(Ink.label(size))
            .modifier(Engraving(dark: dark))
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .background(StoneFace(dark: dark))
            .shadow(color: .black.opacity(pressed ? 0.15 : 0.3), radius: pressed ? 4 : 9, y: pressed ? 2 : 6)
            .offset(y: pressed ? 2 : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.62), value: pressed)
    }
}

extension ButtonStyle where Self == StoneButtonStyle {
    static func stone(dark: Bool = false, size: CGFloat = 17, hPad: CGFloat = 24, vPad: CGFloat = 11) -> StoneButtonStyle {
        StoneButtonStyle(dark: dark, size: size, hPad: hPad, vPad: vPad)
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

/// A setting is two pebbles side by side. The one you chose is the dark one.
struct StonePair: View {
    let title: String
    @Binding var isOn: Bool
    var onLabel: String = "On"
    var offLabel: String = "Off"

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(Ink.body(16))
                .foregroundStyle(Ink.ink.opacity(0.85))
            Spacer(minLength: 8)
            Button(onLabel) { isOn = true }
                .buttonStyle(.stone(dark: isOn, size: 14, hPad: 15, vPad: 7))
            Button(offLabel) { isOn = false }
                .buttonStyle(.stone(dark: !isOn, size: 14, hPad: 15, vPad: 7))
        }
    }
}

// MARK: - Overlays

/// No sheets in the garden. A card falls onto the water from above, the water
/// darkens under it, and it lifts away again when you touch the water outside.
struct PondOverlay<Content: View>: View {
    @Binding var isPresented: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            if isPresented {
                RadialGradient(colors: [.black.opacity(0.12), .black.opacity(0.34)],
                               center: .center, startRadius: 40, endRadius: 560)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .contentShape(Rectangle())
                    .onTapGesture { isPresented = false }

                content()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.74), value: isPresented)
    }
}

/// Sound, feel, purchases and a word about the game, on one sheet of paper.
/// The Seasons pass, on washi: what it is and two stones to buy it with.
struct StoreCard: View {
    @ObservedObject private var store = Store.shared
    let onClose: () -> Void

    var body: some View {
        PaperCard(inset: 30) {
            VStack(spacing: 14) {
                Text("Seasons to come")
                    .font(Ink.title(24))
                    .foregroundStyle(Ink.ink)
                Text("New seasons, new levels and new looks for the garden arrive with the Seasons pass. The first year is yours to keep.")
                    .font(Ink.body(15))
                    .foregroundStyle(Ink.ink.opacity(0.8))
                    .multilineTextAlignment(.center)
                if store.isSubscribed {
                    Text("You have the Seasons pass. Thank you.")
                        .font(Ink.label(15))
                        .foregroundStyle(Ink.ink)
                } else if store.products.isEmpty {
                    Text("Coming soon")
                        .font(Ink.label(15))
                        .foregroundStyle(Ink.ink.opacity(0.6))
                } else {
                    HStack(spacing: 14) {
                        ForEach(store.products, id: \.id) { product in
                            Button {
                                Task { await store.purchase(product) }
                            } label: {
                                VStack(spacing: 2) {
                                    Text(product.id == Store.annualID ? "Yearly" : "Monthly")
                                    Text(product.displayPrice).font(Ink.body(13))
                                }
                            }
                            .buttonStyle(.stone(dark: true, size: 15, hPad: 18, vPad: 9))
                        }
                    }
                }
                Button("Done", action: onClose)
                    .buttonStyle(.stone(dark: true, size: 17, hPad: 30, vPad: 10))
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 28)
        // The first fetch runs at launch and may have found nothing (no
        // network yet). Ask again while the card is open.
        .task { if store.products.isEmpty { await store.load() } }
    }
}

struct SettingsCard: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var store = Store.shared
    @State private var restoring = false
    let onClose: () -> Void

    var body: some View {
        PaperCard(inset: 30) {
            VStack(spacing: 16) {
                Text("The garden")
                    .font(Ink.title(24))
                    .foregroundStyle(Ink.ink)

                VStack(spacing: 12) {
                    StonePair(title: "Sound", isOn: $settings.soundOn)
                    StonePair(title: "Haptics", isOn: $settings.hapticsOn)
                }

                Button {
                    restoring = true
                    Task { await store.restore(); restoring = false }
                } label: {
                    HStack(spacing: 8) {
                        Text("Restore purchases")
                        if restoring {
                            ProgressView().controlSize(.small).tint(Ink.ink)
                        }
                    }
                }
                .buttonStyle(.stone(size: 15, hPad: 18, vPad: 9))
                .disabled(restoring)

                Text("Ripple Garden is a calm puzzle about water. Every level is a pond, every ripple is yours, and nothing can go wrong.")
                    .font(Ink.body(14))
                    .foregroundStyle(Ink.ink.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Done", action: onClose)
                    .buttonStyle(.stone(dark: true, size: 16, hPad: 30, vPad: 10))
            }
            .frame(maxWidth: 250)
        }
        .floatingPaper(seed: 5)
        .padding(.horizontal, 40)
    }
}
