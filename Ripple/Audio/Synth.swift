import AVFoundation
import os

/// A small additive synthesiser. Everything the game plays is made here from
/// sine partials and filtered noise, so there are no audio files to license,
/// and every note can be pitched to the water that made it.
final class Synth {

    struct Voice {
        var id: Int
        var freq: Float
        var phase: Float = 0
        var amp: Float
        var targetAmp: Float
        var attack: Float          // per-sample coefficient toward targetAmp when rising
        var release: Float         // per-sample coefficient toward targetAmp when falling
        var partials: [(ratio: Float, gain: Float)]
        var noise = false
        var cutoff: Float = 1      // one-pole lowpass coefficient for noise
        var lp: Float = 0
        var lp2: Float = 0
        var sweepTo: Float?        // glide the frequency toward this
        var sweepRate: Float = 0   // per-sample fraction
        var lfoRate: Float = 0     // slow amplitude wobble, Hz
        var lfoDepth: Float = 0
        var age: Float = 0
    }

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private(set) var sampleRate: Float = 48000
    private let lock = OSAllocatedUnfairLock(initialState: [Voice]())
    private var nextID = 1
    private var running = false
    private var rng = SystemRandomNumberGenerator()

    var masterGain: Float = 0.9

    func start() {
        guard !running else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("[synth] audio session: \(error)")
        }

        let format = engine.outputNode.inputFormat(forBus: 0)
        sampleRate = Float(format.sampleRate)
        let sr = sampleRate
        let lock = self.lock
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1) else { return }
        let node = AVAudioSourceNode(format: mono) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let out = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let gain = self?.masterGain ?? 0.9
            lock.withLock { voices in
                Synth.render(voices: &voices, into: out, frames: Int(frameCount), sampleRate: sr, gain: gain)
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: mono)
        engine.mainMixerNode.outputVolume = 1
        source = node
        do {
            try engine.start()
            running = true
        } catch {
            print("[synth] engine start: \(error)")
        }
    }

    func stop() {
        guard running else { return }
        engine.stop()
        running = false
    }

    // MARK: - Rendering

    private static func render(voices: inout [Voice], into out: UnsafeMutablePointer<Float>, frames: Int, sampleRate: Float, gain: Float) {
        for i in 0..<frames { out[i] = 0 }
        let twoPi = Float.pi * 2
        var i = 0
        while i < voices.count {
            var v = voices[i]
            let lfoStep = v.lfoRate * twoPi / sampleRate
            for n in 0..<frames {
                // Envelope.
                var target = v.targetAmp
                if v.lfoDepth > 0 {
                    target *= 1 - v.lfoDepth * 0.5 * (1 + sin(v.age * lfoStep))
                }
                v.amp += (target - v.amp) * (target > v.amp ? v.attack : v.release)
                v.age += 1

                if let to = v.sweepTo {
                    v.freq += (to - v.freq) * v.sweepRate
                }

                var s: Float = 0
                if v.noise {
                    let white = Float.random(in: -1...1)
                    v.lp += (white - v.lp) * v.cutoff
                    v.lp2 += (v.lp - v.lp2) * v.cutoff
                    s = v.lp2 * 3
                } else {
                    let ph = v.phase
                    for p in v.partials {
                        s += sin(ph * p.ratio) * p.gain
                    }
                    v.phase += twoPi * v.freq / sampleRate
                    if v.phase > twoPi * 64 { v.phase -= twoPi * 64 }
                }
                out[n] += s * v.amp
            }
            if v.targetAmp <= 0.0001 && v.amp < 0.0006 {
                voices.remove(at: i)
            } else {
                voices[i] = v
                i += 1
            }
        }
        for n in 0..<frames {
            let x = out[n] * gain
            out[n] = tanh(x)
        }
    }

    // MARK: - Voice management

    @discardableResult
    func add(_ voice: Voice) -> Int {
        var v = voice
        nextID += 1
        v.id = nextID
        lock.withLock { $0.append(v) }
        return v.id
    }

    func set(id: Int, targetAmp: Float? = nil, freq: Float? = nil, release: Float? = nil) {
        lock.withLock { voices in
            guard let i = voices.firstIndex(where: { $0.id == id }) else { return }
            if let t = targetAmp { voices[i].targetAmp = t }
            if let f = freq { voices[i].sweepTo = f }
            if let r = release { voices[i].release = r }
        }
    }

    func release(id: Int, over seconds: Float) {
        set(id: id, targetAmp: 0, release: coefficient(seconds: seconds))
    }

    /// Per-sample smoothing coefficient that gets ~95% of the way in `seconds`.
    func coefficient(seconds: Float) -> Float {
        guard seconds > 0 else { return 1 }
        return min(1, 3.0 / (seconds * sampleRate))
    }

    // MARK: - Instruments

    /// A struck note: fast attack, exponential decay.
    @discardableResult
    func pluck(freq: Float, amp: Float, decay: Float, partials: [(ratio: Float, gain: Float)]? = nil, attack: Float = 0.004) -> Int {
        add(Voice(id: 0, freq: freq, amp: 0, targetAmp: 0,
                  attack: coefficient(seconds: attack), release: coefficient(seconds: decay),
                  partials: partials ?? [(1, 1), (2, 0.35), (3, 0.12)]))
            .also { id in
                // Kick the envelope: rise to amp, then decay toward zero.
                self.lock.withLock { voices in
                    guard let i = voices.firstIndex(where: { $0.id == id }) else { return }
                    voices[i].amp = amp
                    voices[i].targetAmp = 0
                }
            }
    }

    /// A sustained tone whose level the caller drives.
    @discardableResult
    func sustain(freq: Float, amp: Float, attack: Float, partials: [(ratio: Float, gain: Float)]? = nil) -> Int {
        add(Voice(id: 0, freq: freq, amp: 0, targetAmp: amp,
                  attack: coefficient(seconds: attack), release: coefficient(seconds: 0.8),
                  partials: partials ?? [(1, 1), (2, 0.25), (3, 0.08)]))
    }

    /// Filtered noise, sustained until released.
    @discardableResult
    func wash(amp: Float, cutoffHz: Float, attack: Float, lfoRate: Float = 0, lfoDepth: Float = 0) -> Int {
        var v = Voice(id: 0, freq: 0, amp: 0, targetAmp: amp,
                      attack: coefficient(seconds: attack), release: coefficient(seconds: 1.0),
                      partials: [], noise: true)
        v.cutoff = min(1, cutoffHz * 2 * Float.pi / sampleRate)
        v.lfoRate = lfoRate
        v.lfoDepth = lfoDepth
        return add(v)
    }

    /// A short noise burst.
    func burst(amp: Float, cutoffHz: Float, decay: Float) {
        var v = Voice(id: 0, freq: 0, amp: amp, targetAmp: 0,
                      attack: 1, release: coefficient(seconds: decay), partials: [], noise: true)
        v.cutoff = min(1, cutoffHz * 2 * Float.pi / sampleRate)
        add(v)
    }

    /// A sine that glides from one pitch to another while it decays.
    func sweep(from: Float, to: Float, amp: Float, decay: Float, glide: Float) {
        var v = Voice(id: 0, freq: from, amp: amp, targetAmp: 0,
                      attack: 1, release: coefficient(seconds: decay), partials: [(1, 1), (2, 0.15)])
        v.sweepTo = to
        v.sweepRate = coefficient(seconds: glide)
        add(v)
    }
}

private extension Int {
    func also(_ f: (Int) -> Void) -> Int { f(self); return self }
}
