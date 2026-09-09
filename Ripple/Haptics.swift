import CoreHaptics
import QuartzCore
import UIKit

/// Each gesture feels different in the hand as well as sounding different.
/// Core Haptics where the hardware has it, UIKit feedback where it does not,
/// nothing at all where the player has turned it off.
final class Haptics {

    private var engine: CHHapticEngine?
    private var holdPlayer: CHHapticAdvancedPatternPlayer?
    private var slidePlayer: CHHapticAdvancedPatternPlayer?
    private var slideStarted: TimeInterval = 0
    private var slideTravel: Float = 0
    private var lastCrunch: TimeInterval = 0
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    /// How long one slide pattern lasts before it has to be laid down again.
    private static let slideSeconds: TimeInterval = 30
    /// The sharpness baked into the slide event. Dynamic sharpness is an offset from it.
    private static let slideBaseSharpness: Float = 0.3

    private var enabled: Bool { Settings.shared.hapticsOn }

    init() {
        guard supported else { return }
        do {
            let e = try CHHapticEngine()
            e.playsHapticsOnly = true
            e.resetHandler = { [weak self] in
                guard let self else { return }
                // The reset kills every player. Forget the slide one so the next
                // slide lays down a fresh pattern instead of talking to a corpse.
                self.slidePlayer = nil
                try? self.engine?.start()
            }
            try e.start()
            engine = e
        } catch {
            engine = nil
        }
        light.prepare()
        soft.prepare()
        medium.prepare()
        rigid.prepare()
        heavy.prepare()
    }

    private func play(_ events: [CHHapticEvent]) {
        play(events, curves: [])
    }

    private func play(_ events: [CHHapticEvent], curves: [CHHapticParameterCurve]) {
        guard enabled else { return }
        guard let engine else { return }
        do {
            let pattern = try CHHapticPattern(events: events, parameterCurves: curves)
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // A missed haptic is not worth a log line.
        }
    }

