import StoreKit
import SwiftUI
import UIKit

/// The menus. There is no menu object in Ripple Garden: there is a moment
/// when the pond dims and words are on it. One full-bleed scrim, paper white
/// words set straight on it, 56pt rows, one vermilion hairline under the one
/// primary action. No panel, no card, no paper, no stone.
///
/// The pond never pauses behind it. The sim runs at full rate the whole time
/// a menu is up; only touch is taken away.

/// Which menu is up. The controllers publish it and the views draw it.
enum MenuScreen: Equatable {
    case settings, store, complete
}

/// The words low in the pond while the level plays: the line that opens it,
/// what is left, a hint. Never a menu, so never a scrim.
struct PondWords: Equatable, Hashable {
    var title: String?
    var line: String
}

/// Arriving is savoured, leaving is instant.
enum Motion {
    static let scrim = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.32)
    static let words = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.42)
    static let leave = Animation.timingCurve(0.4, 0, 0.6, 1, duration: 0.22)
    /// Per row, down the screen.
    static let stagger = 0.04
    /// The pond is allowed to go quiet on its own before the words come.
    static let completionPause = 0.9
}

/// The one layer. An ink wash whose composited value is what is specified,
/// not its alpha: the pond is first pulled down by a multiply and the ink
/// laid over it, so the result lands near #17251F over a black winter pond
/// and a sunlit summer one alike. The pond stays legible at about a fifth.
///
/// The design asks for an 18pt blur under it too. Blurring a live 120fps
/// Metal view every frame costs more than it buys once the pond is already
/// at a fifth, so the wash carries the contrast on its own.
private struct Scrim: View {
    /// How much of the ink lies over the pond.
    var ink: Double
    /// How much of the pond survives the multiply under it.
    var keep: Double

    var body: some View {
        ZStack {
            Rectangle().fill(Color(white: keep)).blendMode(.multiply)
            Rectangle().fill(Ink.scrim.opacity(ink))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// One line of a menu: 56pt tall, the full width of the pad, a hairline
/// above it. Well over Apple's 44pt default in both directions.
private struct Row<Trailing: View>: View {
    let label: String
    var primary = false
    /// A hairline above, unless the row stands on its own.
    var line = true
    var closing = false
    var press: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(Ink.label(Size.row))
                .tracking(0.15)
                .foregroundStyle(Ink.paper)
                .overlay(alignment: .bottom) {
                    if primary {
                        Rectangle().fill(Ink.vermilion).frame(height: 2).offset(y: 9)
                    }
                }
            Spacer(minLength: 0)
            trailing()
        }
        .frame(height: 56)
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            if line { Rectangle().fill(Ink.hairline).frame(height: 1) }
        }
        .overlay(alignment: .bottom) {
            if closing { Rectangle().fill(Ink.hairline).frame(height: 1) }
        }
        .onTapGesture { press?() }
    }
}

private extension Row where Trailing == EmptyView {
    init(_ label: String, primary: Bool = false, line: Bool = true, closing: Bool = false, press: (() -> Void)? = nil) {
        self.init(label: label, primary: primary, line: line, closing: closing, press: press) { EmptyView() }
    }
}

/// A menu over the pond. Both screens build the same thing.
struct MenuLayer: View {

    let screen: MenuScreen
    let sound: SoundDirector
    let haptics: Haptics
    /// Only the completion offers it, and only when a level follows.
    var hasNext = false
    let onClose: () -> Void
    var onGarden: () -> Void = {}
    var onNext: () -> Void = {}
    /// The completion's third word: the player's own pond, where what they
    /// just won has gone. Nil until RootView wires it.
    var onYourPond: (() -> Void)? = nil

    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var store = Store.shared
    @State private var up = false

    var body: some View {
        ZStack {
            Scrim(ink: screen == .complete ? 0.68 : 0.80,
                  keep: screen == .complete ? 0.60 : 0.50)
            // A tap on the water outside closes a menu. The completion does
            // not: the player chooses where they are going.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { if screen != .complete { onClose() } }
                .ignoresSafeArea()
            content
                .padding(.horizontal, 32)
        }
        .onAppear { up = true }
    }

    @ViewBuilder private var content: some View {
        switch screen {
        case .settings: settingsRows
        case .store: storeRows
        case .complete: completion
        }
    }

    // MARK: - Settings

    /// Three things and a way out. No header: it names the screen the player
    /// just opened. Restore hides itself once the pass is on.
    private var settingsRows: some View {
        VStack(spacing: 0) {
            rise(0) {
                Row(label: "Sound", closing: false) {
                    Toggle("", isOn: $settings.soundOn).labelsHidden().tint(Ink.vermilion)
                }
            }
            rise(1) {
                Row(label: "Haptics", closing: store.isSubscribed) {
                    Toggle("", isOn: $settings.hapticsOn).labelsHidden().tint(Ink.vermilion)
                }
            }
            if !store.isSubscribed {
                rise(2) {
                    Row("Restore purchases", closing: true, press: {
                        pressed()
                        Task { await Store.shared.restore() }
                    })
                }
            }
            rise(store.isSubscribed ? 2 : 3) {
                Row("Done", primary: true, line: false, press: { primaryPressed(); onClose() })
                    .padding(.top, 26)
            }
        }
    }

    // MARK: - Seasons pass

