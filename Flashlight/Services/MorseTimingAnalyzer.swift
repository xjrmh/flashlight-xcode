import Foundation

/// Analyzes Morse code timing patterns using k-means clustering
struct MorseTimingAnalyzer {
    
    // MARK: - Types
    
    enum GapType {
        case element  // Gap within a letter (between dots/dashes)
        case letter   // Gap between letters
        case word     // Gap between words
    }
    
    struct GapThresholds {
        let letterThreshold: TimeInterval  // Boundary between element and letter gaps
        let wordThreshold: TimeInterval    // Boundary between letter and word gaps
    }
    
    struct TimingAnalysisResult {
        let dotDuration: TimeInterval
        let dashThreshold: TimeInterval
        let gapThresholds: GapThresholds
        let detectedWPM: Double
        let confidence: TimingConfidence
    }
    
    enum TimingConfidence: String {
        case learning = "Learning..."
        case low = "Low"
        case medium = "Medium"
        case high = "High"
    }
    
    // MARK: - Pulse Analysis
    
    /// Updates timing estimates using k-means clustering on pulse durations
    static func updateTimingEstimates(
        pulseDurations: [TimeInterval],
        currentEstimate: TimeInterval
    ) -> (dotDuration: TimeInterval, confidence: TimingConfidence, wpm: Double) {
        guard pulseDurations.count >= 3 else {
            // Not enough data yet - use a reasonable default
            let defaultDot = currentEstimate > 0 ? currentEstimate : 0.05 // 24 WPM default
            return (defaultDot, .learning, 1.2 / defaultDot)
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
        
        var estimatedDotDuration: TimeInterval
        var confidence: TimingConfidence
        
        // Estimate dot duration - prefer the dot cluster if we have both
        if hasBothClusters && ratio > 1.5 {
            // Clear separation - use dot cluster
            estimatedDotDuration = dotCentroid
            
            // Update confidence
            if pulseDurations.count >= 10 && goodSeparation {
                confidence = .high
            } else if pulseDurations.count >= 5 {
                confidence = .medium
            } else {
                confidence = .low
            }
        } else {
            // No clear separation - use median of shorter half
            let shortHalf = sorted.prefix(sorted.count / 2 + 1)
            estimatedDotDuration = shortHalf[shortHalf.count / 2]
            confidence = pulseDurations.count >= 5 ? .low : .learning
        }
        
        // Clamp to reasonable range (3 WPM to 40 WPM)
        let minDot: TimeInterval = 0.03  // ~40 WPM
        let maxDot: TimeInterval = 0.4   // ~3 WPM
        estimatedDotDuration = max(minDot, min(maxDot, estimatedDotDuration))
        
        // Calculate WPM: Formula: WPM = 1.2 / dotDuration (from MorseCode.Timing)
        let calculatedWPM = 1.2 / estimatedDotDuration
        let wpm = min(40, max(3, calculatedWPM.rounded()))
        
        return (estimatedDotDuration, confidence, wpm)
    }
    
    // MARK: - Gap Classification
    
    /// Classifies a gap duration using adaptive thresholds
    static func classifyGap(
        _ duration: TimeInterval,
        gapDurations: [TimeInterval],
        estimatedDotDuration: TimeInterval
    ) -> GapType {
        // If we have enough gap data, use clustering to find natural boundaries
        if gapDurations.count >= 5 {
            let thresholds = computeGapThresholds(gapDurations: gapDurations, dotDuration: estimatedDotDuration)
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
    
    /// Uses 3-way k-means clustering to find natural gap boundaries
    static func computeGapThresholds(gapDurations: [TimeInterval], dotDuration: TimeInterval) -> GapThresholds {
        let gaps = gapDurations.sorted()
        
        guard gaps.count >= 5 else {
            // Not enough data - use defaults based on dot duration
            return GapThresholds(
                letterThreshold: dotDuration * 2.0,
                wordThreshold: dotDuration * 5.0
            )
        }
        
        // Standard morse timing ratios: element=1, letter=3, word=7 units
        // Initialize 3 centroids based on expected ratios
        var elementCentroid = dotDuration * 1.0
        var letterCentroid = dotDuration * 3.0
        var wordCentroid = dotDuration * 7.0
        
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
        let minLetterThreshold = dotDuration * 1.8
        let minWordThreshold = dotDuration * 4.5
        
        let finalLetterThreshold = max(letterThreshold, minLetterThreshold)
        let finalWordThreshold = max(wordThreshold, minWordThreshold)
        
        return GapThresholds(
            letterThreshold: finalLetterThreshold,
            wordThreshold: finalWordThreshold
        )
    }
    
    // MARK: - Optimal Duration Computation
    
    /// Computes optimal dot duration using k-means clustering on all pulses
    static func computeOptimalDotDuration(from pulses: [TimeInterval]) -> TimeInterval {
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
    
    // MARK: - Full Signal Analysis
    
    /// Performs comprehensive analysis of signal sequence for final verification
    static func analyzeSignalSequence(
        _ sequence: [SignalEvent],
        dedicatedSourceMode: Bool,
        preamblePattern: String
    ) -> (morse: String, signals: [MorseSignal], dotDuration: TimeInterval, wpm: Double, confidence: TimingConfidence, gapInfo: String) {
        
        // Extract all pulse and gap durations from the sequence
        var allPulses: [TimeInterval] = []
        var allGaps: [TimeInterval] = []
        
        for event in sequence {
            switch event {
            case .pulse(let duration):
                allPulses.append(duration)
            case .gap(let duration):
                allGaps.append(duration)
            }
        }
        
        // Need at least one pulse to proceed
        guard !allPulses.isEmpty else {
            return ("", [], 0.1, 12, .learning, "")
        }
        
        // Compute optimal dot duration
        let optimizedDotDuration = computeOptimalDotDuration(from: allPulses)
        let pulseThreshold = optimizedDotDuration * 2.0
        
        // Calculate gap ratios
        let gapRatios = allGaps.map { $0 / optimizedDotDuration }
        let sortedRatios = gapRatios.sorted()
        
        // Find thresholds
        let letterRatioThreshold: Double
        let wordRatioThreshold: Double
        
        if sortedRatios.count >= 2 {
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
            
            if maxJumpRatio > 1.5 {
                letterRatioThreshold = (sortedRatios[jumpIndex] + sortedRatios[min(jumpIndex + 1, sortedRatios.count - 1)]) / 2.0
            } else {
                letterRatioThreshold = 1.8
            }
            wordRatioThreshold = max(5.0, letterRatioThreshold * 2.5)
        } else {
            letterRatioThreshold = 1.8
            wordRatioThreshold = 5.0
        }
        
        // Rebuild morse string using ratio-based classification
        var verifiedMorse = ""
        
        for event in sequence {
            switch event {
            case .pulse(let duration):
                let symbol = duration < pulseThreshold ? "." : "-"
                verifiedMorse += symbol
                
            case .gap(let duration):
                let ratio = duration / optimizedDotDuration
                
                if ratio >= wordRatioThreshold {
                    if !verifiedMorse.isEmpty && !verifiedMorse.hasSuffix(" ") && !verifiedMorse.hasSuffix("/") {
                        verifiedMorse += " / "
                    }
                } else if ratio >= letterRatioThreshold {
                    if !verifiedMorse.isEmpty && !verifiedMorse.hasSuffix(" ") && !verifiedMorse.hasSuffix("/") {
                        verifiedMorse += " "
                    }
                }
            }
        }
        
        // Handle preamble mode
        var finalMorse = verifiedMorse
        if dedicatedSourceMode {
            if let range = verifiedMorse.range(of: preamblePattern) {
                finalMorse = String(verifiedMorse[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        
        // Build signals array
        var newSignals: [MorseSignal] = []
        for event in sequence {
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
        
        // Calculate metrics
        let calculatedWPM = 1.2 / optimizedDotDuration
        let wpm = min(40, max(3, calculatedWPM.rounded()))
        let confidence: TimingConfidence = allPulses.count >= 10 ? .high : (allPulses.count >= 5 ? .medium : .low)
        
        let letterMs = Int(letterRatioThreshold * optimizedDotDuration * 1000)
        let wordMs = Int(wordRatioThreshold * optimizedDotDuration * 1000)
        let gapInfo = "Letter: \(letterMs)ms (\(String(format: "%.1f", letterRatioThreshold))x), Word: \(wordMs)ms"
        
        return (finalMorse, newSignals, optimizedDotDuration, wpm, confidence, gapInfo)
    }
}

// MARK: - Signal Event Type

enum SignalEvent {
    case pulse(duration: TimeInterval)
    case gap(duration: TimeInterval)
}
