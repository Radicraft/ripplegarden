import CoreHaptics
import UIKit

/// Each gesture feels different in the hand as well as sounding different.
/// Core Haptics where the hardware has it, UIKit feedback where it does not,
/// nothing at all where the player has turned it off.
final class Haptics {

    private var engine: CHHapticEngine?
    private var holdPlayer: CHHapticAdvancedPatternPlayer?
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    private var enabled: Bool { Settings.shared.hapticsOn }

    init() {
        guard supported else { return }
        do {
            let e = try CHHapticEngine()
            e.playsHapticsOnly = true
            e.resetHandler = { [weak self] in try? self?.engine?.start() }
            try e.start()
            engine = e
        } catch {
            engine = nil
        }
        light.prepare()
        soft.prepare()
        medium.prepare()
    }

    private func play(_ events: [CHHapticEvent]) {
        guard enabled else { return }
        guard let engine else { return }
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
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
}