    /// The one screen where many words are right: the auto-renew disclosure
    /// is required, so it is set at 17pt and nothing competes with it.
    private var storeRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            rise(0) {
                Text("Seasons to come")
                    .font(Ink.serif(Size.word))
                    .tracking(1.12)
                    .foregroundStyle(Ink.paper)
            }
            rise(1) {
                Text("Winter, spring, summer and autumn are yours. The Seasons pass adds new seasons as they arrive, and renews monthly or yearly until you cancel.")
                    .font(Ink.label(Size.body))
                    .lineSpacing(6)
                    .foregroundStyle(Ink.paper.opacity(Ink.dim))
                    .padding(.top, 20)
                    .padding(.bottom, 26)
            }
            if store.isSubscribed {
                rise(2) { Row("You have the Seasons pass. Thank you.", closing: true) }
            } else if store.products.isEmpty {
                rise(2) { Row("Coming soon", closing: true) }
            } else {
                ForEach(Array(offers.enumerated()), id: \.element.id) { i, product in
                    rise(2 + i) {
                        Row(price(product), primary: i == 0, closing: i == offers.count - 1, press: {
                            primaryPressed()
                            Task { await store.purchase(product) }
                        })
                    }
                }
            }
            rise(4) {
                HStack(spacing: 26) {
                    legal("Terms", Store.termsURL)
                    if let privacy = Store.privacyURL { legal("Privacy", privacy) }
                    Spacer(minLength: 0)
                    Text("Done")
                        .font(Ink.label(Size.row))
                        .tracking(0.15)
                        .foregroundStyle(Ink.paper)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                        .onTapGesture { pressed(); onClose() }
                }
                .frame(height: 56)
                .padding(.top, 22)
            }
        }
    }

    /// The year first, because it is the one being offered.
    private var offers: [Product] {
        store.products.sorted { a, _ in a.id == Store.annualID }
    }

    private func price(_ product: Product) -> String {
        "\(product.id == Store.annualID ? "Year" : "Month") \(product.displayPrice)"
    }

    private func legal(_ word: String, _ url: URL) -> some View {
        Text(word)
            .font(Ink.label(Size.legal))
            .foregroundStyle(Ink.paper.opacity(Ink.dim))
            .frame(height: 44)
            .contentShape(Rectangle())
            .onTapGesture { pressed(); UIApplication.shared.open(url) }
    }

    // MARK: - The pond is clear

    /// Four words and three ways on: back to the garden, to your own pond,
    /// or the next level. No score, no stars, no time. The scrim is lighter
    /// here so the cleared pond is the thing you look at.
    private var completion: some View {
        GeometryReader { g in
            Text("The pond wakes.")
                .font(Ink.serif(Size.word))
                .tracking(1.12)
                .foregroundStyle(Ink.paper)
                .frame(width: g.size.width)
                .multilineTextAlignment(.center)
                .opacity(up ? 1 : 0)
                .offset(y: up ? 0 : 8)
                .animation(Motion.words.delay(0.26), value: up)
                .position(x: g.size.width / 2, y: g.size.height * 0.457)
            HStack(spacing: 0) {
                Text("Garden")
                    .font(Ink.label(Size.row))
                    .tracking(0.15)
                    .foregroundStyle(Ink.paper)
                    .frame(height: 56)
                    .contentShape(Rectangle())
                    .onTapGesture { pressed(); onGarden() }
                Spacer(minLength: 0)
                Text("Your pond")
                    .font(Ink.label(Size.row))
                    .tracking(0.15)
                    .foregroundStyle(Ink.paper)
                    .frame(height: 56)
                    .contentShape(Rectangle())
                    .onTapGesture { pressed(); onYourPond?() }
                Spacer(minLength: 0)
                if hasNext {
                    Text("Next")
                        .font(Ink.label(Size.row))
                        .tracking(0.15)
                        .foregroundStyle(Ink.paper)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Ink.vermilion).frame(height: 2).offset(y: 9)
                        }
                        .frame(height: 56)
                        .contentShape(Rectangle())
                        .onTapGesture { primaryPressed(); onNext() }
                }
            }
            .frame(width: g.size.width)
            .opacity(up ? 1 : 0)
            .offset(y: up ? 0 : 8)
            .animation(Motion.words.delay(0.38), value: up)
            .position(x: g.size.width / 2, y: g.size.height * 0.744)
        }
    }

    // MARK: - Arriving

    /// Each row rises 8pt into place, forty milliseconds after the one above.
    @ViewBuilder private func rise<V: View>(_ index: Int, @ViewBuilder _ view: () -> V) -> some View {
        view()
            .opacity(up ? 1 : 0)
            .offset(y: up ? 0 : 8)
            .animation(Motion.words.delay(Motion.stagger * Double(index)), value: up)
    }

    /// A tick of surface tension under the finger.
    private func pressed() {
        sound.tap(x: 0.5, weight: 0.3)
        haptics.tap(weight: 0.3)
    }

    /// The primary action gets the firm one.
    private func primaryPressed() {
        sound.plop()
        haptics.tap(weight: 0.9)
    }
}

/// Hints, the line that opens a level and what is left, low in the pond.
///
/// The one place the design changes its answer: no scrim, because dimming
/// the pond while the player is using the pond would be absurd. A 250pt veil
/// at the bottom instead, where their hands already are and the least is
/// happening. Paper white over unveiled sunlit shallows is 1.6:1; over the
/// veil it is 12:1.
struct PondVeil: View {
    let words: PondWords

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = words.title {
                Text(title)
                    .font(Ink.serif(Size.word))
                    .tracking(1.12)
            }
            Text(words.line)
                .font(Ink.serif(Size.prose))
                .tracking(0.24)
                .lineSpacing(6)
        }
        .foregroundStyle(Ink.paper)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.bottom, 96)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(alignment: .bottom) {
            LinearGradient(stops: [
                .init(color: Ink.veil.opacity(0), location: 0),
                .init(color: Ink.veil.opacity(0.72), location: 0.66),
                .init(color: Ink.veil.opacity(0.86), location: 1)
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: 250)
        }
        .ignoresSafeArea()
        // The water under the words is still the player's to work.
        .allowsHitTesting(false)
    }
}
