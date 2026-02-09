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
    @Published var detectedWPM: Double = 0  // Auto-detected words per minute
    @Published var timingConfidence: TimingConfidence = .learning
    @Published var gapTimingInfo: String = ""  // Debug info for gap detection
    @Published var isProcessing: Bool = false  // True during post-processing verification
    
    enum TimingConfidence: String {
        case learning = "Learning..."
        case low = "Low"
        case medium = "Medium"
        case high = "High"
    }
    
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
    private var estimatedDotDuration: TimeInterval = 0.05 // Start faster (24 WPM), will adapt
    private var lastUpdateTime: CFAbsoluteTime = 0
    
    // MARK: - Signal Sequence (for rebuilding with gaps)
    /// Stores the sequence of pulses and gaps for accurate reconstruction
    private var signalSequence: [SignalEvent] = []
    
    enum SignalEvent {
        case pulse(duration: TimeInterval)
        case gap(duration: TimeInterval)
    }
    
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
                // At 60fps, minimum detectable pulse is ~16ms (1 frame)
                // Be lenient to allow high-speed morse detection
                let minPulseDuration = max(0.015, estimatedDotDuration * 0.15)
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
        // Record pulse event in sequence
        signalSequence.append(.pulse(duration: duration))
        
        // Store duration for adaptive timing
        pulseDurations.append(duration)
        if pulseDurations.count > 20 {
            pulseDurations.removeFirst()
        }
        
        // Track previous confidence to detect improvement
        let previousConfidence = timingConfidence
        
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
        
        // If confidence improved significantly, reclassify all previous signals
        if shouldReclassify(from: previousConfidence, to: timingConfidence) {
            reclassifyAllSignals()
            return // reclassifyAllSignals handles morse string and decoding
        }
        
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
    
    private func shouldReclassify(from oldConfidence: TimingConfidence, to newConfidence: TimingConfidence) -> Bool {
        // Reclassify when we transition from learning/low to medium/high
        let dominated: [TimingConfidence: Int] = [.learning: 0, .low: 1, .medium: 2, .high: 3]
        guard let oldLevel = dominated[oldConfidence], let newLevel = dominated[newConfidence] else {
            return false
        }
        // Reclassify when jumping from learning/low (0-1) to medium/high (2-3)
        return oldLevel < 2 && newLevel >= 2
    }
    
    private func reclassifyAllSignals() {
        // Reclassify all received signals with the improved timing estimate
        let threshold = estimatedDotDuration * 2.0
        
        // Update signal types based on new threshold
        var newSignals: [MorseSignal] = []
        for signal in receivedSignals {
            let isDot = signal.duration < threshold
            let newSignal = MorseSignal(
                type: isDot ? .dot : .dash,
                duration: signal.duration,
                timestamp: signal.timestamp
            )
            newSignals.append(newSignal)
        }
        receivedSignals = newSignals
        
        // Rebuild morse string from reclassified signals
        rebuildMorseFromSignals()
    }
    
    private func rebuildMorseFromSignals() {
        // Rebuild morse string from signal sequence (pulses + gaps)
        var newMorse = ""
        let pulseThreshold = estimatedDotDuration * 2.0
        
        for event in signalSequence {
            switch event {
            case .pulse(let duration):
                let symbol = duration < pulseThreshold ? "." : "-"
                newMorse += symbol
            case .gap(let duration):
                // Use ML-style clustering for gap classification
                let gapType = classifyGap(duration)
                switch gapType {
                case .word:
                    // Word gap
                    if !newMorse.isEmpty && !newMorse.hasSuffix(" ") && !newMorse.hasSuffix("/") {
                        newMorse += " / "
                    }
                case .letter:
                    // Letter gap
                    if !newMorse.isEmpty && !newMorse.hasSuffix(" ") && !newMorse.hasSuffix("/") {
                        newMorse += " "
                    }
                case .element:
                    // Element gaps don't add separators
                    break
                }
            }
        }
        
        // Also update receivedSignals to match new classification
        var newSignals: [MorseSignal] = []
        for event in signalSequence {
            if case .pulse(let duration) = event {
                let isDot = duration < pulseThreshold
                let signal = MorseSignal(
                    type: isDot ? .dot : .dash,
                    duration: duration,
                    timestamp: Date()
                )
                newSignals.append(signal)
            }
        }
        receivedSignals = newSignals
        
        // Handle preamble mode
        if dedicatedSourceMode {
            if let range = newMorse.range(of: Self.preamblePattern) {
                preambleDetected = true
                detectedMorse = String(newMorse[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                rawDetectedMorse = ""
            } else {
                preambleDetected = false
                rawDetectedMorse = newMorse
                detectedMorse = ""
            }
        } else {
            detectedMorse = newMorse
        }
        
        // Re-decode
        tryDecode()
    }
    
    private func processGap(duration: TimeInterval) {
        // Record gap event in sequence - this is the most important part
        // The final verification will use this data to properly classify gaps
        signalSequence.append(.gap(duration: duration))
        
        // Store gap duration for analysis
        gapDurations.append(duration)
        if gapDurations.count > 30 {
            gapDurations.removeFirst()
        }
        
        // During real-time detection, use simple ratio-based classification
        // This gives immediate feedback but may not be accurate
        // The final verification will correct this when user stops
        
        // Use a more lenient threshold for real-time display
        // Standard morse: element=1, letter=3, word=7 units
        // Threshold between element and letter should be ~2 units
        let letterThreshold = estimatedDotDuration * 1.8  // More lenient
        let wordThreshold = estimatedDotDuration * 5.0
        
        if duration >= wordThreshold {
            // Word gap - add word separator
            if shouldAddSeparator() {
                detectedMorse += " / "
                tryDecode()
            }
        } else if duration >= letterThreshold {
            // Letter gap - add space between letters
            if shouldAddSeparator() {
                detectedMorse += " "
                tryDecode()
            }
        }
        // Element gaps don't add separators
    }
    
    private func startGapMonitoring() {
        gapCheckTask?.cancel()
        
        // This monitors for gaps while we're still waiting (no new pulse has arrived)
        // It handles the "end of transmission" case where we need to finalize gaps
        // that haven't been closed by a new pulse yet
        gapCheckTask = Task { @MainActor in
            // Get thresholds from clustering (or fallback to ratio-based)
            let thresholds = computeGapThresholds()
            
            // Wait for letter gap duration
            try? await Task.sleep(nanoseconds: UInt64(thresholds.letterThreshold * 1_000_000_000))
            
            guard !Task.isCancelled else { return }
            guard case .inGap(let gapStartTime, _) = detectorState else { return }
            
            // Still in gap - check current duration
            let currentGapDuration = CFAbsoluteTimeGetCurrent() - gapStartTime
            let currentGapType = classifyGap(currentGapDuration)
            
            // Add letter separator if this is at least a letter gap
            if currentGapType == .letter || currentGapType == .word {
                if shouldAddSeparator() {
                    detectedMorse += " "
                    tryDecode()
                }
            }
            
            // Wait more for word gap
            let additionalWait = thresholds.wordThreshold - thresholds.letterThreshold
            try? await Task.sleep(nanoseconds: UInt64(max(0.1, additionalWait) * 1_000_000_000))
            
            guard !Task.isCancelled else { return }
            guard case .inGap(let gapStartTime2, _) = detectorState else { return }
            
            // Check if this has become a word gap
            let finalGapDuration = CFAbsoluteTimeGetCurrent() - gapStartTime2
            if classifyGap(finalGapDuration) == .word {
                if shouldAddSeparator() {
                    // Replace trailing space with word separator
                    if detectedMorse.hasSuffix(" ") && !detectedMorse.hasSuffix("/ ") {
                        detectedMorse = String(detectedMorse.dropLast()) + " / "
                    }
                }
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
            // Not enough data yet - use a reasonable default
            if estimatedDotDuration == 0 {
                estimatedDotDuration = 0.05 // 24 WPM default - adapts quickly
            }
            timingConfidence = .learning
            return
        }
        
        // K-means clustering to separate dots from dashes
        let sorted = pulseDurations.sorted()
        
        // Initial centroids: shortest for dots, longest for dashes
        var dotCentroid = sorted.first!
        var dashCentroid = sorted.last!
        
        // Iterate to refine centroids
        var finalDotCount = 0
        var finalDashCount = 0
        
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
            
            finalDotCount = dotCount
            finalDashCount = dashCount
        }
        
        // Calculate timing confidence based on cluster separation and sample count
        let ratio = dashCentroid / max(0.001, dotCentroid)
        let hasBothClusters = finalDotCount > 0 && finalDashCount > 0
        let goodSeparation = ratio > 2.0 && ratio < 5.0 // Ideal: dash is 3x dot
        
        // Estimate dot duration - prefer the dot cluster if we have both
        if hasBothClusters && ratio > 1.5 {
            // Clear separation - use dot cluster
            estimatedDotDuration = dotCentroid
            
            // Update confidence
            if pulseDurations.count >= 10 && goodSeparation {
                timingConfidence = .high
            } else if pulseDurations.count >= 5 {
                timingConfidence = .medium
            } else {
                timingConfidence = .low
            }
        } else {
            // No clear separation - use median of shorter half
            let shortHalf = sorted.prefix(sorted.count / 2 + 1)
            estimatedDotDuration = shortHalf[shortHalf.count / 2]
            timingConfidence = pulseDurations.count >= 5 ? .low : .learning
        }
        
        // Clamp to reasonable range (3 WPM to 40 WPM)
        let minDot: TimeInterval = 0.03  // ~40 WPM
        let maxDot: TimeInterval = 0.4   // ~3 WPM
        estimatedDotDuration = max(minDot, min(maxDot, estimatedDotDuration))
        
        // Calculate and publish detected WPM
        // Formula: WPM = 1.2 / dotDuration (from MorseCode.Timing)
        let calculatedWPM = 1.2 / estimatedDotDuration
        detectedWPM = min(40, max(3, calculatedWPM.rounded()))
    }
    
    // MARK: - Gap Classification using Clustering
    
    /// Classifies a gap duration using adaptive thresholds learned from data
    private func classifyGap(_ duration: TimeInterval) -> GapType {
        // If we have enough gap data, use clustering to find natural boundaries
        if gapDurations.count >= 5 {
            let thresholds = computeGapThresholds()
            if duration >= thresholds.wordThreshold {
                return .word
            } else if duration >= thresholds.letterThreshold {
                return .letter
            } else {
                return .element
            }
        }
        
        // Fall back to ratio-based classification using estimated dot duration
        let letterThreshold = estimatedDotDuration * 2.0
        let wordThreshold = estimatedDotDuration * 5.0
        
        if duration >= wordThreshold {
            return .word
        } else if duration >= letterThreshold {
            return .letter
        } else {
            return .element
        }
    }
    
    enum GapType {
        case element  // Gap within a letter (between dots/dashes)
        case letter   // Gap between letters
        case word     // Gap between words
    }
    
    struct GapThresholds {
        let letterThreshold: TimeInterval  // Boundary between element and letter gaps
        let wordThreshold: TimeInterval    // Boundary between letter and word gaps
    }
    
    /// Uses 3-way k-means clustering to find natural gap boundaries
    private func computeGapThresholds() -> GapThresholds {
        let gaps = gapDurations.sorted()
        
        guard gaps.count >= 5 else {
            // Not enough data - use defaults based on dot duration
            return GapThresholds(
                letterThreshold: estimatedDotDuration * 2.0,
                wordThreshold: estimatedDotDuration * 5.0
            )
        }
        
        // Standard morse timing ratios: element=1, letter=3, word=7 units
        // Initialize 3 centroids based on expected ratios
        var elementCentroid = estimatedDotDuration * 1.0
        var letterCentroid = estimatedDotDuration * 3.0
        var wordCentroid = estimatedDotDuration * 7.0
        
        // K-means iterations to find natural clusters
        for _ in 0..<10 {
            var elementSum: TimeInterval = 0, elementCount = 0
            var letterSum: TimeInterval = 0, letterCount = 0
            var wordSum: TimeInterval = 0, wordCount = 0
            
            // Assign each gap to nearest centroid
            for gap in gaps {
                let distToElement = abs(gap - elementCentroid)
                let distToLetter = abs(gap - letterCentroid)
                let distToWord = abs(gap - wordCentroid)
                
                let minDist = min(distToElement, distToLetter, distToWord)
                
                if minDist == distToElement {
                    elementSum += gap
                    elementCount += 1
                } else if minDist == distToLetter {
                    letterSum += gap
                    letterCount += 1
                } else {
                    wordSum += gap
                    wordCount += 1
                }
            }
            
            // Update centroids
            if elementCount > 0 {
                elementCentroid = elementSum / Double(elementCount)
            }
            if letterCount > 0 {
                letterCentroid = letterSum / Double(letterCount)
            }
            if wordCount > 0 {
                wordCentroid = wordSum / Double(wordCount)
            }
            
            // Ensure centroids stay ordered
            if letterCentroid <= elementCentroid {
                letterCentroid = elementCentroid * 2.5
            }
            if wordCentroid <= letterCentroid {
                wordCentroid = letterCentroid * 2.0
            }
        }
        
        // Calculate thresholds as midpoints between cluster centroids
        let letterThreshold = (elementCentroid + letterCentroid) / 2.0
        let wordThreshold = (letterCentroid + wordCentroid) / 2.0
        
        // Apply minimum bounds based on dot duration
        let minLetterThreshold = estimatedDotDuration * 1.8
        let minWordThreshold = estimatedDotDuration * 4.5
        
        let finalLetterThreshold = max(letterThreshold, minLetterThreshold)
        let finalWordThreshold = max(wordThreshold, minWordThreshold)
        
        // Update debug info
        let letterMs = Int(finalLetterThreshold * 1000)
        let wordMs = Int(finalWordThreshold * 1000)
        gapTimingInfo = "Letter: \(letterMs)ms, Word: \(wordMs)ms"
        
        return GapThresholds(
            letterThreshold: finalLetterThreshold,
            wordThreshold: finalWordThreshold
        )
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
        // Start with faster default (24 WPM) - adapts to actual speed
        estimatedDotDuration = 0.05
        detectorState = .waitingForSignal
    }

    func stopReceiving() {
        isReceiving = false
        gapCheckTask?.cancel()
        detectorState = .idle
        
        // Show processing state
        isProcessing = true
        
        // Run post-processing verification with all collected data
        performFinalVerification()
        
        // Done processing
        isProcessing = false

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
    
    // MARK: - Post-Processing Verification
    
    /// Performs comprehensive verification of all detections using complete signal data
    private func performFinalVerification() {
        guard signalSequence.count >= 2 else {
            tryDecode()
            return
        }
        
        // Step 1: Extract all pulse and gap durations from the sequence
        var allPulses: [TimeInterval] = []
        var allGaps: [TimeInterval] = []
        
        for event in signalSequence {
            switch event {
            case .pulse(let duration):
                allPulses.append(duration)
            case .gap(let duration):
                allGaps.append(duration)
            }
        }
        
        // Need at least one pulse to proceed
        guard !allPulses.isEmpty else {
            tryDecode()
            return
        }
        
        // Step 2: Run k-means on pulses to find optimal dot/dash threshold
        let optimizedDotDuration = computeOptimalDotDuration(from: allPulses)
        let pulseThreshold = optimizedDotDuration * 2.0
        
        // Step 3: Classify each gap individually based on context
        // In standard morse: element gap ≈ 1 dot, letter gap ≈ 3 dots, word gap ≈ 7 dots
        // We'll use the ratio of each gap to the dot duration
        
        // Calculate gap ratios (gap / dot duration)
        let gapRatios = allGaps.map { $0 / optimizedDotDuration }
        
        // Find natural clusters in gap ratios
        // Expected: element gaps ~1x, letter gaps ~3x, word gaps ~7x
        let sortedRatios = gapRatios.sorted()
        
        // Use Jenks natural breaks or simple threshold
        // If ratio > 2, it's likely a letter gap
        // If ratio > 5, it's likely a word gap
        let letterRatioThreshold: Double
        let wordRatioThreshold: Double
        
        if sortedRatios.count >= 2 {
            // Find the largest relative jump in sorted ratios
            var maxJumpRatio: Double = 0
            var jumpIndex = 0
            
            for i in 0..<(sortedRatios.count - 1) {
                let currentRatio = sortedRatios[i]
                let nextRatio = sortedRatios[i + 1]
                let jumpRatio = nextRatio / max(0.1, currentRatio)
                
                if jumpRatio > maxJumpRatio {
                    maxJumpRatio = jumpRatio
                    jumpIndex = i
                }
            }
            
            // If there's a significant jump (>1.5x), use it as the letter threshold
            if maxJumpRatio > 1.5 {
                letterRatioThreshold = (sortedRatios[jumpIndex] + sortedRatios[min(jumpIndex + 1, sortedRatios.count - 1)]) / 2.0
            } else {
                // No clear jump - use fixed threshold
                letterRatioThreshold = 1.8
            }
            wordRatioThreshold = max(5.0, letterRatioThreshold * 2.5)
        } else {
            letterRatioThreshold = 1.8
            wordRatioThreshold = 5.0
        }
        
        // Step 4: Rebuild morse string using ratio-based classification
        var verifiedMorse = ""
        var gapIndex = 0
        
        for event in signalSequence {
            switch event {
            case .pulse(let duration):
                let symbol = duration < pulseThreshold ? "." : "-"
                verifiedMorse += symbol
                
            case .gap(let duration):
                let ratio = duration / optimizedDotDuration
                
                if ratio >= wordRatioThreshold {
                    // Word gap
                    if !verifiedMorse.isEmpty && !verifiedMorse.hasSuffix(" ") && !verifiedMorse.hasSuffix("/") {
                        verifiedMorse += " / "
                    }
                } else if ratio >= letterRatioThreshold {
                    // Letter gap
                    if !verifiedMorse.isEmpty && !verifiedMorse.hasSuffix(" ") && !verifiedMorse.hasSuffix("/") {
                        verifiedMorse += " "
                    }
                }
                // Element gaps - no separator needed
            }
        }
        
        // Step 5: Update the detected morse and signals
        estimatedDotDuration = optimizedDotDuration
        
        // Update WPM based on final analysis
        let calculatedWPM = 1.2 / optimizedDotDuration
        detectedWPM = min(40, max(3, calculatedWPM.rounded()))
        timingConfidence = allPulses.count >= 10 ? .high : (allPulses.count >= 5 ? .medium : .low)
        
        // Update gap timing info (using ratio-based thresholds)
        let letterMs = Int(letterRatioThreshold * optimizedDotDuration * 1000)
        let wordMs = Int(wordRatioThreshold * optimizedDotDuration * 1000)
        gapTimingInfo = "Letter: \(letterMs)ms (\(String(format: "%.1f", letterRatioThreshold))x), Word: \(wordMs)ms"
        
        // Handle preamble mode
        if dedicatedSourceMode {
            if let range = verifiedMorse.range(of: Self.preamblePattern) {
                detectedMorse = String(verifiedMorse[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                detectedMorse = verifiedMorse
            }
        } else {
            detectedMorse = verifiedMorse
        }
        
        // Update received signals to match verified classification
        var newSignals: [MorseSignal] = []
        for event in signalSequence {
            if case .pulse(let duration) = event {
                let isDot = duration < pulseThreshold
                let signal = MorseSignal(
                    type: isDot ? .dot : .dash,
                    duration: duration,
                    timestamp: Date()
                )
                newSignals.append(signal)
            }
        }
        receivedSignals = newSignals
        
        // Final decode
        tryDecode()
    }
    
    /// Computes optimal dot duration using k-means clustering on all pulses
    private func computeOptimalDotDuration(from pulses: [TimeInterval]) -> TimeInterval {
        guard !pulses.isEmpty else {
            return 0.1 // Default 12 WPM
        }
        
        guard pulses.count >= 2 else {
            return pulses[0]
        }
        
        let sorted = pulses.sorted()
        
        // Initialize centroids
        var dotCentroid = sorted[0]
        var dashCentroid = sorted[sorted.count - 1]
        
        // K-means iterations
        for _ in 0..<10 {
            var dotSum: TimeInterval = 0, dotCount = 0
            var dashSum: TimeInterval = 0, dashCount = 0
            
            let threshold = (dotCentroid + dashCentroid) / 2
            
            for duration in pulses {
                if duration < threshold {
                    dotSum += duration
                    dotCount += 1
                } else {
                    dashSum += duration
                    dashCount += 1
                }
            }
            
            if dotCount > 0 { dotCentroid = dotSum / Double(dotCount) }
            if dashCount > 0 { dashCentroid = dashSum / Double(dashCount) }
        }
        
        // Verify we have reasonable separation (dash should be ~3x dot)
        let ratio = dashCentroid / max(0.001, dotCentroid)
        if ratio > 1.5 && ratio < 5.0 {
            return dotCentroid
        }
        
        // Fallback: use median of shorter half
        let halfCount = (sorted.count + 1) / 2
        let medianIndex = halfCount / 2
        return sorted[medianIndex]
    }
    
    /// Computes optimal gap thresholds by finding natural breaks in sorted gap data
    private func computeOptimalGapThresholds(from gaps: [TimeInterval], dotDuration: TimeInterval) -> GapThresholds {
        guard gaps.count >= 2 else {
            return GapThresholds(
                letterThreshold: dotDuration * 2.0,
                wordThreshold: dotDuration * 5.0
            )
        }
        
        let sorted = gaps.sorted()
        
        // Find the largest gap (jump) between consecutive sorted values
        // This indicates a natural boundary between gap types
        var maxJump: TimeInterval = 0
        var maxJumpIndex = 0
        var secondMaxJump: TimeInterval = 0
        var secondMaxJumpIndex = 0
        
        for i in 0..<(sorted.count - 1) {
            let jump = sorted[i + 1] - sorted[i]
            // Use relative jump (ratio) to handle different scales
            let relativeJump = jump / max(0.001, sorted[i])
            
            if relativeJump > maxJump / max(0.001, sorted[max(0, maxJumpIndex - 1)]) {
                secondMaxJump = maxJump
                secondMaxJumpIndex = maxJumpIndex
                maxJump = jump
                maxJumpIndex = i
            } else if jump > secondMaxJump {
                secondMaxJump = jump
                secondMaxJumpIndex = i
            }
        }
        
        // Analyze the distribution
        let minGap = sorted[0]
        let maxGap = sorted[sorted.count - 1]
        let range = maxGap - minGap
        
        // If there's significant spread, use the largest jump as letter threshold
        if range > minGap * 1.5 && maxJump > minGap * 0.5 {
            // The jump point is the threshold
            let letterThreshold = (sorted[maxJumpIndex] + sorted[min(maxJumpIndex + 1, sorted.count - 1)]) / 2.0
            
            // Look for a second jump for word threshold
            var wordThreshold = letterThreshold * 2.5
            if secondMaxJumpIndex > maxJumpIndex && secondMaxJump > maxJump * 0.3 {
                wordThreshold = (sorted[secondMaxJumpIndex] + sorted[min(secondMaxJumpIndex + 1, sorted.count - 1)]) / 2.0
            }
            
            return GapThresholds(
                letterThreshold: max(letterThreshold, dotDuration * 1.5),
                wordThreshold: max(wordThreshold, letterThreshold * 1.8)
            )
        }
        
        // Fallback: Use 2-means clustering on gaps
        var shortCentroid = sorted[0]
        var longCentroid = sorted[sorted.count - 1]
        
        for _ in 0..<10 {
            var shortSum: TimeInterval = 0, shortCount = 0
            var longSum: TimeInterval = 0, longCount = 0
            
            let threshold = (shortCentroid + longCentroid) / 2.0
            
            for gap in sorted {
                if gap < threshold {
                    shortSum += gap
                    shortCount += 1
                } else {
                    longSum += gap
                    longCount += 1
                }
            }
            
            if shortCount > 0 { shortCentroid = shortSum / Double(shortCount) }
            if longCount > 0 { longCentroid = longSum / Double(longCount) }
        }
        
        // Letter threshold is between short (element) and long (letter) clusters
        let letterThreshold = (shortCentroid + longCentroid) / 2.0
        let wordThreshold = longCentroid * 2.0
        

        
        return GapThresholds(
            letterThreshold: max(letterThreshold, dotDuration * 1.5),
            wordThreshold: max(wordThreshold, letterThreshold * 1.8)
        )
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
        
        // Reset timing and WPM detection
        pulseDurations = []
        gapDurations = []
        signalSequence = []
        estimatedDotDuration = 0.05 // 24 WPM default - adapts quickly
        detectedWPM = 0
        timingConfidence = .learning
        
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
