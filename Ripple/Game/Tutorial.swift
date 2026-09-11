import CoreGraphics
import Foundation
import QuartzCore
import SwiftUI

/// The first walk through the game, done rather than read. One line at a
/// time, low in the water where the level's own words go, changing the
/// moment the player does the thing it asked for. Nothing is modal and
/// nothing is skipped past: the line waits, and after six seconds a soft
/// ring of light breathes where the finger should go. Once the walk has
/// reached the player's own pond and back it is over for good.
///
/// The controllers tell it what happened with `note(_:)` and read what to
/// show with `lines` and `spot(for:)`. They never decide the words.
///
/// `-tutorial` runs it whatever the store says; `-noTutorial` skips it.
@MainActor
final class Tutorial: ObservableObject {

    static let shared = Tutorial()

    /// Where the player is, as far as the walk cares.
    enum Screen: Hashable {
        case map, level, plot
    }

    /// The steps in the order they are walked.
    enum Step: Int, Comparable {
        /// On the map: tap the first pool.
        case tapPool
        /// In the frozen pond: tap the ice, break inside the cracks, slide.
        case crackIce, breakThrough, slideIce
        /// Open the rest; the level ends when it ends.
        case breakRest
        /// The completion is up: what was won is theirs.
        case won
        /// Find the plot, by the completion's word or a swipe on the map.
        case findPond
        /// In the plot: dig, open the sluice, wait for water, place, go back.
        case dig, sluice, fill, tray, back
        case done

        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    /// What the controllers report.
    enum Event {
        case dived(levelID: String)
        case levelOpened(id: String, frozen: Bool)
        case iceStruck(at: CGPoint)
        case iceBroke
        /// A slide's step in screen points; the walk adds them up.
        case iceSlid(CGFloat)
        case levelFinished
        case completionShown
        case plotOpened
        /// A dig stroke's step in world points; the walk adds them up.
        case dug(CGFloat)
        case sluiceOpened
        case water(Float)
        case itemPlaced
        case plotLeft
    }

    /// Where the ring of light should breathe. The controller that owns the
    /// screen turns it into a point.
    enum Spot: Equatable {
        case firstPool
        /// Somewhere on the sheet; the level picks the middle of what is left.
        case iceCentre
        /// Inside the ring of cracks the last strike opened.
        case iceAt(CGPoint)
        case yourPond
        case earth
        case sluice
        case trayStone
        case chevron
    }

    @Published private(set) var step: Step
    /// The line for each screen right now, if the step has one there.
    @Published private(set) var lines: [Screen: PondWords] = [:]
    /// The step has waited long enough for the ring to show.
    @Published private(set) var pulsing = false

    var running: Bool { step != .done }

    private static let firstLevel = "winter-1"
    private static let pulseAfter: Double = 6
    private static let slideWait: Double = 10
    private static let wonPause: Double = 3.5
    private static let breakRestLine: Double = 10

    private let forced = ProcessInfo.processInfo.arguments.contains("-tutorial")
    private var enteredAt = CACurrentMediaTime()
    private var levelID: String?
    private var levelFrozen = false
    private var levelOpenedAt = CACurrentMediaTime()
    private var completionUp = false
    private var completionAt: TimeInterval?
    private var lastStrike: CGPoint?
    private var slid: CGFloat = 0
    private var dugTravel: CGFloat = 0
    private var water: Float = 0
    private var timer: Timer?
    private let ringTexture: String? = Bundle.main.url(forResource: "ring_light", withExtension: "png") != nil ? "ring_light" : nil

    private init() {
        let args = ProcessInfo.processInfo.arguments
        let store = ProgressStore.shared
        // The walk runs once on every fresh install, whatever progress has
        // come back from iCloud: the owner wants every first start to begin
        // with it.
        let skip = args.contains("-noTutorial") || (store.tutorialDone && !forced)
        step = skip ? .done : .tapPool
        if !skip { start() }
    }

    private func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: - What happened

