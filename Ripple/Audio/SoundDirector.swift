import AVFoundation
import Foundation
import QuartzCore

/// What the pond sounds like. Everything is a recording: the season's air
/// as layered ambience underneath, and a sampled sound for every touch and
/// event on the water, each one varied a little in pitch and panned to
/// where it happened, so nothing repeats exactly. The owner's rule: natural
/// backgrounds like a calm-app soundscape, never synthesised.
final class SoundDirector {

    struct Entry: Decodable {
        let name: String
        let file: String
        let kind: String
        var gain: Float = 1
        var loop: Bool = false
        var pitchVariation: Float = 0
    }

    private let engine = AVAudioEngine()
    private let ambienceMix = AVAudioMixerNode()
    private let effectMix = AVAudioMixerNode()
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var entries: [String: Entry] = [:]
    private var started = false
    private var loaded = false

    /// Two ambience layers so one can fade into the next.
    private final class Layer {
        let player = AVAudioPlayerNode()
        var name = ""
        var target: Float = 0
    }
    private var layers = [Layer(), Layer()]
    private var front = 0

    /// A small pool of one-shot voices, each with its own varispeed for pitch.
    private final class Voice {
        let player = AVAudioPlayerNode()
        let speed = AVAudioUnitVarispeed()
        var busyUntil: TimeInterval = 0
    }
    private var voices: [Voice] = (0..<10).map { _ in Voice() }
    /// Held sounds (a swell building, a current running) keyed by touch.
    private var held: [Int: Voice] = [:]
    private var duck: Float = 1
    private var fadeTimer: Timer?

    private var enabled: Bool { Settings.shared.soundOn }

    // MARK: - Setup

    private func setUp() {
        guard !started else { return }
        started = true
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {}
        engine.attach(ambienceMix)
        engine.attach(effectMix)
        engine.connect(ambienceMix, to: engine.mainMixerNode, format: nil)
        engine.connect(effectMix, to: engine.mainMixerNode, format: nil)
        for l in layers {
            engine.attach(l.player)
            engine.connect(l.player, to: ambienceMix, format: nil)
            l.player.volume = 0
        }
        for v in voices {
            engine.attach(v.player)
            engine.attach(v.speed)
            engine.connect(v.player, to: v.speed, format: nil)
            engine.connect(v.speed, to: effectMix, format: nil)
        }
        loadManifest()
        try? engine.start()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func loadManifest() {
        guard !loaded else { return }
        loaded = true
        let url = Bundle.main.url(forResource: "manifest", withExtension: "json")
            ?? Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "Sounds")
        guard let url, let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        for e in list { entries[e.name] = e }
    }

    private func buffer(_ name: String) -> AVAudioPCMBuffer? {
        if let b = buffers[name] { return b }
        guard let e = entries[name] else { return nil }
        let base = (e.file as NSString).deletingPathExtension
        let ext = (e.file as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: base, withExtension: ext)
                ?? Bundle.main.url(forResource: base, withExtension: ext, subdirectory: "Sounds"),
              let file = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        try? file.read(into: buf)
        buffers[name] = buf
        return buf
    }

    /// Volumes ease toward their targets: ambience crossfades, holds swell.
    private func tick() {
        for l in layers {
            let want = l.target * duck
            l.player.volume += (want - l.player.volume) * 0.08
            if l.target == 0, l.player.volume < 0.005, l.player.isPlaying { l.player.stop() }
        }
    }

    // MARK: - Ambience

    /// The air of a season, or the stream on the map: one loop fading into
    /// the last, with the same file left alone.
    func startAmbience(named name: String) {
        guard enabled else { return }
        setUp()
        guard layers[front].name != name else { return }
        guard let buf = buffer(name), let e = entries[name] else { return }
        layers[front].target = 0
        front = 1 - front
        let l = layers[front]
        l.name = name
        l.player.stop()
        l.player.scheduleBuffer(buf, at: nil, options: [.loops])
        l.player.volume = 0
        l.target = e.gain
        l.player.play()
    }

    func startAmbience(root: Float) {
        // Kept for older call sites: the season decides.
        startAmbience(named: "amb_spring")
    }

    func stopAmbience() {
        for l in layers { l.target = 0; l.name = "" }
    }

    /// Cards on the water push the air back a little.
    func duck(_ on: Bool) { duck = on ? 0.55 : 1 }

    // MARK: - Effects

