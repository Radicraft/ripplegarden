import SwiftUI

struct LevelView: View {

    @ObservedObject var controller: GameController
    let onExit: () -> Void
    @ObservedObject private var settings = Settings.shared
    @State private var showSettings = false

    var body: some View {
        ZStack {
            WaterView(controller: controller)
                .ignoresSafeArea()

            hud
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .overlay {
            PondOverlay(isPresented: $showSettings) {
                SettingsCard { showSettings = false }
            }
        }
    }

    private var hud: some View {
        VStack {
            HStack(alignment: .top) {
                StoneIconButton(symbol: "chevron.left", action: onExit)
                    .padding(.leading, 18)
                    .padding(.top, 8)
                    .opacity(controller.phase == .playing ? 0.9 : 0)
                if controller.showTitle {
                    Text(controller.level.title)
                        .font(Ink.title(22))
                        .foregroundStyle(Ink.paper)
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                        .padding(.leading, 22)
                        .padding(.top, 10)
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }
                Spacer()
                StoneIconButton(symbol: "leaf") { showSettings = true }
                    .padding(.trailing, 18)
                    .padding(.top, 8)
                    .opacity(controller.phase == .playing ? 0.9 : 0)
            }
            .animation(.easeInOut(duration: 0.8), value: controller.showTitle)

            Spacer()

            if let hint = controller.hint {
                HintBubble(text: hint.text)
                    .floatingPaper(seed: 1)
                    .padding(.bottom, 92)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            if controller.phase == .complete {
                CompletionCard(season: controller.season,
                               hasNext: Library.level(after: controller.level) != nil,
                               next: { controller.next() },
                               garden: onExit)
                .floatingPaper(seed: 2)
                .padding(.bottom, 86)
                .transition(.opacity.combined(with: .offset(y: 16)))
                .onAppear { controller.paperLanded(atScreenFraction: CGPoint(x: 0.5, y: 0.8)) }
            }
        }
    }
}

/// Paper on the water: it rides a slow swell, tilting a little as it bobs,
/// and its shadow moves with it. Every card and bubble in the game floats.
struct FloatingPaper: ViewModifier {
    let seed: Double

    func body(content: Content) -> some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate + seed * 3.7
            let bob = sin(t * 0.9) * 3 + sin(t * 1.7 + 1) * 1.2
            let tiltX = sin(t * 0.75 + 0.4) * 2.2
            let tiltY = sin(t * 0.55 + 2) * 1.6
            content
                .rotation3DEffect(.degrees(tiltX), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
                .rotation3DEffect(.degrees(tiltY), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                .offset(y: bob)
                .shadow(color: .black.opacity(0.28), radius: 10 + bob * 0.6, x: 2 + tiltY, y: 8 + bob)
        }
    }
}

extension View {
    func floatingPaper(seed: Double) -> some View { modifier(FloatingPaper(seed: seed)) }
}

/// A smaller cut of the same paper, for a word of help.
struct HintBubble: View {
    let text: String

    var body: some View {
        PaperCard(inset: 22) {
            Text(text)
                .font(Ink.body(16))
                .foregroundStyle(Ink.ink)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
    }
}

struct CompletionCard: View {
    let season: Season
    let hasNext: Bool
    let next: () -> Void
    let garden: () -> Void

    var body: some View {
        PaperCard(inset: 30) {
            VStack(spacing: 14) {
                Text("The pond is clear.")
                    .font(Ink.title(22))
                    .foregroundStyle(Ink.ink)
                Text("The garden blooms a little further.")
                    .font(Ink.body(15))
                    .foregroundStyle(Ink.ink.opacity(0.75))
                HStack(spacing: 14) {
                    Button("Garden", action: garden)
                        .buttonStyle(.stone(size: 17, hPad: 22, vPad: 10))
                    if hasNext {
                        Button("Next", action: next)
                            .buttonStyle(.stone(dark: true, size: 17, hPad: 30, vPad: 10))
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 44)
    }
}
