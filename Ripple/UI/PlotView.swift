import SwiftUI

/// The way from the map to the plot. RootView sets it on HubView; the hub's
/// sideways swipe calls it once that is wired (`@Environment(\.openPlot)`).
struct OpenPlotKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var openPlot: () -> Void {
        get { self[OpenPlotKey.self] }
        set { self[OpenPlotKey.self] = newValue }
    }
}

// MARK: - Which plot a controller works

/// A plot controller that knows which plot along the bank it is. The
/// pager asks for this when it makes a controller; until `PlotController`
/// carries an index of its own every controller works plot 0.
protocol PlotIndexed: AnyObject {
    var plotIndex: Int { get set }
}

extension PlotController {
    /// The controller for one plot along the bank.
    static func make(index: Int) -> PlotController {
        let c = PlotController()
        if let indexed = c as? any PlotIndexed { indexed.plotIndex = index }
        return c
    }
}

// MARK: - The plots along the bank

/// The plots in a row along the bank: the ones owned, each its own
/// controller made when its page is turned to and let go when it is
/// left, and past the last one a page for the next plot to be bought.
@MainActor
final class PlotPager: ObservableObject {

    /// The page open now: a plot index. Owned, or the one for sale.
    @Published private(set) var index: Int = 0
    /// The controller for the open page, nil on the page for sale.
    @Published private(set) var controller: PlotController?
    /// Which way the last turn went, for the slide.
    @Published private(set) var forward = true

    private let inventory = Inventory.shared

    /// The pages in order: every plot owned, then the next for sale.
    var pages: [Int] {
        var out = inventory.ownedPlotIndices
        if let next = inventory.nextPlotIndex { out.append(next) }
        return out
    }

    var position: Int { pages.firstIndex(of: index) ?? 0 }
    var isLocked: Bool { !inventory.ownsPlot(index) }
    var canGoBack: Bool { position > 0 }
    var canGoForward: Bool { position + 1 < pages.count }

    /// Coming onto the plots: the page's controller is made if it is not.
    func arrive() {
        if !pages.contains(index) { index = 0 }
        if controller == nil, inventory.ownsPlot(index) { controller = PlotController.make(index: index) }
    }

    /// Going back to the map: the plot is written now. The controller is
    /// kept, so the page does not change under the fade, and is attached
    /// afresh when the plots are next visited.
    func leave() {
        controller?.leave()
    }

    func turn(by step: Int) {
        let pages = pages
        let to = position + step
        guard to >= 0, to < pages.count, pages[to] != index else { return }
        forward = step > 0
        controller?.leave()
        controller = nil
        index = pages[to]
        if inventory.ownsPlot(index) { controller = PlotController.make(index: index) }
    }

    /// The page for sale is paid for: it becomes a plot of its own.
    func dig() {
        guard isLocked, inventory.buyPlot(index) else { return }
        controller = PlotController.make(index: index)
    }
}

// MARK: - The screen

/// The player's own pond, or the page for the next plot along the bank.
/// One pager overlay along the bottom turns between them; the edges of
/// the bank turn too when a finger is drawn across them.
struct PlotView: View {

    @ObservedObject var pager: PlotPager
    @ObservedObject private var inventory = Inventory.shared
    let onExit: () -> Void

