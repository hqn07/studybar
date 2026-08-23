import AVFoundation

/// (57) Ambient focus noise, generated live — no bundled audio files.
final class FocusSounds {
    static let shared = FocusSounds()

    enum Kind: String, CaseIterable, Identifiable {
        case none = "Off", white = "White", brown = "Brown", pink = "Pink"
        var id: String { rawValue }
    }

    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private var fadeTimer: Timer?
    private(set) var kind: Kind = .none
    var volume: Float = 0.5      // 0…1 user level (applied via mixer output)

    /// Live volume — safe to call while playing.
    func setVolume(_ v: Float) {
        volume = max(0, min(1, v))
        fadeTimer?.invalidate()
        engine.mainMixerNode.outputVolume = volume
    }

    private func fade(to target: Float, duration: Double, completion: (() -> Void)? = nil) {
        fadeTimer?.invalidate()
        let steps = 24
        let start = engine.mainMixerNode.outputVolume
        var i = 0
        fadeTimer = Timer.scheduledTimer(withTimeInterval: duration / Double(steps), repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            i += 1
            let f = Float(i) / Float(steps)
            self.engine.mainMixerNode.outputVolume = start + (target - start) * f
            if i >= steps { t.invalidate(); completion?() }
        }
    }

    func play(_ k: Kind) {
        stop(fade: false)
        kind = k
        guard k != .none else { return }

        let format = engine.outputNode.inputFormat(forBus: 0)
        var brown: Float = 0
        var pink = [Float](repeating: 0, count: 7)
        let gain: Float = 0.35   // internal headroom; user level via mixer

        let src = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                let white = Float.random(in: -1...1)
                var sample: Float
                switch k {
                case .white:
                    sample = white
                case .brown:
                    brown = (brown + 0.02 * white) / 1.02
                    sample = brown * 3.5
                case .pink:
                    pink[0] = 0.99886 * pink[0] + white * 0.0555179
                    pink[1] = 0.99332 * pink[1] + white * 0.0750759
                    pink[2] = 0.96900 * pink[2] + white * 0.1538520
                    pink[3] = 0.86650 * pink[3] + white * 0.3104856
                    pink[4] = 0.55000 * pink[4] + white * 0.5329522
                    pink[5] = -0.7616 * pink[5] - white * 0.0168980
                    sample = (pink[0]+pink[1]+pink[2]+pink[3]+pink[4]+pink[5]+pink[6]+white*0.5362) * 0.11
                    pink[6] = white * 0.115926
                case .none:
                    sample = 0
                }
                sample *= gain
                for buffer in abl {
                    let buf = buffer.mData!.assumingMemoryBound(to: Float.self)
                    buf[frame] = sample
                }
            }
            return noErr
        }

        engine.attach(src)
        engine.connect(src, to: engine.mainMixerNode, format: format)
        node = src
        engine.mainMixerNode.outputVolume = 0
        try? engine.start()
        fade(to: volume, duration: 1.4)   // fade in
    }

    var isPlaying: Bool { kind != .none }

    /// Graceful stop with fade-out (default) or immediate.
    func stop(fade doFade: Bool = true) {
        guard kind != .none else { hardStop(); return }
        if doFade {
            fade(to: 0, duration: 1.0) { [weak self] in self?.hardStop() }
        } else {
            hardStop()
        }
    }

    private func hardStop() {
        fadeTimer?.invalidate(); fadeTimer = nil
        engine.stop()
        if let n = node { engine.detach(n); node = nil }
        kind = .none
    }
}