    private func transient(_ intensity: Float, _ sharpness: Float, at t: TimeInterval = 0) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticTransient,
                      parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                                   CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)],
                      relativeTime: t)
    }

    /// A single light tick, a touch heavier for a fatter finger.
    func tap(weight: Float) {
        guard enabled else { return }
        if engine != nil {
            play([transient(0.35 + 0.35 * weight, 0.55)])
        } else {
            soft.impactOccurred(intensity: CGFloat(0.45 + 0.55 * weight))
            soft.prepare()
        }
    }

    /// A rumble that builds for as long as the finger stays.
    func holdBegin() {
        guard enabled, let engine else { return }
        let dur = TimeInterval(Tuning.holdChargeSeconds) + 0.4
        let event = CHHapticEvent(eventType: .hapticContinuous,
                                  parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.2),
                                               CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.15)],
                                  relativeTime: 0, duration: dur)
        let curve = CHHapticParameterCurve(parameterID: .hapticIntensityControl,
                                           controlPoints: [.init(relativeTime: 0, value: 0.15),
                                                           .init(relativeTime: dur * 0.7, value: 0.9),
                                                           .init(relativeTime: dur, value: 1.0)],
                                           relativeTime: 0)
        do {
            let pattern = try CHHapticPattern(events: [event], parameterCurves: [curve])
            let player = try engine.makeAdvancedPlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            holdPlayer = player
        } catch {
            holdPlayer = nil
        }
    }

    /// The swell leaves the finger: one round thump, sized by the charge.
    func holdRelease(charge: Float) {
        guard enabled else { return }
        try? holdPlayer?.stop(atTime: CHHapticTimeImmediate)
        holdPlayer = nil
        if engine != nil {
            play([transient(0.5 + 0.5 * charge, 0.2), transient(0.3 * charge, 0.1, at: 0.09)])
        } else {
            medium.impactOccurred(intensity: CGFloat(0.4 + 0.6 * charge))
            medium.prepare()
        }
    }

    /// Two fingers sweeping: a broad rolling pulse.
    func swell() {
        guard enabled else { return }
        if engine != nil {
            play([transient(0.6, 0.15), transient(0.5, 0.1, at: 0.07), transient(0.35, 0.05, at: 0.15),
                  CHHapticEvent(eventType: .hapticContinuous,
                                parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.3),
                                             CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.05)],
                                relativeTime: 0.05, duration: 0.3)])
        } else {
            medium.impactOccurred(intensity: 0.7)
            medium.prepare()
        }
    }

    /// A stroke along the bank: faint ticks as the hand travels.
    func currentTick() {
        guard enabled else { return }
        if engine != nil { play([transient(0.18, 0.3)]) } else { soft.impactOccurred(intensity: 0.3) }
    }

    func clear() {
        guard enabled else { return }
        if engine != nil { play([transient(0.4, 0.7), transient(0.25, 0.8, at: 0.06)]) } else { light.impactOccurred() }
    }

    func plop() {
        guard enabled else { return }
        if engine != nil { play([transient(0.55, 0.25)]) } else { soft.impactOccurred(intensity: 0.7) }
    }

    func complete() {
        guard enabled else { return }
        if engine != nil {
            play([transient(0.4, 0.3), transient(0.5, 0.35, at: 0.22), transient(0.7, 0.4, at: 0.44)])
        } else {
            medium.impactOccurred()
        }
    }

    // MARK: - Ice

    /// The hammer lands on the sheet: one hard crack, then the split racing away.
    func iceStrike() {
        guard enabled else { return }
        if engine != nil {
            play([transient(0.85, 0.95),
                  transient(0.5, 0.85, at: 0.035),
                  transient(0.35, 0.8, at: 0.08),
                  transient(0.22, 0.7, at: 0.15),
                  transient(0.12, 0.6, at: 0.26)])
        } else {
            rigid.impactOccurred()
            rigid.prepare()
        }
    }

    /// A slab lets go and drops into the water. Bigger slab, heavier thud.
    /// - Parameter size: 0 to 1 by the area that broke away.
    func iceBreak(size: Float) {
        guard enabled else { return }
        stopSlidePlayer()
        let s = min(max(size, 0), 1)
        if engine != nil {
            let rumble = CHHapticEvent(eventType: .hapticContinuous,
                                       parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.35),
                                                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.1)],
                                       relativeTime: 0, duration: 0.14)
            let decay = CHHapticParameterCurve(parameterID: .hapticIntensityControl,
                                               controlPoints: [.init(relativeTime: 0, value: 1.0),
                                                               .init(relativeTime: 0.14, value: 0.0)],
                                               relativeTime: 0)
            play([transient(0.6 + 0.4 * s, 0.15), rumble, transient(0.3, 0.5, at: 0.12)], curves: [decay])
        } else {
            heavy.impactOccurred(intensity: CGFloat(0.6 + 0.4 * s))
            heavy.prepare()
        }
    }

    // MARK: - Sliding on ice

    /// The finger settles on the sheet. Silent until `slide` gives it a speed.
    func slideBegin() {
        guard enabled else { return }
        slideTravel = 0
        lastCrunch = 0
        guard engine != nil else { return }
        startSlidePlayer()
    }

    /// The finger travels. Glassy ice is faint and smooth, frost is grainy and crunches.
    /// - Parameters:
    ///   - speed: points per second.
    ///   - grain: 0 for black ice, 1 for deep frost.
    ///   - travel: points moved since the last call.
    func slide(speed: Float, grain: Float, travel: Float) {
        guard enabled else { return }
        let g = min(max(grain, 0), 1)
        let now = CACurrentMediaTime()

        if engine != nil {
            // One pattern only lasts so long. Lay the next one down before this one runs out.
            if slidePlayer == nil || now - slideStarted > Haptics.slideSeconds - 1 {
                startSlidePlayer()
            }
            let intensity = min(max(speed / 700, 0), 1) * (0.18 + 0.42 * g)
            let sharpness = 0.12 + (0.6 - 0.12) * g
            let offset = min(max(sharpness - Haptics.slideBaseSharpness, -1), 1)
            try? slidePlayer?.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                                                      value: intensity, relativeTime: 0),
                                              CHHapticDynamicParameter(parameterID: .hapticSharpnessControl,
                                                                       value: offset, relativeTime: 0)],
                                             atTime: CHHapticTimeImmediate)
        }

        guard g > 0.4 else { slideTravel = 0; return }
        slideTravel += max(travel, 0)
        let step: Float = engine != nil ? 22 : 30
        guard slideTravel >= step else { return }
        guard now - lastCrunch >= 0.016 else { return }
        slideTravel = 0
        lastCrunch = now
        if engine != nil {
            play([transient(0.1 + 0.1 * g, 0.5)])
        } else {
            soft.impactOccurred(intensity: CGFloat(0.2 + 0.3 * g))
            soft.prepare()
        }
    }

    /// The finger crosses a crack: one click, harder across a wider split.
    func slideCrack(strength: Float) {
        guard enabled else { return }
        let s = min(max(strength, 0), 1)
        if engine != nil {
            play([transient(0.3 + 0.45 * s, 0.9)])
        } else {
            rigid.impactOccurred(intensity: CGFloat(0.4 + 0.6 * s))
            rigid.prepare()
        }
    }

    /// The finger leaves the ice.
    func slideEnd() {
        stopSlidePlayer()
        slideTravel = 0
        lastCrunch = 0
    }

    private func startSlidePlayer() {
        guard let engine else { return }
        // The event carries full intensity and the dynamic parameter scales it,
        // so it starts silent and only speaks once `slide` sends a speed.
        let event = CHHapticEvent(eventType: .hapticContinuous,
                                  parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                                               CHHapticEventParameter(parameterID: .hapticSharpness,
                                                                      value: Haptics.slideBaseSharpness)],
                                  relativeTime: 0, duration: Haptics.slideSeconds)
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makeAdvancedPlayer(with: pattern)
            try player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                                                value: 0, relativeTime: 0)],
                                      atTime: CHHapticTimeImmediate)
            try player.start(atTime: CHHapticTimeImmediate)
            let old = slidePlayer
            slidePlayer = player
            slideStarted = CACurrentMediaTime()
            // Stop the outgoing one after the new one is running so the seam is not felt.
            try? old?.stop(atTime: CHHapticTimeImmediate)
        } catch {
            slidePlayer = nil
        }
    }

    private func stopSlidePlayer() {
        try? slidePlayer?.stop(atTime: CHHapticTimeImmediate)
        slidePlayer = nil
    }
}
