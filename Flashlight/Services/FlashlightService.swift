import SwiftUI
import AVFoundation

@MainActor
class FlashlightService: ObservableObject {
    @Published var isOn = false
    @Published var brightness: Double = 1.0
    @Published var beamWidth: Double = 1.0

    private var device: AVCaptureDevice? {
        AVCaptureDevice.default(for: .video)
    }

    var hasTorch: Bool {
        device?.hasTorch ?? false
    }

    func toggle() {
        isOn.toggle()
        applyTorch()
    }

    func turnOn() {
        isOn = true
        applyTorch()
    }

    func turnOff() {
        isOn = false
        applyTorch()
    }

    func setBrightness(_ value: Double) {
        brightness = max(0.01, min(1.0, value))
        if isOn {
            applyTorch()
        }
    }

    func setBeamWidth(_ value: Double) {
        beamWidth = max(0.0, min(1.0, value))
        if isOn {
            applyTorch()
        }
    }

    func applyTorch() {
        guard let device = device, device.hasTorch else { return }

        do {
            try device.lockForConfiguration()

            if isOn {
                let effectiveBrightness = Float(brightness * (0.3 + 0.7 * beamWidth))
                try device.setTorchModeOn(level: max(0.01, min(1.0, effectiveBrightness)))
            } else {
                device.torchMode = .off
            }

            device.unlockForConfiguration()
        } catch {
            print("Torch error: \(error.localizedDescription)")
        }
    }

    /// Flash the torch for a specific duration (used for Morse code)
    func flash(duration: TimeInterval) async {
        turnOn()
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        turnOff()
    }

    /// Pause between flashes
    func pause(duration: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }
}