    var body: some View {
        ZStack {
            if let plot = pager.controller {
                PlotPage(plot: plot, pager: pager, onExit: onExit)
                    .id(pager.index)
                    .transition(slide)
            } else {
                LockedPlotPage(pager: pager, onExit: onExit)
                    .id(pager.index)
                    .transition(slide)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear { pager.arrive() }
    }

    private var slide: AnyTransition {
        .asymmetric(insertion: .move(edge: pager.forward ? .trailing : .leading),
                    removal: .move(edge: pager.forward ? .leading : .trailing))
    }
}

/// The two stone dots and the words between them: "‹ 1 of 3 ›". Drawn
/// only when there is more than one page to turn to.
private struct PagerBar: View {
    @ObservedObject var pager: PlotPager

    var body: some View {
        let pages = pager.pages
        if pages.count > 1 {
            VStack {
                Spacer()
                HStack(spacing: 14) {
                    Button { turn(-1) } label: { chevron("chevron.left", on: pager.canGoBack) }
                        .disabled(!pager.canGoBack)
                    Text("\(pager.position + 1) of \(pages.count)")
                        .font(Ink.serif(Size.body))
                        .foregroundStyle(Ink.paper)
                    Button { turn(1) } label: { chevron("chevron.right", on: pager.canGoForward) }
                        .disabled(!pager.canGoForward)
                }
                .shadow(color: Ink.veil.opacity(0.65), radius: 5, y: 1)
                .padding(.bottom, 30)
            }
        }
    }

    private func chevron(_ symbol: String, on: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(Ink.paper.opacity(on ? 0.72 : 0.25))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private func turn(_ step: Int) {
        withAnimation(.easeInOut(duration: 0.45)) { pager.turn(by: step) }
    }
}

/// Strips at the bank's edges a finger can be drawn across to turn the
/// page: the whole left edge under the chevron, and the right edge clear
/// of the sluice stone and the tray's stone.
private struct EdgeTurns: View {
    @ObservedObject var pager: PlotPager

    var body: some View {
        GeometryReader { g in
            let h = g.size.height
            ZStack(alignment: .topLeading) {
                strip.frame(width: 22, height: max(0, h - 80)).offset(x: 0, y: 70)
                strip.frame(width: 22, height: max(0, h * 0.34 - 70)).offset(x: g.size.width - 22, y: 70)
                strip.frame(width: 22, height: max(0, h - 160 - h * 0.52)).offset(x: g.size.width - 22, y: h * 0.52)
            }
        }
    }

    private var strip: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 20).onEnded { v in
                let dx = v.translation.width, dy = v.translation.height
                guard abs(dx) > 60, abs(dx) > abs(dy) * 1.6 else { return }
                withAnimation(.easeInOut(duration: 0.45)) { pager.turn(by: dx < 0 ? 1 : -1) }
            })
    }
}

/// One owned plot: the water, a chevron back to the map, the petal purse
/// in the top corner, the settings gear where the map keeps it, one line
/// on the first visit, and the pager along the bottom.
private struct PlotPage: View {

    @ObservedObject var plot: PlotController
    @ObservedObject var pager: PlotPager
    @ObservedObject private var inventory = Inventory.shared
    @ObservedObject private var tutorial = Tutorial.shared
    let onExit: () -> Void

    var body: some View {
        ZStack {
            WaterView(input: plot, worldScale: PlotController.worldScale, gridLongSide: PlotController.gridLongSide) { renderer in
                plot.attach(renderer: renderer)
            }
            .ignoresSafeArea()

            words
            EdgeTurns(pager: pager)
                .opacity(plot.presented == nil ? 1 : 0)
                .allowsHitTesting(plot.presented == nil)
            hud
            PagerBar(pager: pager)
                .opacity(plot.presented == nil ? 1 : 0)
                .animation(Motion.leave, value: plot.presented)
            gear
            menu
        }
        .onAppear { plot.onExit = onExit }
    }

    /// The first visit's one line, low in the water like a level's; the
    /// first walk's line in its place while the walk is on.
    @ViewBuilder private var words: some View {
        ZStack {
            if let w = tutorial.lines[.plot] ?? plot.words, plot.presented == nil {
                PondVeil(words: w)
                    .transition(.opacity)
                    .id(w)
            }
        }
        .animation(Motion.words, value: plot.words)
        .animation(Motion.words, value: tutorial.lines)
        .allowsHitTesting(false)
    }

    /// Back at the top left; the petals at the top right, in the serif.
    private var hud: some View {
        VStack {
            HStack(alignment: .center) {
                GlyphButton(symbol: "chevron.left") { _ in
                    pager.leave()
                    onExit()
                }
                // The first walk's ring on the way back to the stream.
                .overlay { TutorialPulse(on: tutorial.spot(for: .plot) == .chevron, diameter: 60) }
                Spacer()
                PetalPurse(petals: inventory.petals)
                    .padding(.trailing, 6)
            }
            .padding(.horizontal, 18)
            .opacity(plot.presented == nil ? 1 : 0)
            .animation(Motion.leave, value: plot.presented)
            Spacer()
        }
    }