    func note(_ event: Event) {
        guard running else { return }
        switch event {
        case .dived(let id):
            if step == .tapPool, id == Tutorial.firstLevel { advance(to: .crackIce) }
        case .levelOpened(let id, let frozen):
            levelID = id
            levelFrozen = frozen
            levelOpenedAt = CACurrentMediaTime()
            completionUp = false
            completionAt = nil
            if step == .tapPool, id == Tutorial.firstLevel { advance(to: .crackIce) }
        case .iceStruck(let at):
            lastStrike = at
            if step == .crackIce { advance(to: .breakThrough) }
        case .iceBroke:
            if step == .crackIce || step == .breakThrough { advance(to: .slideIce) }
        case .iceSlid(let d):
            guard step == .slideIce else { return }
            slid += d
            if slid > 60 { advance(to: .breakRest) }
        case .levelFinished:
            if step < .won { advance(to: .won) }
        case .completionShown:
            completionUp = true
            completionAt = CACurrentMediaTime()
        case .plotOpened:
            completionUp = false
            if step == .won || step == .findPond { advance(to: .dig) }
        case .dug(let d):
            guard step == .dig else { return }
            dugTravel += d
            if dugTravel > 80 { advance(to: .sluice) }
        case .sluiceOpened:
            if step == .sluice { advance(to: .fill) }
        case .water(let w):
            water = w
            if step == .fill, w > 0.25 { advance(to: .tray) }
        case .itemPlaced:
            if step == .tray { advance(to: .back) }
        case .plotLeft:
            if step == .back { advance(to: .done) }
        }
        refresh()
    }

    private func advance(to next: Step) {
        step = next
        enteredAt = CACurrentMediaTime()
        pulsing = false
        // The ice hint says what the walk has just said, so once the sheet
        // has been worked it is marked as seen and stays away.
        if next >= .breakRest { HintMemory.markSeen(.ice) }
        if next == .done { finish() }
    }

    /// Over, and never again.
    private func finish() {
        timer?.invalidate()
        timer = nil
        ProgressStore.shared.tutorialDone = true
        lines = [:]
        pulsing = false
    }

    /// The clock: the slide that was never made, the pause after the win,
    /// and the ring once a step has waited.
    private func tick() {
        guard running else { return }
        let now = CACurrentMediaTime()
        if step == .slideIce, now - enteredAt > Tutorial.slideWait { advance(to: .breakRest) }
        if step == .won, let at = completionAt, now - at > Tutorial.wonPause { advance(to: .findPond) }
        let due = now - enteredAt > Tutorial.pulseAfter
        if due != pulsing { pulsing = due }
        refresh()
    }

    // MARK: - What to show

    private func refresh() {
        var next: [Screen: PondWords] = [:]
        if let m = mapLine() { next[.map] = PondWords(title: nil, line: m) }
        if let l = levelLine() { next[.level] = PondWords(title: nil, line: l) }
        if let p = plotLine() { next[.plot] = PondWords(title: nil, line: p) }
        if next != lines { lines = next }
    }

    private func mapLine() -> String? {
        switch step {
        case .tapPool:
            return "This is the stream. Every pool along it is a pond to wake. Tap the first one."
        case .crackIce, .breakThrough, .slideIce, .breakRest:
            return "The first pond is still under its ice. Tap it to go back in."
        case .won, .findPond, .dig, .sluice, .fill, .tray, .back:
            return "Your pond is over the bank. Swipe left to find it."
        case .done:
            return nil
        }
    }

    private func levelLine() -> String? {
        let now = CACurrentMediaTime()
        switch step {
        case .crackIce:
            return levelFrozen ? "The pond is asleep under the ice. Tap the ice to crack it." : nil
        case .breakThrough:
            return levelFrozen ? "Tap inside the cracks to break through." : nil
        case .slideIce:
            return levelFrozen ? "Slide a finger across the ice: feel it." : nil
        case .breakRest:
            // Said for a while, and again if the level is opened afresh.
            guard levelFrozen, now - max(enteredAt, levelOpenedAt) < Tutorial.breakRestLine else { return nil }
            return "Break the rest. Every pond you wake sends something home to your own pond."
        case .won:
            return completionUp ? "You won that. It is yours to keep." : nil
        case .findPond:
            return completionUp ? "Now find your pond: tap Your pond, or swipe left on the map." : nil
        case .tapPool, .dig, .sluice, .fill, .tray, .back, .done:
            return nil
        }
    }

