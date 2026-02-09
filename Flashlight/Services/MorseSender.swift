import SwiftUI

/// Handles Morse code sending functionality
@MainActor
class MorseSender: ObservableObject {
    // MARK: - Preamble Pattern
    /// Unique sync pattern: short-short-long-long-short (distinct from any letter)
    static let preamblePattern = "..--."
    
    // MARK: - Sending State
    @Published var inputText: String = ""
    @Published var morseRepresentation: String = ""
    @Published var isSending: Bool = false
    @Published var currentSendIndex: Int = 0
    @Published var currentSendElementIndex: Int? = nil
    @Published var sendingSpeed: Double = 10 // WPM
    @Published var loopSending: Bool = false
    @Published var currentLoopCount: Int = 0
    @Published var sendWithSound: Bool = false
    @Published var sendWithPreamble: Bool = false
    
    // MARK: - Sending History
    @Published var sendHistory: [MorseMessage] = [] {
        didSet { saveSendHistory() }
    }
    
    // MARK: - Persistence Keys
    private static let sendHistoryKey = "MorseSender.sendHistory"
    private static let maxHistoryItems = 100
    
    private var sendTask: Task<Void, Never>?
    private var flashEvents: [MorseCode.FlashEvent] = []
    private var flashEventToMorseIndex: [Int?] = []
    private let soundService = MorseSoundService()
    
    init() {
        loadHistory()
    }
    
    // MARK: - Public Methods
    
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
        guard !inputText.isEmpty, !isSending else { return }
        
        updateMorseRepresentation()
        let messageText = inputText
        let messageMorse = morseRepresentation
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
        
        sendTask = Task { [messageText, messageMorse] in
            defer {
                flashlightService.turnOff()
                soundService.stop()
                flashlightService.unlockBrightness()
                flashlightService.setBrightness(previousBrightness)
                isSending = false
                currentSendIndex = 0
                currentSendElementIndex = nil
                currentLoopCount = 0
            }
            
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
                        do {
                            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                        } catch {
                            Logger.log("Send sleep interrupted: \(error.localizedDescription)", level: .debug)
                        }
                    case .pause(let duration):
                        flashlightService.turnOff()
                        if sendWithSound {
                            soundService.stop()
                        }
                        do {
                            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                        } catch {
                            Logger.log("Send pause interrupted: \(error.localizedDescription)", level: .debug)
                        }
                    }
                }
                
                // Add a word gap pause between loops
                if loopSending && !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(timing.wordGap * 1_000_000_000))
                    } catch {
                        Logger.log("Loop pause interrupted: \(error.localizedDescription)", level: .debug)
                    }
                }
            } while loopSending && !Task.isCancelled
            
            if Task.isCancelled { return }
            
            let message = MorseMessage(
                text: messageText,
                morse: messageMorse,
                timestamp: Date(),
                direction: .sent
            )
            sendHistory.insert(message, at: 0)
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
        sendingSpeed = 10
    }
    
    var sendProgress: Double {
        guard isSending, !flashEvents.isEmpty else { return 0 }
        let progress = Double(currentSendIndex + 1) / Double(flashEvents.count)
        return min(1, max(0, progress))
    }
    
    func clearSendHistory() {
        sendHistory = []
    }
    
    // MARK: - Private Methods
    
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
    
    // MARK: - Persistence
    
    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: Self.sendHistoryKey),
           let decoded = try? JSONDecoder().decode([MorseMessage].self, from: data) {
            sendHistory = decoded
        }
    }
    
    private func saveSendHistory() {
        let trimmedHistory = Array(sendHistory.prefix(Self.maxHistoryItems))
        if let encoded = try? JSONEncoder().encode(trimmedHistory) {
            UserDefaults.standard.set(encoded, forKey: Self.sendHistoryKey)
        }
    }
}
