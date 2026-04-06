import AVFoundation

/// Clean, minimal sound effects for recording start/stop
final class SoundEffects {
    static let shared = SoundEffects()

    /// Soft pop — recording started
    func playStart() {
        playTone(frequencies: [523, 784], durations: [0.04, 0.06], volume: 0.12, waveform: .soft)
    }

    /// Gentle click — recording stopped
    func playStop() {
        playTone(frequencies: [784, 523], durations: [0.04, 0.06], volume: 0.12, waveform: .soft)
    }

    private enum Waveform { case soft }

    private func playTone(frequencies: [Double], durations: [Double], volume: Float, waveform: Waveform) {
        DispatchQueue.global(qos: .userInteractive).async {
            let sampleRate: Double = 44100
            var samples: [Float] = []

            for (freq, dur) in zip(frequencies, durations) {
                let count = Int(sampleRate * dur)
                for i in 0..<count {
                    let t = Double(i) / sampleRate
                    let progress = Float(i) / Float(count)

                    // Smooth envelope — fast attack, gentle release
                    let envelope: Float
                    if progress < 0.05 {
                        envelope = progress / 0.05
                    } else {
                        envelope = pow(1.0 - progress, 2.0)
                    }

                    // Soft sine with slight harmonic for warmth
                    let fundamental = Float(sin(2.0 * .pi * freq * t))
                    let harmonic = Float(sin(2.0 * .pi * freq * 2.0 * t)) * 0.15
                    let sample = (fundamental + harmonic) * envelope * volume
                    samples.append(sample)
                }
                // Tiny gap between tones
                let gapSamples = Int(sampleRate * 0.01)
                samples.append(contentsOf: [Float](repeating: 0, count: gapSamples))
            }

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)

            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
            engine.connect(player, to: engine.mainMixerNode, format: format)

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)

            if let channelData = buffer.floatChannelData?[0] {
                for i in 0..<samples.count {
                    channelData[i] = samples[i]
                }
            }

            do {
                try engine.start()
                player.play()
                player.scheduleBuffer(buffer) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        engine.stop()
                    }
                }
            } catch {
                NSLog("Screenie: Sound failed: %@", error.localizedDescription)
            }
        }
    }
}