    private func plotLine() -> String? {
        switch step {
        case .dig:
            return "This is your patch of the bank. Drag a finger on the earth to dig a pond."
        case .sluice:
            return "Tap the stone at the water's edge to let the stream in."
        case .fill:
            return "The stream is filling it. Hold the stone to hurry it along."
        case .tray:
            return "Tap the tray stone and drag out what you won."
        case .back:
            return "Flowers shed petals to pick up; petals buy more plots. Every level you finish brings something new. Tap the chevron to go back to the stream."
        case .tapPool, .crackIce, .breakThrough, .slideIce, .breakRest, .won, .findPond, .done:
            return nil
        }
    }

    /// Where the ring should breathe on this screen, once the step has
    /// waited long enough. Nil means no ring.
    func spot(for screen: Screen) -> Spot? {
        guard running, pulsing else { return nil }
        switch (screen, step) {
        case (.map, .tapPool), (.map, .crackIce), (.map, .breakThrough), (.map, .slideIce), (.map, .breakRest):
            return .firstPool
        case (.level, .crackIce):
            return levelFrozen ? .iceCentre : nil
        case (.level, .breakThrough):
            return levelFrozen ? lastStrike.map { .iceAt($0) } ?? .iceCentre : nil
        case (.level, .findPond):
            return completionUp ? .yourPond : nil
        case (.plot, .dig):
            return .earth
        case (.plot, .sluice), (.plot, .fill):
            return .sluice
        case (.plot, .tray):
            return .trayStone
        case (.plot, .back):
            return .chevron
        default:
            return nil
        }
    }

    /// The ring of light on the water at a point: the reveal's ring, small
    /// and white, breathing. A soft glow with a circle of motes stands in
    /// if the painting is missing.
    func ring(at p: CGPoint, time: Float) -> [Sprite] {
        let breathe = CGFloat(1 + 0.1 * sin(time * 2.1))
        let r: CGFloat = 36 * breathe
        let alpha: Float = 0.5 + 0.28 * sin(time * 2.1)
        let white: SIMD4<Float> = [1, 1, 1, 1]
        if let ring = ringTexture {
            return [Sprite(ring, at: p, size: CGSize(width: r * 2, height: r * 2), rotation: time * 0.3,
                           mode: .floater, alpha: alpha, tint: white, z: 0.3)]
        }
        var out = [Sprite("mote", at: p, size: CGSize(width: r * 2.4, height: r * 2.1),
                          mode: .floater, alpha: 0.2 * alpha, tint: white, z: 0.3)]
        let n = 14
        for k in 0..<n {
            let a = CGFloat(k) / CGFloat(n) * 2 * .pi + CGFloat(time) * 0.4
            let at = CGPoint(x: p.x + cos(a) * r, y: p.y + sin(a) * r * 0.85)
            out.append(Sprite("mote", at: at, size: CGSize(width: 18, height: 18),
                              mode: .floater, alpha: alpha, tint: white, z: 0.3))
        }
        return out
    }
}

/// The same ring over the interface, for the two spots that are words
/// rather than water: the completion's "Your pond" and the plot's chevron.
struct TutorialPulse: View {
    var on: Bool
    var diameter: CGFloat = 72
    @State private var big = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Ink.paper.opacity(0.3), lineWidth: 10)
                .blur(radius: 7)
            Circle()
                .stroke(Ink.paper.opacity(0.9), lineWidth: 1.5)
                .blur(radius: 0.8)
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(big ? 1.1 : 0.9)
        .opacity(on ? (big ? 0.4 : 0.9) : 0)
        .animation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true), value: big)
        .animation(Motion.words, value: on)
        .onAppear { big = true }
        .allowsHitTesting(false)
    }
}
