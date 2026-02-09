import SwiftUI
import Combine

@MainActor
class MorseCodeEngine: ObservableObject {
    // MARK: - Preamble Pattern
    /// Unique sync pattern: short-short-long-long-short (distinct from any letter)
    static let preamblePattern = "..--."
    
    // MARK: - Sending State
    @Published var inputText: String = ""
    @Published var morseRepresentation: String = ""
    @Published var isSending: Bool = false
    @Published var currentSendIndex: Int = 0
    @Published var currentSendElementIndex: Int? = nil
    @Published var sendingSpeed: Double = 5 // WPM
    @Published var loopSending: Bool = false
    @Published var currentLoopCount: Int = 0
    @Published var sendWithSound: Bool = false
    @Published var sendWithPreamble: Bool = true

    // MARK: - Receiving State
    @Published var isReceiving: Bool = false
    @Published var detectedMorse: String = ""
    @Published var decodedText: String = ""
    @Published var lightDetected: Bool = false
    @Published var currentBrightnessLevel: Double = 0.0
    @Published var detectionThreshold: Double = 0.5
    @Published var autoSensitivity: Bool = true
    @Published var receivedSignals: [MorseSignal] = []
    @Published var dedicatedSourceMode: Bool = false
    @Published var preambleDetected: Bool = false
    private var rawDetectedMorse: String = "" // Buffer before preamble detection
    private var ambientLevel: Double = 0
    private var smoothedLevel: Double = 0
    private var emaMean: Double = 0
    private var emaVariance: Double = 0
    private var consecutiveOnSamples: Int = 0
    private var consecutiveOffSamples: Int = 0
    private var estimatedDotDuration: TimeInterval = 0
    private var recentOnDurations: [TimeInterval] = []

    // MARK: - Sending History
    @Published var sendHistory: [MorseMessage] = []
    @Published var receiveHistory: [MorseMessage] = []

    private var sendTask: Task<Void, Never>?
    private var flashEvents: [MorseCode.FlashEvent] = []
    private var flashEventToMorseIndex: [Int?] = []
    private let soundService = MorseSoundService()

    // MARK: - Sending

    func updateMorseRepresentation() {
        morseRepresentation = MorseCode.encode(inputText)
    }

    var sendingMorseRepresentation: String {
        guard !morseRepresentation.isEmpty else { return "" }
        if sendWithPreamble {
            return Self.preamblePattern + " " + morseRepresentation
        }
        return morseRepresentation
    }

    func startSending(using flashlightService: FlashlightService) {
        guard !inputText.isEmpty else { return }

        updateMorseRepresentation()
        let timing = MorseCode.Timing(wpm: sendingSpeed)
        
        // Build full sequence: optional preamble + letter gap + message
        let fullMorse = sendingMorseRepresentation
        flashEvents = MorseCode.toFlashSequence(fullMorse, timing: timing)
        flashEventToMorseIndex = buildFlashEventMapping(for: fullMorse, events: flashEvents)
        isSending = true
        currentSendIndex = 0
        currentSendElementIndex = flashEventToMorseIndex.first ?? nil
        currentLoopCount = 0

        // Set brightness to max for morse signaling
        let previousBrightness = flashlightService.brightness
        flashlightService.lockBrightnessToMax()

        sendTask = Task {
            repeat {
                currentLoopCount += 1
                
                for (index, event) in flashEvents.enumerated() {
                    if Task.isCancelled { break }
                    currentSendIndex = index
                    currentSendElementIndex = flashEventToMorseIndex[index]

                    switch event {
                    case .on(let duration):
                        flashlightService.turnOn()
                        if sendWithSound {
                            soundService.playTone(duration: duration)
                        }
                        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                    case .pause(let duration):
                        flashlightService.turnOff()
                        if sendWithSound {
                            soundService.stop()
                        }
                        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                    }
                }
                
                // Add a word gap pause between loops
                if loopSending && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(timing.wordGap * 1_000_000_000))
                }
            } while loopSending && !Task.isCancelled

