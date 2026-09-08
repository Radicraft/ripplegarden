import Foundation
import QuartzCore

/// What the pond sounds like. The water is the instrument: every gesture has
/// its own tone, and every tone sits in the season's pentatonic scale so
/// nothing the player does can sound wrong.
final class SoundDirector {

    private let synth = Synth()
    private var root: Float = 523.25
    private var holdVoices: [Int: (chord: [Int], base: Float)] = [:]
    private var currentVoices: [Int: Int] = [:]
    private var windVoice: Int?
    private var birdTimer: Timer?
    private var lastTapAt: TimeInterval = 0
    private var lastTapNote = 0

    /// Major pentatonic, two octaves.
    private let scale: [Float] = [1, 9.0 / 8, 5.0 / 4, 3.0 / 2, 5.0 / 3, 2, 9.0 / 4, 5.0 / 2, 3, 10.0 / 3]

    /// Owner's call, 2026-09-08: no sounds at all for now. Nothing below runs
    /// while this is on, and the audio engine is never started.
    static let killSwitch = true

    private var enabled: Bool { !SoundDirector.killSwitch && Settings.shared.soundOn }

    // MARK: - Ambience

    func startAmbience(root: Float) {
        self.root = root
        guard enabled else { return }
        synth.start()
        if windVoice == nil {
            windVoice = synth.wash(amp: 0.045, cutoffHz: 420, attack: 4.0, lfoRate: 0.07, lfoDepth: 0.8)
        }
        scheduleBird()
    }

    func stopAmbience() {
        if let w = windVoice { synth.release(id: w, over: 2); windVoice = nil }
        birdTimer?.invalidate()
        birdTimer = nil
    }

    private func scheduleBird() {
        birdTimer?.invalidate()
        birdTimer = Timer.scheduledTimer(withTimeInterval: Double.random(in: 7...16), repeats: false) { [weak self] _ in
            self?.bird()
            self?.scheduleBird()
        }
    }

    /// Two or three quick rising chirps, far away.
    private func bird() {
        guard enabled else { return }
        let base = Float.random(in: 2400...3600)
        let n = Int.random(in: 2...3)
        for i in 0..<n {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.19) { [synth] in
                synth.sweep(from: base * 0.85, to: base * Float.random(in: 1.05...1.25),
                            amp: 0.035, decay: 0.16, glide: 0.07)
            }
        }
    }

    // MARK: - Gestures

    /// Where the finger lands picks the note: left is low, right is high.
    func tap(x: Float, weight: Float) {
        guard enabled else { return }
        synth.start()
        let idx = max(0, min(scale.count - 3, Int(x * Float(scale.count - 2))))
        let now = CACurrentMediaTime()
        // Quick repeated taps walk up the scale rather than repeating.
        let note = (now - lastTapAt < 0.5 && idx == lastTapNote) ? min(scale.count - 1, idx + 1) : idx
        lastTapAt = now
        lastTapNote = idx
        let freq = root * scale[note] * (weight > 0.6 ? 0.5 : 1)
        synth.pluck(freq: freq, amp: 0.30 + 0.15 * weight, decay: 0.55,
                    partials: [(1, 1), (2.01, 0.28), (3.0, 0.10), (4.2, 0.04)])
        synth.burst(amp: 0.06, cutoffHz: 1800, decay: 0.05)
    }

    /// A held finger opens a chord that swells with the charge.
    func holdBegin(id: Int) {
        guard enabled else { return }
        let base = root * 0.5
        let chord = [
            synth.sustain(freq: base, amp: 0.0, attack: 0.6, partials: [(1, 1), (2, 0.2)]),
            synth.sustain(freq: base * 1.5, amp: 0.0, attack: 0.8, partials: [(1, 0.8), (2, 0.15)]),
            synth.sustain(freq: base * 2, amp: 0.0, attack: 1.0, partials: [(1, 0.6), (3, 0.05)]),
        ]
        holdVoices[id] = (chord, base)
    }

    func holdLevel(id: Int, charge: Float) {
        guard let h = holdVoices[id] else { return }
        let level = 0.05 + 0.18 * charge
        for (i, v) in h.chord.enumerated() {
            synth.set(id: v, targetAmp: level * (1 - Float(i) * 0.2))
        }
    }

    /// The finger lifted before or after a charge; the chord fades.
    func holdEnd(id: Int) {
        guard let h = holdVoices.removeValue(forKey: id) else { return }
        for v in h.chord { synth.release(id: v, over: 0.5) }
    }

    /// A charged release: a bell whose size matches the swell.
    func holdRelease(charge: Float) {
        guard enabled else { return }
        let freq = root * (charge > 0.6 ? 0.5 : 1)
        let bell: [(ratio: Float, gain: Float)] = [(1, 1), (2.0, 0.5), (2.76, 0.28), (4.1, 0.14), (5.4, 0.06)]
        synth.pluck(freq: freq, amp: 0.22 + 0.28 * charge, decay: 1.6 + 1.6 * charge, partials: bell, attack: 0.01)
        synth.pluck(freq: freq * 1.5, amp: 0.10 * charge, decay: 1.4, partials: bell, attack: 0.02)
    }

    /// Two fingers sweeping: a broad low wash.
    func swell() {
        guard enabled else { return }
        synth.burst(amp: 0.22, cutoffHz: 380, decay: 0.9)
        synth.pluck(freq: root * 0.25, amp: 0.16, decay: 1.2, partials: [(1, 1), (1.5, 0.3)], attack: 0.08)
    }

    /// A stroke along the bank: a thin sustained hiss that follows the hand.
    func currentBegin(id: Int) {
        guard enabled else { return }
        currentVoices[id] = synth.wash(amp: 0.02, cutoffHz: 900, attack: 0.4)
    }

    func currentLevel(id: Int, strength: Float) {
        guard let v = currentVoices[id] else { return }
        synth.set(id: v, targetAmp: 0.02 + 0.06 * strength)
    }

    func currentEnd(id: Int) {
        guard let v = currentVoices.removeValue(forKey: id) else { return }
        synth.release(id: v, over: 1.2)
    }

    // MARK: - Events

    /// Each cleared piece climbs the scale; the last one lands on the octave.
    func clearNote(index: Int, of total: Int) {
        guard enabled else { return }
        let step = min(scale.count - 1, Int(Float(index) / Float(max(1, total)) * 6))
        let freq = root * 2 * scale[step]
        synth.pluck(freq: freq, amp: 0.20, decay: 1.1,
                    partials: [(1, 1), (2, 0.2), (3, 0.05)], attack: 0.006)
        synth.pluck(freq: freq * 2, amp: 0.05, decay: 0.7, attack: 0.006)
    }

    /// The koi dives.
    func plop() {
        guard enabled else { return }
        synth.sweep(from: root * 0.6, to: root * 0.28, amp: 0.25, decay: 0.16, glide: 0.09)
        synth.burst(amp: 0.08, cutoffHz: 1200, decay: 0.08)
    }

    /// The pond is clear: a slow rising arpeggio with a long tail.
    func complete() {
        guard enabled else { return }
        let bell: [(ratio: Float, gain: Float)] = [(1, 1), (2.0, 0.4), (2.76, 0.22), (4.1, 0.1)]
        let notes: [Float] = [1, 5.0 / 4, 3.0 / 2, 2, 5.0 / 2]
        for (i, n) in notes.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.22) { [synth, root] in
                synth.pluck(freq: root * n, amp: 0.22, decay: 3.2, partials: bell, attack: 0.015)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [synth] in
            synth.burst(amp: 0.05, cutoffHz: 2400, decay: 1.8)
        }
    }
}