    private var gear: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                GlyphButton(symbol: "gearshape") { plot.openSettings(from: $0) }
            }
            .padding(.trailing, 12)
            .padding(.bottom, 22)
        }
        .opacity(plot.presented == nil ? 1 : 0)
        .animation(Motion.leave, value: plot.presented)
    }

    @ViewBuilder private var menu: some View {
        if let screen = plot.presented {
            MenuLayer(screen: screen,
                      sound: plot.sound,
                      haptics: plot.haptics,
                      onClose: { plot.closeMenu() })
                .transition(.opacity)
        }
    }
}

/// The petal count in the serif, with its word. The map and the plot
/// both wear it.
struct PetalPurse: View {
    let petals: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("\(petals)")
                .font(Ink.serif(Size.prose))
            Text(petals == 1 ? "petal" : "petals")
                .font(Ink.serif(Size.body))
                .opacity(Ink.dim)
        }
        .foregroundStyle(Ink.paper)
        .shadow(color: Ink.veil.opacity(0.65), radius: 5, y: 1)
    }
}

/// The page past the last plot owned: the bank scene dimmed, the price,
/// and a stone to press to dig it. Nothing here costs money; the plot is
/// paid for in petals picked off the water.
private struct LockedPlotPage: View {

    @ObservedObject var pager: PlotPager
    @ObservedObject private var inventory = Inventory.shared
    let onExit: () -> Void

    private var price: Int { Inventory.plotPrice(pager.index) }
    private var canPay: Bool { inventory.petals >= price }

    var body: some View {
        ZStack {
            bank
            EdgeTurns(pager: pager)
            VStack(spacing: 22) {
                Text("A new plot. \(price) petals.")
                    .font(Ink.serif(Size.word))
                    .tracking(1.12)
                    .multilineTextAlignment(.center)
                if !canPay {
                    Text(inventory.petals == 1 ? "You have 1 petal." : "You have \(inventory.petals) petals.")
                        .font(Ink.serif(Size.prose))
                        .opacity(Ink.dim)
                }
                StoneButton(label: "Dig it", on: canPay) {
                    withAnimation(.easeInOut(duration: 0.45)) { pager.dig() }
                }
                .padding(.top, 8)
            }
            .foregroundStyle(Ink.paper)
            .shadow(color: Ink.veil.opacity(0.65), radius: 5, y: 1)
            .padding(.horizontal, 32)
            hud
            PagerBar(pager: pager)
        }
    }

    /// The bank painting the plots all wear, pulled down under a wash.
    private var bank: some View {
        ZStack {
            Ink.scrim
            if let image = Art.image("bank_spring") {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            Rectangle().fill(Color(white: 0.42)).blendMode(.multiply)
            Rectangle().fill(Ink.scrim.opacity(0.35))
        }
        .ignoresSafeArea()
    }

    private var hud: some View {
        VStack {
            HStack(alignment: .center) {
                GlyphButton(symbol: "chevron.left") { _ in
                    pager.leave()
                    onExit()
                }
                Spacer()
                PetalPurse(petals: inventory.petals)
                    .padding(.trailing, 6)
            }
            .padding(.horizontal, 18)
            Spacer()
        }
    }
}

/// A word pressed on a stone: the label face on a rounded grey slab with
/// a little shade under it, dimmed when it cannot be pressed.
private struct StoneButton: View {
    let label: String
    var on = true
    let press: () -> Void

    var body: some View {
        Button(action: press) {
            Text(label)
                .font(Ink.label(Size.row))
                .tracking(0.15)
                .foregroundStyle(Ink.paper)
                .padding(.horizontal, 30)
                .frame(height: 56)
                .background(
                    Capsule()
                        .fill(Color(red: 0.50, green: 0.53, blue: 0.52))
                        .shadow(color: Ink.veil.opacity(0.55), radius: 6, y: 3)
                )
                .overlay(Capsule().stroke(Ink.paper.opacity(0.18), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!on)
        .opacity(on ? 1 : 0.45)
    }
}
