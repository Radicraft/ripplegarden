import SwiftUI

/// Paper and ink, the two colours the interface is allowed.
enum Ink {
    static let paper = Color(red: 0.965, green: 0.945, blue: 0.900)
    static let ink = Color(red: 0.106, green: 0.106, blue: 0.106)
    static let blossom = Color(red: 0.93, green: 0.55, blue: 0.65)
}

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
        .sheet(isPresented: $showSettings) { SettingsSheet() }
    }

    private var hud: some View {
        VStack {
            HStack(alignment: .top) {
                Button(action: onExit) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Ink.ink)
                        .frame(width: 34, height: 34)
                        .background(Ink.paper.opacity(0.85), in: Circle())
                }
                .padding(.leading, 18)
                .padding(.top, 8)
                .opacity(controller.phase == .playing ? 0.8 : 0)
                if controller.showTitle {
                    Text(controller.level.title)
                        .font(.system(size: 22, weight: .regular, design: .serif))
                        .foregroundStyle(Ink.paper)
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                        .padding(.leading, 22)
                        .padding(.top, 10)
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "leaf")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Ink.ink)
                        .frame(width: 34, height: 34)
                        .background(Ink.paper.opacity(0.85), in: Circle())
                }
                .padding(.trailing, 18)
                .padding(.top, 8)
                .opacity(controller.phase == .playing ? 0.8 : 0)
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

struct HintBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 16, design: .serif))
            .foregroundStyle(Ink.ink)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Ink.paper.opacity(0.94), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Ink.ink.opacity(0.35), lineWidth: 1))
            .padding(.horizontal, 40)
    }
}

struct CompletionCard: View {
    let season: Season
    let hasNext: Bool
    let next: () -> Void
    let garden: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("The pond is clear.")
                .font(.system(size: 22, weight: .regular, design: .serif))
                .foregroundStyle(Ink.ink)
            Text("The garden blooms a little further.")
                .font(.system(size: 15, design: .serif))
                .foregroundStyle(Ink.ink.opacity(0.75))
            HStack(spacing: 14) {
                Button(action: garden) {
                    Text("Garden")
                        .font(.system(size: 17, weight: .medium, design: .serif))
                        .foregroundStyle(Ink.ink)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .overlay(Capsule().stroke(Ink.ink.opacity(0.5), lineWidth: 1))
                }
                if hasNext {
                    Button(action: next) {
                        Text("Next")
                            .font(.system(size: 17, weight: .medium, design: .serif))
                            .foregroundStyle(Ink.paper)
                            .padding(.horizontal, 34)
                            .padding(.vertical, 10)
                            .background(Ink.ink, in: Capsule())
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 24)
        .background(Ink.paper.opacity(0.96), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Ink.ink.opacity(0.4), lineWidth: 1))
        .padding(.horizontal, 44)
    }
}

struct SettingsSheet: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var store = Store.shared
    @Environment(\.dismiss) private var dismiss
    @State private var restoring = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if !SoundDirector.killSwitch {
                        Toggle("Sound", isOn: $settings.soundOn)
                    }
                    Toggle("Haptics", isOn: $settings.hapticsOn)
                }
                Section {
                    Button {
                        restoring = true
                        Task { await store.restore(); restoring = false }
                    } label: {
                        HStack {
                            Text("Restore purchases")
                            Spacer()
                            if restoring { ProgressView() }
                        }
                    }
                    .disabled(restoring)
                }
                Section {
                    Text("Ripple Garden is a calm puzzle about water. Every level is a pond, every ripple is yours, and nothing can go wrong.")
                        .font(.system(size: 15, design: .serif))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.light)
    }
}