    /// One sound, once. `x` is 0...1 across the pond for the pan; `pitch` is
    /// a multiplier on top of the file's own variation; nil leaves it be.
    @discardableResult
    private func play(_ name: String, x: Float? = nil, gain: Float = 1, pitch: Float = 1, loop: Bool = false) -> Voice? {
        guard enabled else { return nil }
        setUp()
        guard let buf = buffer(name), let e = entries[name] else { return nil }
        let now = CACurrentMediaTime()
        guard let v = voices.first(where: { $0.busyUntil <= now && held.values.contains { $0 === $0 } == false || $0.busyUntil <= now })
                ?? voices.min(by: { $0.busyUntil < $1.busyUntil }) else { return nil }
        if held.values.contains(where: { $0 === v }) { return nil }
        v.player.stop()
        let vary = 1 + Float.random(in: -e.pitchVariation...e.pitchVariation)
        v.speed.rate = max(0.5, min(2, pitch * vary))
        v.player.volume = e.gain * gain
        v.player.pan = x.map { max(-0.7, min(0.7, ($0 - 0.5) * 1.4)) } ?? 0
        v.player.scheduleBuffer(buf, at: nil, options: loop ? [.loops] : [])
        v.player.play()
        let seconds = Double(buf.frameLength) / buf.format.sampleRate / Double(v.speed.rate)
        v.busyUntil = loop ? .greatestFiniteMagnitude : now + seconds
        return v
    }

    private func pick(_ base: String, _ n: Int) -> String {
        let k = Int.random(in: 1...n)
        return entries["\(base)_\(k)"] != nil ? "\(base)_\(k)" : base
    }

    /// A drop of water: heavier fingers make a deeper plop.
    func tap(x: Float, weight: Float) {
        play(pick("fx_drop", 3), x: x, gain: 0.7 + 0.3 * weight, pitch: 1.15 - 0.35 * weight)
    }

    /// A swell building under a still finger: rushing water rising with the charge.
    func holdBegin(id: Int) {
        guard let v = play("amb_stream", gain: 0.0, pitch: 0.7, loop: true) else { return }
        held[id] = v
    }

    func holdLevel(id: Int, charge: Float) {
        guard let v = held[id] else { return }
        v.player.volume += ((0.05 + 0.5 * charge) - v.player.volume) * 0.15
    }

    func holdEnd(id: Int) {
        guard let v = held.removeValue(forKey: id) else { return }
        v.player.stop()
        v.busyUntil = 0
    }

    /// The swell leaves the finger: a splash sized by the charge.
    func holdRelease(charge: Float) {
        if charge > 0.55 { play("fx_splash_big", gain: 0.5 + 0.5 * charge, pitch: 1.1 - 0.25 * charge) }
        else { play(pick("fx_splash_small", 3), gain: 0.6 + 0.4 * charge) }
    }

    /// Two fingers sweeping: a broad wash.
    func swell() {
        play("fx_splash_big", gain: 0.55, pitch: 0.85)
    }

    /// A stroke along the bank: water running, louder as the current builds.
    func currentBegin(id: Int) {
        guard let v = play("amb_stream", gain: 0.0, pitch: 1.15, loop: true) else { return }
        held[id] = v
    }

    func currentLevel(id: Int, strength: Float) {
        guard let v = held[id] else { return }
        v.player.volume += ((0.04 + 0.3 * strength) - v.player.volume) * 0.2
    }

    func currentEnd(id: Int) { holdEnd(id: id) }

    /// A piece reaches the bank: a pebble tick that climbs as the pond clears.
    func clearNote(index: Int, of total: Int) {
        let t = Float(index) / Float(max(1, total))
        play("fx_pebbles", gain: 0.5, pitch: 0.9 + 0.35 * t)
    }

    func plop() { play(pick("fx_splash_small", 3), gain: 0.7) }

    func complete() {
        play("fx_chime_complete", gain: 0.9)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.play("fx_bird_flutter", gain: 0.5) }
    }

    // MARK: - Things on the water

    func iceCrack(x: Float) { play(pick("fx_ice_crack", 3), x: x, gain: 0.9) }

    func iceBreak(x: Float, size: Float) {
        play(pick("fx_ice_break", 2), x: x, gain: 0.6 + 0.4 * size, pitch: 1.1 - 0.3 * size)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.play(self?.pick("fx_splash_small", 3) ?? "fx_splash_small", x: x, gain: 0.5)
        }
    }

    func iceSlide(x: Float, speed: Float) {
        // A slide over frost is a faint rustle; the reed rustle at a low rate does it.
        guard speed > 120 else { return }
        play("fx_reeds", x: x, gain: min(0.35, speed / 2000), pitch: 0.8)
    }

    func can(x: Float) { play(pick("fx_can", 2), x: x, gain: 0.8) }
    func bottle(x: Float) { play("fx_bottle", x: x, gain: 0.8) }
    func wood(x: Float) { play("fx_wood_knock", x: x, gain: 0.7) }
    func bell(x: Float) { play("fx_bell", x: x, gain: 0.9) }
    func bud(x: Float) { play("fx_bird_flutter", x: x, gain: 0.45, pitch: 1.2) }
    func frog(x: Float) { play("fx_frog_jump", x: x, gain: 0.7) }
    func reeds(x: Float) { play("fx_reeds", x: x, gain: 0.5) }
    /// The camera drops into a pool on the map.
    func dive() { play("fx_splash_big", gain: 0.9, pitch: 0.9) }
    /// A card lands on the water.
    func paper() { play("fx_paper", gain: 0.6) }
}
