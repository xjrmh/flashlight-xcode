import SwiftUI

/// Handles Morse code receiving and decoding functionality
@MainActor
class MorseReceiver: ObservableObject {
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
    @Published var detectedWPM: Double = 0
    @Published var timingConfidence: MorseTimingAnalyzer.TimingConfidence = .learning
    @Published var gapTimingInfo: String = ""
    @Published var isProcessing: Bool = false
    
    // MARK: - Receive History
    @Published var receiveHistory: [MorseMessage] = [] {
        didSet { saveReceiveHistory() }
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
    private var estimatedDotDuration: TimeInterval = 0.05
    private var lastUpdateTime: CFAbsoluteTime = 0
    
    // MARK: - Signal Sequence
    private var signalSequence: [SignalEvent] = []
    
    // MARK: - Preamble Detection
    private var rawDetectedMorse: String = ""
    
    // MARK: - Debouncing
    private var consecutiveHighSamples: Int = 0
    private var consecutiveLowSamples: Int = 0
    private let minSamplesForTransition = 2
    
    // MARK: - Persistence
    private static let receiveHistoryKey = "MorseReceiver.receiveHistory"
    private static let maxHistoryItems = 100
    
    // Gap detection timer
    private var gapCheckTask: Task<Void, Never>?
    
    init() {
        loadHistory()
    }
    
    // MARK: - Light Level Processing
    
    /// Called by the camera service when light level changes - with high-precision timestamp
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
            let range = max(0.1, signalPeak - noiseFloor)
            let sensitivity = detectionThreshold
            
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
            return level > (adaptiveThreshold - hysteresis)
        } else {
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
                lightDetected = true
                detectorState = .inPulse(startTime: timestamp)
                gapCheckTask?.cancel()
            }
            
        case .inPulse(let startTime):
            if !isHigh && consecutiveLowSamples >= minSamplesForTransition {
                lightDetected = false
                let pulseDuration = timestamp - startTime
                
                let minPulseDuration = max(0.015, estimatedDotDuration * 0.15)
                if pulseDuration >= minPulseDuration {
                    processPulse(duration: pulseDuration)
                }
                
                detectorState = .inGap(startTime: timestamp, lastPulseDuration: pulseDuration)
                startGapMonitoring()
            }
            
        case .inGap(let gapStartTime, _):
            if isHigh && consecutiveHighSamples >= minSamplesForTransition {
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
        let result = MorseTimingAnalyzer.updateTimingEstimates(
            pulseDurations: pulseDurations,
            currentEstimate: estimatedDotDuration
        )
        estimatedDotDuration = result.dotDuration
        timingConfidence = result.confidence
        detectedWPM = result.wpm
        
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
            return
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
    
    private func shouldReclassify(from oldConfidence: MorseTimingAnalyzer.TimingConfidence, to newConfidence: MorseTimingAnalyzer.TimingConfidence) -> Bool {
        let orderedLevels: [MorseTimingAnalyzer.TimingConfidence: Int] = [.learning: 0, .low: 1, .medium: 2, .high: 3]
        guard let oldLevel = orderedLevels[oldConfidence], let newLevel = orderedLevels[newConfidence] else {
            return false
        }
        return oldLevel < 2 && newLevel >= 2
    }
    
    private func reclassifyAllSignals() {
        // Reclassify all received signals with the improved timing estimate
        let threshold = estimatedDotDuration * 2.0
        
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
        
        rebuildMorseFromSignals()
    }
    
    private func rebuildMorseFromSignals() {
        var newMorse = ""
        let pulseThreshold = estimatedDotDuration * 2.0
        
        for event in signalSequence {
            switch event {
            case .pulse(let duration):
                let symbol = duration < pulseThreshold ? "." : "-"
                newMorse += symbol
            case .gap(let duration):
                let gapType = MorseTimingAnalyzer.classifyGap(
                    duration,
                    gapDurations: gapDurations,
                    estimatedDotDuration: estimatedDotDuration
                )
                switch gapType {
                case .word:
                    if !newMorse.isEmpty && !newMorse.hasSuffix(" ") && !newMorse.hasSuffix("/") {
                        newMorse += " / "
                    }
                case .letter:
                    if !newMorse.isEmpty && !newMorse.hasSuffix(" ") && !newMorse.hasSuffix("/") {
                        newMorse += " "
                    }
                case .element:
                    break
                }
            }
        }
        
        // Update receivedSignals to match new classification
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
            if let range = newMorse.range(of: MorseSender.preamblePattern) {
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
        
        tryDecode()
    }
    
    private func processGap(duration: TimeInterval) {
        signalSequence.append(.gap(duration: duration))
        
        gapDurations.append(duration)
        if gapDurations.count > 30 {
            gapDurations.removeFirst()
        }
        
        let letterThreshold = estimatedDotDuration * 1.8
        let wordThreshold = estimatedDotDuration * 5.0
        
        if duration >= wordThreshold {
            if shouldAddSeparator() {
                detectedMorse += " / "
                tryDecode()
            }
        } else if duration >= letterThreshold {
            if shouldAddSeparator() {
                detectedMorse += " "
                tryDecode()
            }
        }
    }
    
    private func startGapMonitoring() {
        gapCheckTask?.cancel()
        
        gapCheckTask = Task { @MainActor in
            let thresholds = MorseTimingAnalyzer.computeGapThresholds(
                gapDurations: gapDurations,
                dotDuration: estimatedDotDuration
            )
            
            do {
                try await Task.sleep(nanoseconds: UInt64(thresholds.letterThreshold * 1_000_000_000))
            } catch {
                Logger.log("Gap monitoring sleep interrupted", level: .debug)
                return
            }
            
            guard !Task.isCancelled else { return }
            guard case .inGap(let gapStartTime, _) = detectorState else { return }
            
            let currentGapDuration = CFAbsoluteTimeGetCurrent() - gapStartTime
            let currentGapType = MorseTimingAnalyzer.classifyGap(
                currentGapDuration,
                gapDurations: gapDurations,
                estimatedDotDuration: estimatedDotDuration
            )
            
            if currentGapType == .letter || currentGapType == .word {
                if shouldAddSeparator() {
                    detectedMorse += " "
                    tryDecode()
                }
            }
            
            let additionalWait = thresholds.wordThreshold - thresholds.letterThreshold
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0.1, additionalWait) * 1_000_000_000))
            } catch {
                Logger.log("Gap word check sleep interrupted", level: .debug)
                return
            }
            
