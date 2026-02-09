import SwiftUI
import AVFoundation

@MainActor
class FlashlightService: ObservableObject {
    @Published var isOn = false
    @Published var brightness: Double = 1.0
    @Published var torchError: String?
    @Published var isBrightnessLockedToMax: Bool = false
    @Published var isStrobing: Bool = false
    @Published var strobeIntensity: Double = 0.0

    // Cache the device reference
    private lazy var device: AVCaptureDevice? = {
        AVCaptureDevice.default(for: .video)
    }()

    private var strobeTask: Task<Void, Never>?
    private var strobePreviousIsOn: Bool = false

    var hasTorch: Bool {
        device?.hasTorch ?? false
    }
    
    var isTorchAvailable: Bool {
        device?.isTorchAvailable ?? false
    }
    
    var isTorchActive: Bool {
        device?.isTorchActive ?? false
    }

    func toggle() {
        if isStrobing {
            stopStrobe()
        }
        isOn.toggle()
        applyTorch()
    }

    func turnOn() {
        if isStrobing {
            stopStrobe()
        }
        isOn = true
        applyTorch()
    }

    func turnOff() {
        if isStrobing {
            stopStrobe()
        }
        isOn = false
        applyTorch()
    }

    func setBrightness(_ value: Double) {
        guard !isBrightnessLockedToMax else { return }
        brightness = max(0.01, min(1.0, value))
        if isOn {
            applyTorch()
        }
    }

    func lockBrightnessToMax() {
        isBrightnessLockedToMax = true
        brightness = 1.0
        if isOn {
            applyTorch()
        }
    }

    func unlockBrightness() {
        isBrightnessLockedToMax = false
    }

    func startStrobe(intensity: Double) {
        let clampedIntensity = clamp(intensity)
        torchError = nil
        strobePreviousIsOn = isOn
        isStrobing = true
        strobeIntensity = clampedIntensity
        isOn = true

        if strobeTask == nil {
            strobeTask = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled && self.isStrobing {
                    let interval = self.strobeInterval(for: self.strobeIntensity)
                    let level = Float(max(0.01, min(1.0, self.brightness)))
                    self.setTorch(isOn: true, level: level)
                    try? await Task.sleep(nanoseconds: UInt64(interval * 0.5 * 1_000_000_000))
                    self.setTorch(isOn: false, level: 0)
                    try? await Task.sleep(nanoseconds: UInt64(interval * 0.5 * 1_000_000_000))
                }
            }
        }
    }

    func updateStrobeIntensity(_ intensity: Double) {
        guard isStrobing else { return }
        strobeIntensity = clamp(intensity)
    }

    func stopStrobe() {
        guard isStrobing else { return }
        isStrobing = false
        strobeIntensity = 0.0
        strobeTask?.cancel()
        strobeTask = nil
        isBrightnessLockedToMax = false
        isOn = strobePreviousIsOn
        applyTorch()
    }

    private func strobeInterval(for intensity: Double) -> Double {
        let clamped = clamp(intensity)
        let minInterval = 0.04
        let maxInterval = 0.18
        return maxInterval - (maxInterval - minInterval) * clamped
    }

    private func clamp(_ value: Double) -> Double {
        max(0.0, min(1.0, value))
    }

    private func setTorch(isOn: Bool, level: Float) {
        guard let device = device else { return }
        guard device.hasTorch, device.isTorchAvailable else { return }
        do {
            try device.lockForConfiguration()
            if isOn {
                try device.setTorchModeOn(level: level)
            } else {
                device.torchMode = .off
            }
            device.unlockForConfiguration()
        } catch {
            torchError = error.localizedDescription
        }
    }

    func applyTorch() {
        torchError = nil
        
        guard let device = device else {
            torchError = "No camera device found"
            isOn = false
            return
        }
        
        guard device.hasTorch else {
            torchError = "Device has no torch"
            isOn = false
            return
        }
        
        guard device.isTorchAvailable else {
            torchError = "Torch not available"
            isOn = false
            return
        }

        do {
            try device.lockForConfiguration()

            if isOn {
                try device.setTorchModeOn(level: Float(brightness))
            } else {
                device.torchMode = .off
            }

            device.unlockForConfiguration()
        } catch {
            torchError = error.localizedDescription
            isOn = false
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
