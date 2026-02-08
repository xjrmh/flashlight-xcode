import Foundation

/// Morse code mapping and utilities
struct MorseCode {
    /// Standard International Morse Code mapping
    static let characterToMorse: [Character: String] = [
        "A": ".-",    "B": "-...",  "C": "-.-.",  "D": "-..",
        "E": ".",     "F": "..-.",  "G": "--.",   "H": "....",
        "I": "..",    "J": ".---",  "K": "-.-",   "L": ".-..",
        "M": "--",    "N": "-.",    "O": "---",   "P": ".--.",
        "Q": "--.-",  "R": ".-.",   "S": "...",   "T": "-",
        "U": "..-",   "V": "...-",  "W": ".--",   "X": "-..-",
        "Y": "-.--",  "Z": "--..",
        "0": "-----", "1": ".----", "2": "..---", "3": "...--",
        "4": "....-", "5": ".....", "6": "-....", "7": "--...",
        "8": "---..", "9": "----.",
        ".": ".-.-.-", ",": "--..--", "?": "..--..", "'": ".----.",
        "!": "-.-.--", "/": "-..-.",  "(": "-.--.", ")": "-.--.-",
        "&": ".-...",  ":": "---...", ";": "-.-.-.", "=": "-...-",
        "+": ".-.-.",  "-": "-....-", "_": "..--.-", "\"": ".-..-.",
        "$": "...-..-", "@": ".--.-.",
    ]

    /// Reverse mapping: Morse to character
    static let morseToCharacter: [String: Character] = {
        var map: [String: Character] = [:]
        for (char, morse) in characterToMorse {
            map[morse] = char
        }
        return map
    }()

    /// Convert text to morse code string representation
    static func encode(_ text: String) -> String {
        text.uppercased().map { char -> String in
            if char == " " {
                return "/"
            }
            return characterToMorse[char] ?? ""
        }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    /// Decode morse code string to text
    static func decode(_ morse: String) -> String {
        let words = morse.components(separatedBy: " / ")
        return words.map { word in
            word.components(separatedBy: " ").compactMap { code -> String? in
                guard let char = morseToCharacter[code] else { return nil }
                return String(char)
            }.joined()
        }.joined(separator: " ")
    }

    /// Timing constants (in seconds) for morse code transmission
    struct Timing {
        let dotDuration: TimeInterval
        let dashDuration: TimeInterval
        let elementGap: TimeInterval
        let letterGap: TimeInterval
        let wordGap: TimeInterval

        /// Standard timing based on words-per-minute
        init(wpm: Double = 15) {
            let unitDuration = 1.2 / wpm
            self.dotDuration = unitDuration
            self.dashDuration = unitDuration * 3
            self.elementGap = unitDuration
            self.letterGap = unitDuration * 3
            self.wordGap = unitDuration * 7
        }
    }

    /// Convert morse string to a sequence of flash events
    static func toFlashSequence(_ morseString: String, timing: Timing = Timing()) -> [FlashEvent] {
        var events: [FlashEvent] = []

        let letters = morseString.components(separatedBy: " ")
        for (letterIndex, letter) in letters.enumerated() {
            if letter == "/" {
                events.append(.pause(timing.wordGap))
                continue
            }

            for (elementIndex, element) in letter.enumerated() {
                switch element {
                case ".":
                    events.append(.on(timing.dotDuration))
                case "-":
                    events.append(.on(timing.dashDuration))
                default:
                    break
                }

                // Gap between elements within a letter
                if elementIndex < letter.count - 1 {
                    events.append(.pause(timing.elementGap))
                }
            }

            // Gap between letters
            if letterIndex < letters.count - 1 && letters[letterIndex + 1] != "/" {
                events.append(.pause(timing.letterGap))
            }
        }

        return events
    }

    enum FlashEvent {
        case on(TimeInterval)
        case pause(TimeInterval)

        var duration: TimeInterval {
            switch self {
            case .on(let d), .pause(let d): return d
            }
        }

        var isOn: Bool {
            switch self {
            case .on: return true
            case .pause: return false
            }
        }
    }
}
