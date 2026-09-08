import SwiftUI

/// Paper and ink, the two colours the interface is allowed.
enum Ink {
    static let paper = Color(red: 0.965, green: 0.945, blue: 0.900)
    static let ink = Color(red: 0.106, green: 0.106, blue: 0.106)
    static let blossom = Color(red: 0.93, green: 0.55, blue: 0.65)
}

struct LevelView: View {

    @ObservedObject var controller: GameController
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
                    .padding(.bottom, 92)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            if controller.phase == .complete {
                CompletionCard(season: controller.season) {
                    controller.next()
                }
                .padding(.bottom, 86)
                .transition(.opacity.combined(with: .offset(y: 16)))
            }
        }
    }
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
    let next: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("The pond is clear.")
                .font(.system(size: 22, weight: .regular, design: .serif))
                .foregroundStyle(Ink.ink)
            Text("The garden blooms a little further.")
                .font(.system(size: 15, design: .serif))
                .foregroundStyle(Ink.ink.opacity(0.75))
            Button(action: next) {
                Text("Next")
                    .font(.system(size: 17, weight: .medium, design: .serif))
                    .foregroundStyle(Ink.paper)
                    .padding(.horizontal, 34)
                    .padding(.vertical, 10)
                    .background(Ink.ink, in: Capsule())
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
    @Environment(\.dismiss) private var dismiss

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
