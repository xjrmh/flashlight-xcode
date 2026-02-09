import AVFoundation

final class MorseSoundService {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isConfigured = false

    init() {
        configureSessionIfNeeded()
    }

    func playTone(duration: TimeInterval, frequency: Double = 800) {
        configureEngineIfNeeded()

        let sampleRate = 44100.0
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard frameCount > 0 else { return }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }

        buffer.frameLength = frameCount
        let thetaIncrement = 2.0 * Double.pi * frequency / sampleRate
        var theta = 0.0

        if let channelData = buffer.floatChannelData?[0] {
            for frame in 0..<Int(frameCount) {
                channelData[frame] = Float(sin(theta)) * 0.3
                theta += thetaIncrement
            }
        }

        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !player.isPlaying {
            player.play()
        }
    }

    func stop() {
        player.stop()
    }

    private func configureSessionIfNeeded() {
        guard !isConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.ambient, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("Audio session error: \(error.localizedDescription)")
        }
        isConfigured = true
    }

    private func configureEngineIfNeeded() {
        guard engine.attachedNodes.contains(player) == false else { return }
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 1)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                print("Audio engine error: \(error.localizedDescription)")
            }
        }
    }
}
