import SwiftUI
import Combine

@MainActor
class MorseCodeEngine: ObservableObject {
    // MARK: - Sending State
    @Published var inputText: String = ""
    @Published var morseRepresentation: String = ""
    @Published var isSending: Bool = false
    @Published var currentSendIndex: Int = 0
    @Published var sendingSpeed: Double = 15 // WPM

    // MARK: - Receiving State
    @Published var isReceiving: Bool = false
    @Published var detectedMorse: String = ""
    @Published var decodedText: String = ""
    @Published var lightDetected: Bool = false
    @Published var currentBrightnessLevel: Double = 0.0
    @Published var detectionThreshold: Double = 0.5
    @Published var receivedSignals: [MorseSignal] = []

    // MARK: - Sending History
    @Published var sendHistory: [MorseMessage] = []
    @Published var receiveHistory: [MorseMessage] = []

    private var sendTask: Task<Void, Never>?
    private var flashEvents: [MorseCode.FlashEvent] = []

    // MARK: - Sending

    func updateMorseRepresentation() {
        morseRepresentation = MorseCode.encode(inputText)
    }

    func startSending(using flashlightService: FlashlightService) {
        guard !inputText.isEmpty else { return }

        updateMorseRepresentation()
        let timing = MorseCode.Timing(wpm: sendingSpeed)
        flashEvents = MorseCode.toFlashSequence(morseRepresentation, timing: timing)
        isSending = true
        currentSendIndex = 0

        sendTask = Task {
            // Set brightness to max for morse signaling
            let previousBrightness = flashlightService.brightness
            flashlightService.setBrightness(1.0)

            for (index, event) in flashEvents.enumerated() {
                if Task.isCancelled { break }
                currentSendIndex = index

                switch event {
                case .on(let duration):
                    flashlightService.turnOn()
                    try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                case .pause(let duration):
                    flashlightService.turnOff()
                    try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                }
            }

            flashlightService.turnOff()
            flashlightService.setBrightness(previousBrightness)

            let message = MorseMessage(
                text: inputText,
                morse: morseRepresentation,
                timestamp: Date(),
                direction: .sent
            )
            sendHistory.insert(message, at: 0)

            isSending = false
            currentSendIndex = 0
        }
    }

    func stopSending(using flashlightService: FlashlightService) {
        sendTask?.cancel()
        sendTask = nil
        flashlightService.turnOff()
        isSending = false
        currentSendIndex = 0
    }

    var sendProgress: Double {
        guard !flashEvents.isEmpty else { return 0 }
        return Double(currentSendIndex) / Double(flashEvents.count)
    }

    // MARK: - Receiving / Decoding

    /// Called by the camera service when light level changes
    func updateLightLevel(_ level: Double) {
        currentBrightnessLevel = level
        let wasDetected = lightDetected
        lightDetected = level > detectionThreshold

        if isReceiving {
            if lightDetected && !wasDetected {
                // Light just turned on - start timing
                onLightOn()
            } else if !lightDetected && wasDetected {
                // Light just turned off - record duration
                onLightOff()
            }
        }
    }

    private var lightOnTime: Date?
    private var lightOffTime: Date?
    private var gapTimer: Task<Void, Never>?

    private func onLightOn() {
        lightOnTime = Date()
        gapTimer?.cancel()
    }

    private func onLightOff() {
        guard let onTime = lightOnTime else { return }
        let duration = Date().timeIntervalSince(onTime)
        lightOffTime = Date()

        let timing = MorseCode.Timing(wpm: sendingSpeed)
        let threshold = (timing.dotDuration + timing.dashDuration) / 2.0

        let signal: MorseSignal
        if duration < threshold {
            signal = MorseSignal(type: .dot, duration: duration, timestamp: Date())
            detectedMorse += "."
        } else {
            signal = MorseSignal(type: .dash, duration: duration, timestamp: Date())
            detectedMorse += "-"
        }
        receivedSignals.append(signal)

        // Start gap timer to detect letter/word gaps
        startGapTimer()
    }

    private func startGapTimer() {
        gapTimer?.cancel()
        let timing = MorseCode.Timing(wpm: sendingSpeed)

        gapTimer = Task {
            // Wait for letter gap duration
            try? await Task.sleep(nanoseconds: UInt64(timing.letterGap * 1.5 * 1_000_000_000))
            if Task.isCancelled { return }

            // This is at least a letter gap — add space
            detectedMorse += " "
            tryDecode()

            // Wait more for word gap
            try? await Task.sleep(nanoseconds: UInt64((timing.wordGap - timing.letterGap) * 1.5 * 1_000_000_000))
            if Task.isCancelled { return }

            // This is a word gap
            detectedMorse += "/ "
        }
    }

    private func tryDecode() {
        decodedText = MorseCode.decode(detectedMorse.trimmingCharacters(in: .whitespaces))
    }

    func startReceiving() {
        isReceiving = true
        detectedMorse = ""
        decodedText = ""
        receivedSignals = []
    }

    func stopReceiving() {
        isReceiving = false
        gapTimer?.cancel()
        tryDecode()

        if !detectedMorse.trimmingCharacters(in: .whitespaces).isEmpty {
            let message = MorseMessage(
                text: decodedText,
                morse: detectedMorse.trimmingCharacters(in: .whitespaces),
                timestamp: Date(),
                direction: .received
            )
            receiveHistory.insert(message, at: 0)
        }
    }

    func clearReceived() {
        detectedMorse = ""
        decodedText = ""
        receivedSignals = []
    }
}

// MARK: - Supporting Types

struct MorseSignal: Identifiable {
    let id = UUID()
    let type: SignalType
    let duration: TimeInterval
    let timestamp: Date

    enum SignalType {
        case dot
        case dash
    }
}

struct MorseMessage: Identifiable {
    let id = UUID()
    let text: String
    let morse: String
    let timestamp: Date
    let direction: Direction

    enum Direction {
        case sent
        case received
    }

    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
}
