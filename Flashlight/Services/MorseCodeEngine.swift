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
    @Published var detectorState: DetectorState = .idle
    
    // MARK: - Detection State Machine
    enum DetectorState: Equatable {
        case idle
        case waitingForSignal
        case inPulse(startTime: CFAbsoluteTime)
        case inGap(startTime: CFAbsoluteTime, lastPulseDuration: TimeInterval)
    }
    
    // MARK: - Adaptive Threshold
    private var adaptiveThreshold: Double = 0.3
    private var noiseFloor: Double = 0.05
    private var signalPeak: Double = 0.5
    private var thresholdHistory: [Double] = []
    private let thresholdHistorySize = 30
    
    // MARK: - Timing Analysis
    private var pulseDurations: [TimeInterval] = []
    private var gapDurations: [TimeInterval] = []
    private var estimatedDotDuration: TimeInterval = 0.08 // Will be updated adaptively
    private var lastUpdateTime: CFAbsoluteTime = 0
    
    // MARK: - Preamble Detection
    private var rawDetectedMorse: String = ""
    
    // MARK: - Debouncing
    private var consecutiveHighSamples: Int = 0
    private var consecutiveLowSamples: Int = 0
    private let minSamplesForTransition = 2 // Require 2 consecutive samples to confirm transition
    
    // MARK: - Sending History
    @Published var sendHistory: [MorseMessage] = []
    @Published var receiveHistory: [MorseMessage] = []

    private var sendTask: Task<Void, Never>?
    private var flashEvents: [MorseCode.FlashEvent] = []
    private var flashEventToMorseIndex: [Int?] = []
    private let soundService = MorseSoundService()
    
    // Gap detection timer
    private var gapCheckTask: Task<Void, Never>?

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

    /// Called by the camera service when light level changes - now with high-precision timestamp
    func updateLightLevel(_ level: Double, timestamp: CFAbsoluteTime) {
        currentBrightnessLevel = level
        lastUpdateTime = timestamp
        
        guard isReceiving else { return }
        
        // Update adaptive threshold
        updateAdaptiveThreshold(level)
        
        // Determine if signal is high or low with hysteresis
        let isHigh = isSignalHigh(level)
        
        // Debounce: require consecutive samples to confirm state change
        if isHigh {
            consecutiveHighSamples += 1
            consecutiveLowSamples = 0
        } else {
            consecutiveLowSamples += 1
            consecutiveHighSamples = 0
        }
        
        // State machine transitions
        processStateMachine(isHigh: isHigh, level: level, timestamp: timestamp)
    }
    
    /// Legacy method for backward compatibility
    func updateLightLevel(_ level: Double) {
        updateLightLevel(level, timestamp: CFAbsoluteTimeGetCurrent())
    }
    
    private func updateAdaptiveThreshold(_ level: Double) {
        // Track noise floor (minimum) and signal peak (maximum)
        if level < noiseFloor * 1.5 || thresholdHistory.count < 10 {
            noiseFloor = noiseFloor * 0.95 + level * 0.05
        }
        if level > signalPeak * 0.7 {
            signalPeak = signalPeak * 0.9 + level * 0.1
        }
        
        // Keep history for statistics
        thresholdHistory.append(level)
        if thresholdHistory.count > thresholdHistorySize {
            thresholdHistory.removeFirst()
        }
        
        if autoSensitivity && thresholdHistory.count >= 10 {
            // Calculate adaptive threshold between noise floor and signal peak
            // Use Schmitt trigger style: different on/off thresholds
            let range = max(0.1, signalPeak - noiseFloor)
            let sensitivity = detectionThreshold // 0.1 (sensitive) to 0.9 (less sensitive)
            
            // Threshold at user-controlled point between noise and signal
            adaptiveThreshold = noiseFloor + range * (0.2 + sensitivity * 0.4)
        } else {
            // Fixed threshold mode
            adaptiveThreshold = detectionThreshold
        }
    }
    
    private func isSignalHigh(_ level: Double) -> Bool {
        // Hysteresis: use different thresholds for on vs off transitions
        let hysteresis = 0.08
        let wasHigh = lightDetected
        
        if wasHigh {
            // Currently high - need to go below lower threshold to turn off
            return level > (adaptiveThreshold - hysteresis)
        } else {
            // Currently low - need to go above upper threshold to turn on
            return level > (adaptiveThreshold + hysteresis)
        }
    }
    
    private func processStateMachine(isHigh: Bool, level: Double, timestamp: CFAbsoluteTime) {
        switch detectorState {
        case .idle:
            if isReceiving {
                detectorState = .waitingForSignal
            }
            
        case .waitingForSignal:
            if isHigh && consecutiveHighSamples >= minSamplesForTransition {
                // Signal detected - start pulse
                lightDetected = true
                detectorState = .inPulse(startTime: timestamp)
                gapCheckTask?.cancel()
            }
            
        case .inPulse(let startTime):
            if !isHigh && consecutiveLowSamples >= minSamplesForTransition {
                // Pulse ended
                lightDetected = false
                let pulseDuration = timestamp - startTime
                
                // Filter out noise pulses (too short)
                let minPulseDuration = estimatedDotDuration * 0.2
                if pulseDuration >= minPulseDuration {
                    processPulse(duration: pulseDuration)
                }
                
                detectorState = .inGap(startTime: timestamp, lastPulseDuration: pulseDuration)
                startGapMonitoring()
            }
            
        case .inGap(let gapStartTime, _):
            if isHigh && consecutiveHighSamples >= minSamplesForTransition {
                // New pulse started
                lightDetected = true
                let gapDuration = timestamp - gapStartTime
                processGap(duration: gapDuration)
                
                detectorState = .inPulse(startTime: timestamp)
                gapCheckTask?.cancel()
            }
        }
    }
    
    private func processPulse(duration: TimeInterval) {
        // Store duration for adaptive timing
        pulseDurations.append(duration)
        if pulseDurations.count > 20 {
            pulseDurations.removeFirst()
        }
        
        // Update estimated dot duration using k-means style clustering
        updateTimingEstimates()
        
        // Classify as dot or dash
        let threshold = estimatedDotDuration * 2.0
        let isDot = duration < threshold
        let symbol = isDot ? "." : "-"
        
        // Create signal record
        let signal = MorseSignal(
            type: isDot ? .dot : .dash,
            duration: duration,
            timestamp: Date()
        )
        receivedSignals.append(signal)
        
        // Handle preamble detection in dedicated mode
        if dedicatedSourceMode && !preambleDetected {
            rawDetectedMorse += symbol
            checkForPreamble()
            if !preambleDetected {
                return
            }
        }
        
        // Add to detected morse
        detectedMorse += symbol
    }
    
    private func processGap(duration: TimeInterval) {
        // Store gap duration
        gapDurations.append(duration)
        if gapDurations.count > 20 {
            gapDurations.removeFirst()
        }
        
        // Don't add separators for element gaps (within a letter)
        // Only letter gaps and word gaps add to the output
    }
    
    private func startGapMonitoring() {
        gapCheckTask?.cancel()
        
        gapCheckTask = Task { @MainActor in
            // Wait for letter gap
            let letterGapDuration = estimatedDotDuration * 3.5
            try? await Task.sleep(nanoseconds: UInt64(letterGapDuration * 1_000_000_000))
            
            guard !Task.isCancelled else { return }
            guard case .inGap = detectorState else { return }
            
            // Letter gap detected - add space
            if shouldAddSeparator() {
                detectedMorse += " "
                tryDecode()
            }
            
            // Wait more for word gap
            let additionalWait = estimatedDotDuration * 4.0 // 7 - 3 = 4 more units
            try? await Task.sleep(nanoseconds: UInt64(additionalWait * 1_000_000_000))
            
            guard !Task.isCancelled else { return }
            guard case .inGap = detectorState else { return }
            
            // Word gap detected - add word separator
            if shouldAddSeparator() {
                detectedMorse += "/ "
            }
        }
    }
    
    private func shouldAddSeparator() -> Bool {
        // Don't add separator if we're in preamble detection mode and haven't found it
        if dedicatedSourceMode && !preambleDetected {
            return false
        }
        // Don't add if morse is empty or already ends with separator
        guard !detectedMorse.isEmpty else { return false }
        let lastChar = detectedMorse.last
        return lastChar != " " && lastChar != "/"
    }
    
    private func updateTimingEstimates() {
        guard pulseDurations.count >= 3 else {
            // Use WPM-based estimate initially
            estimatedDotDuration = MorseCode.Timing(wpm: sendingSpeed).dotDuration
            return
        }
        
        // K-means clustering to separate dots from dashes
        let sorted = pulseDurations.sorted()
        
        // Initial centroids: shortest for dots, longest for dashes
        var dotCentroid = sorted.first!
        var dashCentroid = sorted.last!
        
        // Iterate to refine centroids
        for _ in 0..<5 {
            var dotSum: TimeInterval = 0
            var dotCount = 0
            var dashSum: TimeInterval = 0
            var dashCount = 0
            
            let threshold = (dotCentroid + dashCentroid) / 2
            
            for duration in pulseDurations {
                if duration < threshold {
                    dotSum += duration
                    dotCount += 1
                } else {
                    dashSum += duration
                    dashCount += 1
                }
            }
            
            if dotCount > 0 {
                dotCentroid = dotSum / Double(dotCount)
            }
            if dashCount > 0 {
                dashCentroid = dashSum / Double(dashCount)
            }
        }
        
        // Estimate dot duration - prefer the dot cluster if we have both
        if dashCentroid > dotCentroid * 1.5 {
            // Clear separation - use dot cluster
            estimatedDotDuration = dotCentroid
        } else {
            // No clear separation - use median of shorter half
            let shortHalf = sorted.prefix(sorted.count / 2 + 1)
            estimatedDotDuration = shortHalf[shortHalf.count / 2]
        }
        
        // Clamp to reasonable range
        let minDot: TimeInterval = 0.03
        let maxDot: TimeInterval = 0.5
        estimatedDotDuration = max(minDot, min(maxDot, estimatedDotDuration))
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

    private func tryDecode() {
        decodedText = MorseCode.decode(detectedMorse.trimmingCharacters(in: .whitespaces))
    }

    func startReceiving() {
        isReceiving = true
        resetReceivingState()
        estimatedDotDuration = MorseCode.Timing(wpm: sendingSpeed).dotDuration
        detectorState = .waitingForSignal
    }

    func stopReceiving() {
        isReceiving = false
        gapCheckTask?.cancel()
        detectorState = .idle
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
        if isReceiving {
            detectorState = .waitingForSignal
        }
    }

    func resetReceivingState() {
        gapCheckTask?.cancel()
        detectedMorse = ""
        decodedText = ""
        receivedSignals = []
        rawDetectedMorse = ""
        preambleDetected = !dedicatedSourceMode
        lightDetected = false
        currentBrightnessLevel = 0
        
        // Reset threshold adaptation
        noiseFloor = 0.05
        signalPeak = 0.5
        thresholdHistory = []
        
        // Reset timing
        pulseDurations = []
        gapDurations = []
        estimatedDotDuration = MorseCode.Timing(wpm: sendingSpeed).dotDuration
        
        // Reset debouncing
        consecutiveHighSamples = 0
        consecutiveLowSamples = 0
        
        detectorState = isReceiving ? .waitingForSignal : .idle
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