            guard !Task.isCancelled else { return }
            guard case .inGap(let gapStartTime2, _) = detectorState else { return }
            
            let finalGapDuration = CFAbsoluteTimeGetCurrent() - gapStartTime2
            if MorseTimingAnalyzer.classifyGap(finalGapDuration, gapDurations: gapDurations, estimatedDotDuration: estimatedDotDuration) == .word {
                if shouldAddSeparator() {
                    if detectedMorse.hasSuffix(" ") && !detectedMorse.hasSuffix("/ ") {
                        detectedMorse = String(detectedMorse.dropLast()) + " / "
                    }
                }
            }
        }
    }
    
    private func shouldAddSeparator() -> Bool {
        if dedicatedSourceMode && !preambleDetected {
            return false
        }
        guard !detectedMorse.isEmpty else { return false }
        let lastChar = detectedMorse.last
        return lastChar != " " && lastChar != "/"
    }
    
    private func checkForPreamble() {
        if rawDetectedMorse.contains(MorseSender.preamblePattern) {
            preambleDetected = true
            if let range = rawDetectedMorse.range(of: MorseSender.preamblePattern) {
                let afterPreamble = String(rawDetectedMorse[range.upperBound...])
                detectedMorse = afterPreamble
            }
            rawDetectedMorse = ""
        }
        
        if rawDetectedMorse.count > 20 {
            rawDetectedMorse = String(rawDetectedMorse.suffix(10))
        }
    }
    
    private func tryDecode() {
        decodedText = MorseCode.decode(detectedMorse.trimmingCharacters(in: .whitespaces))
    }
    
    // MARK: - Public Methods
    
    func startReceiving() {
        isReceiving = true
        resetReceivingState()
        estimatedDotDuration = 0.05
        detectorState = .waitingForSignal
    }
    
    func stopReceiving() {
        isReceiving = false
        gapCheckTask?.cancel()
        detectorState = .idle
        
        isProcessing = true
        performFinalVerification()
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
    
    func reprocessFromRecording(brightnessData: [(brightness: Double, timestamp: CFAbsoluteTime)]) {
        guard brightnessData.count >= 2 else { return }
        
        isProcessing = true
        
        signalSequence.removeAll()
        pulseDurations.removeAll()
        gapDurations.removeAll()
        receivedSignals.removeAll()
        detectedMorse = ""
        decodedText = ""
        
        detectorState = .waitingForSignal
        consecutiveHighSamples = 0
        consecutiveLowSamples = 0
        
        noiseFloor = 0.05
        signalPeak = 0.5
        thresholdHistory.removeAll()
        
        let wasReceiving = isReceiving
        isReceiving = true
        
        for (brightness, timestamp) in brightnessData {
            updateLightLevel(brightness, timestamp: timestamp)
        }
        
        isReceiving = wasReceiving
        performFinalVerification()
        
        isProcessing = false
        detectorState = .idle
    }
    
    private func performFinalVerification() {
        guard signalSequence.count >= 2 else {
            tryDecode()
            return
        }
        
        let result = MorseTimingAnalyzer.analyzeSignalSequence(
            signalSequence,
            dedicatedSourceMode: dedicatedSourceMode,
            preamblePattern: MorseSender.preamblePattern
        )
        
        estimatedDotDuration = result.dotDuration
        detectedWPM = result.wpm
        timingConfidence = result.confidence
        gapTimingInfo = result.gapInfo
        detectedMorse = result.morse
        receivedSignals = result.signals
        
        tryDecode()
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
        
        noiseFloor = 0.05
        signalPeak = 0.5
        thresholdHistory = []
        
        pulseDurations = []
        gapDurations = []
        signalSequence = []
        estimatedDotDuration = 0.05
        detectedWPM = 0
        timingConfidence = .learning
        
        consecutiveHighSamples = 0
        consecutiveLowSamples = 0
        
        detectorState = isReceiving ? .waitingForSignal : .idle
    }
    
    func clearReceiveHistory() {
        receiveHistory = []
    }
    
    // MARK: - Persistence
    
    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: Self.receiveHistoryKey),
           let decoded = try? JSONDecoder().decode([MorseMessage].self, from: data) {
            receiveHistory = decoded
        }
    }
    
    private func saveReceiveHistory() {
        let trimmedHistory = Array(receiveHistory.prefix(Self.maxHistoryItems))
        if let encoded = try? JSONEncoder().encode(trimmedHistory) {
            UserDefaults.standard.set(encoded, forKey: Self.receiveHistoryKey)
        }
    }
}
