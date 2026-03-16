import AVFoundation

/// Synthesized sound effects for recording start/stop feedback
final class SoundEffects {
    static let shared = SoundEffects()

    /// Soft ascending two-tone — recording started
    func playStart() {
        playTone(frequencies: [880, 1320], durations: [0.06, 0.08], volume: 0.15)
    }

    /// Soft descending two-tone — recording stopped
    func playStop() {
        playTone(frequencies: [1320, 880], durations: [0.06, 0.08], volume: 0.15)
    }

    private func playTone(frequencies: [Double], durations: [Double], volume: Float) {
        DispatchQueue.global(qos: .userInteractive).async {
            let sampleRate: Double = 44100
            var samples: [Float] = []

            for (freq, dur) in zip(frequencies, durations) {
                let count = Int(sampleRate * dur)
                for i in 0..<count {
                    let t = Double(i) / sampleRate
                    let progress = Float(i) / Float(count)
                    let envelope: Float
                    if progress < 0.1 {
                        envelope = progress / 0.1
                    } else if progress > 0.7 {
                        envelope = (1.0 - progress) / 0.3
                    } else {
                        envelope = 1.0
                    }
                    let sample = Float(sin(2.0 * .pi * freq * t)) * envelope * volume
                    samples.append(sample)
                }
                let gapSamples = Int(sampleRate * 0.015)
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
