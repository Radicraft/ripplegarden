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
    /// Every buffer is converted to this on load, and every node is
    /// connected with it once, so no player ever meets a format it was not
    /// wired for (which raises, and took the app down with it).
    private let canonical = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    private let ambienceMix = AVAudioMixerNode()
    private let effectMix = AVAudioMixerNode()
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var entries: [String: Entry] = [:]
    private var started = false
    private var loaded = false

    /// Ambience layers: a season's air fading into the next, and on the map
    /// the brook under whichever seasons the camera is between, so several
    /// can sound at once at their own levels.
    private final class Layer {
        let player = AVAudioPlayerNode()
        var name = ""
        var target: Float = 0
    }
    private var layers = (0..<5).map { _ in Layer() }

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
    /// A gust lifts the air above 1 for a moment; it eases back on its own.
    private var airLift: Float = 1
    private var airLiftUntil: TimeInterval = 0
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
        engine.connect(ambienceMix, to: engine.mainMixerNode, format: canonical)
        engine.connect(effectMix, to: engine.mainMixerNode, format: canonical)
        for l in layers {
            engine.attach(l.player)
            engine.connect(l.player, to: ambienceMix, format: canonical)
            l.player.volume = 0
        }
        for v in voices {
            engine.attach(v.player)
            engine.attach(v.speed)
            engine.connect(v.player, to: v.speed, format: canonical)
            engine.connect(v.speed, to: effectMix, format: canonical)
        }
        loadManifest()
        try? engine.start()
        // The timer outlives the director unless it is told to stop, and a
        // level left behind would leave one ticking for the rest of the run.
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.tick()
        }
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

    private func running() -> Bool {
        if !engine.isRunning { try? engine.start() }
        return engine.isRunning
    }

    private func buffer(_ name: String) -> AVAudioPCMBuffer? {
        if let b = buffers[name] { return b }
        guard let e = entries[name] else { return nil }
        let base = (e.file as NSString).deletingPathExtension
        let ext = (e.file as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: base, withExtension: ext)
                ?? Bundle.main.url(forResource: base, withExtension: ext, subdirectory: "Sounds"),
              let file = try? AVAudioFile(forReading: url),
              let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        do { try file.read(into: raw) } catch { return nil }
        let buf: AVAudioPCMBuffer
        if raw.format.sampleRate == canonical.sampleRate && raw.format.channelCount == canonical.channelCount
            && raw.format.commonFormat == canonical.commonFormat && raw.format.isInterleaved == canonical.isInterleaved {
            buf = raw
        } else {
            // Mono, or another rate: convert once, here, to the canonical format.
            guard let converter = AVAudioConverter(from: raw.format, to: canonical) else { return nil }
            let frames = AVAudioFrameCount(Double(raw.frameLength) * canonical.sampleRate / raw.format.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: canonical, frameCapacity: frames) else { return nil }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true
                status.pointee = .haveData
                return raw
            }
            if error != nil || out.frameLength == 0 { return nil }
            buf = out
        }
        buffers[name] = buf
        return buf
    }

    /// Volumes ease toward their targets: ambience crossfades, holds swell.
    private func tick() {
        if CACurrentMediaTime() > airLiftUntil { airLift += (1 - airLift) * 0.08 }
        for l in layers {
            let want = l.target * duck * airLift
            l.player.volume += (want - l.player.volume) * 0.08
            if l.target == 0, l.player.volume < 0.005, l.player.isPlaying { l.player.stop(); l.name = "" }
        }
    }

    // MARK: - Ambience

    /// The air of a season, or the stream on the map: one loop fading into
    /// the last, with the same file left alone.
    func startAmbience(named name: String) {
        blendAmbience([name: 1])
    }

    /// Several airs at once, each at a share of its own gain (0...1); any
    /// layer not named fades out. The map calls this as the camera moves
    /// up the stream, so the brook stays under the season around it and one
    /// season's air gives way to the next.
    func blendAmbience(_ shares: [String: Float]) {
        guard enabled else { return }
        setUp()
        for l in layers where !l.name.isEmpty && shares[l.name] == nil { l.target = 0 }
        for (name, share) in shares {
            guard let e = entries[name] else { continue }
            if let l = layers.first(where: { $0.name == name }) {
                l.target = e.gain * share
                continue
            }
            guard share > 0.001, let buf = buffer(name) else { continue }
            // A free layer: one silent and unnamed, or the quietest one going out.
            guard let l = layers.first(where: { $0.name.isEmpty })
                    ?? layers.filter({ $0.target == 0 }).min(by: { $0.player.volume < $1.player.volume }) else { continue }
            l.name = name
            l.player.stop()
            guard running() else { return }
            l.player.scheduleBuffer(buf, at: nil, options: [.loops])
            l.player.volume = 0
            l.target = e.gain * share
            l.player.play()
        }
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
        let free = voices.filter { voice in voice.busyUntil <= now && !held.values.contains { $0 === voice } }
        guard let v = free.first ?? voices.filter({ voice in !held.values.contains { $0 === voice } }).min(by: { $0.busyUntil < $1.busyUntil }) else { return nil }
        if held.values.contains(where: { $0 === v }) { return nil }
        v.player.stop()
        guard running() else { return nil }
        // A negative variation in the manifest would be a backwards range.
        let spread = abs(e.pitchVariation)
        let vary = 1 + Float.random(in: -spread...spread)
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
    /// Six recordings between them, never the one just heard, a wide spread
    /// of pitch, and now and then a second, smaller drop just after: no two
    /// taps sound alike.
    private var lastTapName = ""
    func tap(x: Float, weight: Float) {
        var name = Bool.random() && weight < 0.7 ? pick("fx_splash_small", 3) : pick("fx_drop", 3)
        if name == lastTapName { name = name.hasPrefix("fx_drop") ? pick("fx_splash_small", 3) : pick("fx_drop", 3) }
        lastTapName = name
        let pitch = (1.2 - 0.4 * weight) * Float.random(in: 0.82...1.22)
        play(name, x: x, gain: (0.6 + 0.35 * weight) * Float.random(in: 0.8...1.0), pitch: pitch)
        if Float.random(in: 0...1) < 0.3 {
            let echo = name.hasPrefix("fx_drop") ? pick("fx_drop", 3) : pick("fx_splash_small", 3)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 0.09...0.2)) { [weak self] in
                self?.play(echo, x: x + Float.random(in: -0.1...0.1), gain: 0.3, pitch: pitch * Float.random(in: 1.1...1.4))
            }
        }
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

    /// A finger cutting across open water: water rushing past it, up with
    /// the speed of the hand.
    func wakeBegin(id: Int) {
        guard held[id] == nil else { return }
        guard let v = play("amb_stream", gain: 0.0, pitch: 1.35, loop: true) else { return }
        held[id] = v
    }

    func wakeLevel(id: Int, speed: Float) {
        guard let v = held[id] else { return }
        let want = 0.04 + 0.34 * min(1, speed / 600)
        v.player.volume += (want - v.player.volume) * 0.2
    }

    func wakeEnd(id: Int) { holdEnd(id: id) }

    /// A whirl turning in the pond: the same stream, slowed, low under
    /// everything else for as long as it lasts.
    func whirlBegin(id: Int) {
        guard held[id] == nil else { return }
        guard let v = play("amb_stream", gain: 0.0, pitch: 0.9, loop: true) else { return }
        held[id] = v
    }

    func whirlLevel(id: Int, strength: Float) {
        guard let v = held[id] else { return }
        let want = 0.28 * min(1, max(0, strength))
        v.player.volume += (want - v.player.volume) * 0.12
    }

    func whirlEnd(id: Int) { holdEnd(id: id) }

    /// A stream running into the pond: the same water, low and steady, under
    /// everything for as long as the level lasts.
    func inletBegin(id: Int) {
        guard held[id] == nil else { return }
        guard let v = play("amb_stream", gain: 0.0, pitch: 1.05, loop: true) else { return }
        held[id] = v
        v.player.volume = 0.15
    }

    func inletEnd(id: Int) { holdEnd(id: id) }

    /// A gust crosses the pond: the reeds rustle and the air lifts with it.
    func gust(x: Float) {
        play("fx_reeds", x: x, gain: 0.75, pitch: 0.85)
        play("fx_splash_big", x: x, gain: 0.3, pitch: 0.7)
        liftAir(1.35, seconds: 1.4)
    }

    /// The wind that crosses the pond on its own: quieter than a thrown gust,
    /// the reeds rustling and the season's air lifting behind it.
    func breeze(x: Float) {
        play("fx_reeds", x: x, gain: 0.38, pitch: 0.92)
        liftAir(1.18, seconds: 1.8)
    }

    /// A drop off a branch onto the water.
    func drip(x: Float, gain: Float = 1) {
        play(pick("fx_drop", 3), x: x, gain: 0.22 * gain, pitch: 1.35)
    }

    /// A fish mouthing at the surface: barely there.
    func mouth(x: Float) {
        play(pick("fx_splash_small", 3), x: x, gain: 0.18, pitch: 1.3)
    }

    /// The season's air swells for a moment, then settles back.
    private func liftAir(_ amount: Float, seconds: TimeInterval) {
        airLift = amount
        airLiftUntil = CACurrentMediaTime() + seconds
    }

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

    func iceCrack(x: Float, gain: Float = 0.9) { play(pick("fx_ice_crack", 3), x: x, gain: gain, pitch: gain < 0.5 ? 0.85 : 1) }
    /// A bird in the trees, a little way off.
    func bird(x: Float) { play("fx_bird_flutter", x: x, gain: 0.35, pitch: Float.random(in: 0.9...1.1)) }

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
    func frog(x: Float, gain: Float = 0.7) { play("fx_frog_jump", x: x, gain: gain) }
    func reeds(x: Float) { play("fx_reeds", x: x, gain: 0.5) }
    /// The camera drops into a pool on the map.
    func dive() { play("fx_splash_big", gain: 0.9, pitch: 0.9) }
    /// A card lands on the water.
    func paper() { play("fx_paper", gain: 0.6) }

    // MARK: - Instruments and the growing things

    /// Whether the manifest names a sound. Agent E's recordings land by name
    /// and each hook below plays its own file once it is there, falling back
    /// to an older file at another speed until then.
    private func present(_ name: String) -> Bool {
        loadManifest()
        return entries[name] != nil
    }

    /// The shishi-odoshi lands on its stone: one hollow knock.
    func bamboo(x: Float) {
        if present("fx_bamboo_knock") { play("fx_bamboo_knock", x: x, gain: 0.9) }
        else { play("fx_wood_knock", x: x, gain: 0.85, pitch: 0.82) }
    }

    /// The five notes of the water chime, a pentatonic over the recording's
    /// own pitch. Notes past the fifth climb into the next octave.
    static let chimeRatios: [Float] = [1, 9.0 / 8, 5.0 / 4, 3.0 / 2, 5.0 / 3]

    /// A crest passes over a chime stone: a drip ringing in the jar.
    func chime(note: Int, x: Float) {
        let n = max(0, note)
        let ratio = SoundDirector.chimeRatios[n % 5] * pow(2, Float(n / 5))
        if present("fx_water_chime_1") { play(pick("fx_water_chime", 3), x: x, gain: 0.8, pitch: ratio) }
        else { play("fx_bell", x: x, gain: 0.55, pitch: ratio) }
    }

    /// Water going over the lip into the dry pool.
    func spill(x: Float) {
        if present("fx_spill") { play("fx_spill", x: x, gain: 0.6) }
        else { play(pick("fx_splash_small", 3), x: x, gain: 0.45, pitch: 0.78) }
    }

    /// Dry leaves shifting on the water.
    func leaves(x: Float) {
        if present("fx_leaves_1") { play(pick("fx_leaves", 2), x: x, gain: 0.5) }
        else { play("fx_reeds", x: x, gain: 0.32, pitch: 1.25) }
    }

    /// Weed bending under a passing wave: wet vegetation, low.
    func weedRustle(x: Float) {
        if present("fx_weed_rustle") { play("fx_weed_rustle", x: x, gain: 0.45) }
        else { play("fx_reeds", x: x, gain: 0.28, pitch: 0.7) }
    }

    /// A koi taking something off the surface.
    func gulp(x: Float, gain: Float = 1) {
        if present("fx_gulp") { play("fx_gulp", x: x, gain: 0.5 * gain) }
        else { play(pick("fx_drop", 3), x: x, gain: 0.38 * gain, pitch: 0.68) }
    }

    /// A near miss: the target shivers with a soft short tick.
    func tremble(x: Float) {
        if present("fx_tremble") { play("fx_tremble", x: x, gain: 0.3) }
        else { play(pick("fx_drop", 3), x: x, gain: 0.12, pitch: 1.7) }
    }

    /// Dusk falls on the still pond: the season's air gives way to crickets.
    /// Nothing changes until the night recording is in the manifest.
    func startNightAmbience() {
        guard present("amb_night") else { return }
        startAmbience(named: "amb_night")
    }

    // MARK: - The reward

    /// The three notes of the reward, as pitches on the finishing chime
    /// until the recordings are in: a common win is one, rare two, gold all
    /// three climbing.
    private static let rewardPitches: [Float] = [1.0, 1.12, 1.26]

    /// One note of the chord: the recording for it when the manifest has it,
    /// else the finishing chime at that pitch with the bell under it.
    private func rewardNote(_ index: Int, gain: Float = 1) {
        let n = max(0, min(2, index))
        if present("fx_reward_\(n + 1)") {
            play("fx_reward_\(n + 1)", gain: 0.9 * gain)
        } else {
            let pitch = SoundDirector.rewardPitches[n]
            play("fx_chime_complete", gain: 0.85 * gain, pitch: pitch)
            play("fx_bell", gain: 0.3 * gain, pitch: pitch)
        }
    }

    /// The chord that comes with the burst: as many notes as the tier
    /// deserves, each a little after the last.
    func rewardChord(tier: Rarity) {
        let notes = tier == .superRare ? 3 : (tier == .rare ? 2 : 1)
        for i in 0..<notes {
            let delay = 0.16 * Double(i)
            if i == 0 { rewardNote(0) } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.rewardNote(i) }
            }
        }
        liftAir(1.15, seconds: 1.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.play("fx_bird_flutter", gain: 0.4) }
    }

    /// The item breaks the surface: a rare one gets a second note, a gold
    /// one the top two.
    func rewardNote(tier: Rarity) {
        switch tier {
        case .common: break
        case .rare: rewardNote(1, gain: 0.7)
        case .superRare:
            rewardNote(1, gain: 0.7)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in self?.rewardNote(2, gain: 0.7) }
        }
    }

    /// A petal picked off the water, and the petals a win paid.
    func petalPick() {
        if present("fx_petal") { play("fx_petal", gain: 0.6) }
        else { play(pick("fx_drop", 3), gain: 0.35, pitch: 1.7) }
    }

    /// The item goes under for the bank.
    func rewardDive() {
        play(pick("fx_splash_small", 3), gain: 0.7, pitch: 0.92)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.play(self?.pick("fx_drop", 3) ?? "fx_drop", gain: 0.3, pitch: 0.8)
        }
    }
}
