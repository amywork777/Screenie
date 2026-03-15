import AVFoundation

/// Synthesized sound effects manager for Blink recording and UI feedback
class SoundEffects {
    static let shared = SoundEffects()

    private var audioEngine: AVAudioEngine?
    private var audioSession: AVAudioSession

    init() {
        audioSession = AVAudioSession.sharedInstance()
        setupAudio()
    }

    private func setupAudio() {
        do {
            try audioSession.setCategory(.default, options: .duckOthers)
            try audioSession.setActive(true)
            audioEngine = AVAudioEngine()
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }

    /// Play a short beep sound for recording start
    func playRecordingStartSound() {
        playTone(frequency: 800, duration: 0.1)
    }

    /// Play a short beep sound for recording stop
    func playRecordingStopSound() {
        playTone(frequency: 600, duration: 0.15)
    }

    /// Play a UI feedback click sound
    func playClickSound() {
        playTone(frequency: 1000, duration: 0.05)
    }

    private func playTone(frequency: Float, duration: TimeInterval) {
        guard let audioEngine = audioEngine else { return }

        let sampleRate = audioEngine.outputNode.outputFormat(forBus: 0)?.sampleRate ?? 44100
        let sampleCount = Int(Float(sampleRate) * Float(duration))

        var audioBuffer = [Float](repeating: 0, count: sampleCount)
        let amplitude: Float = 0.3

        for i in 0..<sampleCount {
            let time = Float(i) / Float(sampleRate)
            let sine = sin(2.0 * .pi * frequency * time)
            audioBuffer[i] = sine * amplitude
        }

        // Create envelope for smooth fade-in/fade-out
        let fadeTime = Int(Float(sampleRate) * 0.01)
        for i in 0..<fadeTime {
            let fade = Float(i) / Float(fadeTime)
            audioBuffer[i] *= fade
            audioBuffer[sampleCount - 1 - i] *= fade
        }

        if let avAudioBuffer = AVAudioPCMBuffer(
            pcmFormat: audioEngine.outputNode.outputFormat(forBus: 0)\!,
            frameCapacity: AVAudioFrameCount(sampleCount)
        ) {
            avAudioBuffer.frameLength = AVAudioFrameCount(sampleCount)
            for i in 0..<sampleCount {
                avAudioBuffer.floatChannelData?[0][i] = audioBuffer[i]
            }

            do {
                try audioEngine.start()
                let mixer = audioEngine.mainMixerNode
                audioEngine.connect(audioEngine.outputNode, to: mixer, format: nil)

                // Simple playback using system sound for simplicity
                AudioServicesPlayAlertSound(SystemSoundID(1000 + UInt32(frequency)))
            } catch {
                print("Failed to play tone: \(error)")
            }
        }
    }
}