            flashlightService.turnOff()
            soundService.stop()
            flashlightService.unlockBrightness()
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
            currentSendElementIndex = nil
            currentLoopCount = 0
        }
    }

    func stopSending(using flashlightService: FlashlightService) {
        sendTask?.cancel()
        sendTask = nil
        flashlightService.turnOff()
        soundService.stop()
        flashlightService.unlockBrightness()
        isSending = false
        currentSendIndex = 0
        currentSendElementIndex = nil
        currentLoopCount = 0
    }

    func resetSending(using flashlightService: FlashlightService) {
        stopSending(using: flashlightService)
        sendingSpeed = 5
    }

    var sendProgress: Double {
        guard isSending, !flashEvents.isEmpty else { return 0 }
        let progress = Double(currentSendIndex + 1) / Double(flashEvents.count)
        return min(1, max(0, progress))
    }

    private func buildFlashEventMapping(for morse: String, events: [MorseCode.FlashEvent]) -> [Int?] {
        let elementIndices = morseElementIndices(for: morse)
        var mapping: [Int?] = []
        mapping.reserveCapacity(events.count)
        var onIndex = 0
        for event in events {
            if event.isOn {
                if onIndex < elementIndices.count {
                    mapping.append(elementIndices[onIndex])
                } else {
                    mapping.append(nil)
                }
                onIndex += 1
            } else {
                mapping.append(nil)
            }
        }
        return mapping
    }

    private func morseElementIndices(for morse: String) -> [Int] {
        var indices: [Int] = []
        indices.reserveCapacity(morse.count)
        var currentIndex = 0
        for char in morse {
            switch char {
            case ".", "-":
                indices.append(currentIndex)
                currentIndex += 1
            case " ", "/":
                currentIndex += 1
            default:
                break
            }
        }
        return indices
    }

    // MARK: - Receiving / Decoding

    /// Called by the camera service when light level changes
    func updateLightLevel(_ level: Double) {
        // Smooth the incoming signal to reduce flicker noise, with faster rise time.
        if smoothedLevel == 0 {
            smoothedLevel = level
            ambientLevel = level
            emaMean = level
            emaVariance = 0
        } else {
            let riseFactor = 0.5
            let fallFactor = 0.25
            let alpha = level > smoothedLevel ? riseFactor : fallFactor
            smoothedLevel = smoothedLevel * (1.0 - alpha) + level * alpha
        }

        currentBrightnessLevel = smoothedLevel
        let wasDetected = lightDetected

        // Update ambient and noise estimates with EMA.
        ambientLevel = ambientLevel * 0.98 + smoothedLevel * 0.02
        let meanAlpha = 0.05
        let delta = smoothedLevel - emaMean
        emaMean = emaMean + meanAlpha * delta
        emaVariance = (1.0 - meanAlpha) * (emaVariance + meanAlpha * delta * delta)
        let std = max(0.01, sqrt(emaVariance))

        let sensitivity = clamp(detectionThreshold, min: 0.1, max: 0.9)
        let baseDelta = 0.02 + (0.25 * sensitivity)
        let k = autoSensitivity ? (1.2 + (0.8 * sensitivity)) : 10.0
        let adaptiveOn = emaMean + k * std
        let adaptiveOff = emaMean + (k * 0.6) * std

        let onThreshold = max(ambientLevel + baseDelta, adaptiveOn)
        let offThreshold = max(ambientLevel + baseDelta * 0.7, adaptiveOff)

        if smoothedLevel > onThreshold {
            consecutiveOnSamples += 1
            consecutiveOffSamples = 0
        } else if smoothedLevel < offThreshold {
            consecutiveOffSamples += 1
            consecutiveOnSamples = 0
        }

        let requiredStableSamples = 1
        if !wasDetected && consecutiveOnSamples >= requiredStableSamples {
            lightDetected = true
        } else if wasDetected && consecutiveOffSamples >= requiredStableSamples {
            lightDetected = false
        }

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

        let dotDuration = currentDotDuration()
        let threshold = dotDuration * 2.0
        let minPulse = max(0.02, dotDuration * 0.3)

        // Ignore very short pulses as noise.
        if duration < minPulse {
            return
        }

        updateEstimatedDotDuration(using: duration)

        let signal: MorseSignal
        let symbol: String
        if duration < threshold {
            signal = MorseSignal(type: .dot, duration: duration, timestamp: Date())
            symbol = "."
        } else {
            signal = MorseSignal(type: .dash, duration: duration, timestamp: Date())
            symbol = "-"
        }
        receivedSignals.append(signal)

        let wasPreambleDetected = preambleDetected

        // In dedicated mode, buffer until preamble is found
        if dedicatedSourceMode && !preambleDetected {
            rawDetectedMorse += symbol
            checkForPreamble()
            if !preambleDetected {
                return
            }
        }

        if !dedicatedSourceMode || wasPreambleDetected {
            detectedMorse += symbol
        }

        // Start gap timer to detect letter/word gaps
        if !dedicatedSourceMode || wasPreambleDetected {
            startGapTimer()
        }
    }
    
    private func checkForPreamble() {
        // Look for the preamble pattern in the raw buffer
        if rawDetectedMorse.contains(Self.preamblePattern) {
            preambleDetected = true
            // Extract everything after the preamble
            if let range = rawDetectedMorse.range(of: Self.preamblePattern) {
                let afterPreamble = String(rawDetectedMorse[range.upperBound...])
                detectedMorse = afterPreamble
            }
            rawDetectedMorse = ""
        }
        
        // Keep buffer from growing too large (preamble is 5 chars, keep some margin)
        if rawDetectedMorse.count > 20 {
            rawDetectedMorse = String(rawDetectedMorse.suffix(10))
        }
    }

    private func startGapTimer() {
        gapTimer?.cancel()
        let dotDuration = currentDotDuration()
        let letterGap = dotDuration * 3
        let wordGap = dotDuration * 7

        gapTimer = Task {
            // Wait for letter gap duration
            try? await Task.sleep(nanoseconds: UInt64(letterGap * 1.5 * 1_000_000_000))
            if Task.isCancelled { return }

            // This is at least a letter gap — add space
            detectedMorse += " "
            tryDecode()

            // Wait more for word gap
            try? await Task.sleep(nanoseconds: UInt64((wordGap - letterGap) * 1.5 * 1_000_000_000))
            if Task.isCancelled { return }

            // This is a word gap
            detectedMorse += "/ "
        }
    }

    private func tryDecode() {
        decodedText = MorseCode.decode(detectedMorse.trimmingCharacters(in: .whitespaces))
    }

    private func currentDotDuration() -> TimeInterval {
        let baseDot = MorseCode.Timing(wpm: sendingSpeed).dotDuration
        if estimatedDotDuration > 0 {
            return min(max(estimatedDotDuration, baseDot * 0.5), baseDot * 2.5)
        }
        return baseDot
    }

    private func clamp(_ value: Double, min: Double, max: Double) -> Double {
        return Swift.max(min, Swift.min(max, value))
    }

    private func updateEstimatedDotDuration(using duration: TimeInterval) {
        recentOnDurations.append(duration)
        if recentOnDurations.count > 20 {
            recentOnDurations.removeFirst(recentOnDurations.count - 20)
        }

        let sorted = recentOnDurations.sorted()
        let sampleCount = max(1, sorted.count / 2)
        let dotCandidates = sorted.prefix(sampleCount)
        let medianIndex = dotCandidates.index(dotCandidates.startIndex, offsetBy: dotCandidates.count / 2)
        let median = dotCandidates[medianIndex]

        estimatedDotDuration = min(max(median, 0.03), 1.0)
    }

    func startReceiving() {
        isReceiving = true
        resetReceivingState()
        estimatedDotDuration = MorseCode.Timing(wpm: sendingSpeed).dotDuration
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
        resetReceivingState()
    }

    func resetReceivingState() {
        gapTimer?.cancel()
        detectedMorse = ""
        decodedText = ""
        receivedSignals = []
        rawDetectedMorse = ""
        preambleDetected = !dedicatedSourceMode
        lightDetected = false
        currentBrightnessLevel = 0
        ambientLevel = 0
        smoothedLevel = 0
        emaMean = 0
        emaVariance = 0
        consecutiveOnSamples = 0
        consecutiveOffSamples = 0
        estimatedDotDuration = 0
        recentOnDurations = []
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
