import Foundation
import os.log

/// Centralized logging utility for the app
enum Logger {
    /// Log levels matching os.log severity
    enum Level {
        case debug
        case info
        case warning
        case error
        
        fileprivate var osLogType: OSLogType {
            switch self {
            case .debug: return .debug
            case .info: return .info
            case .warning: return .default
            case .error: return .error
            }
        }
    }
    
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.flashlight"
    
    private static let cameraLog = OSLog(subsystem: subsystem, category: "Camera")
    private static let morseLog = OSLog(subsystem: subsystem, category: "Morse")
    private static let flashlightLog = OSLog(subsystem: subsystem, category: "Flashlight")
    private static let generalLog = OSLog(subsystem: subsystem, category: "General")
    
    enum Category {
        case camera
        case morse
        case flashlight
        case general
        
        fileprivate var osLog: OSLog {
            switch self {
            case .camera: return cameraLog
            case .morse: return morseLog
            case .flashlight: return flashlightLog
            case .general: return generalLog
            }
        }
    }
    
    /// Log a message with the specified level and category
    /// - Parameters:
    ///   - message: The message to log
    ///   - level: The severity level (default: .info)
    ///   - category: The log category (default: .general)
    static func log(_ message: String, level: Level = .info, category: Category = .general) {
        os_log("%{public}@", log: category.osLog, type: level.osLogType, message)
        
        #if DEBUG
        let prefix: String
        switch level {
        case .debug: prefix = "🔍"
        case .info: prefix = "ℹ️"
        case .warning: prefix = "⚠️"
        case .error: prefix = "❌"
        }
        print("\(prefix) [\(category)] \(message)")
        #endif
    }
    
    /// Log an error with optional underlying error
    static func logError(_ message: String, error: Error? = nil, category: Category = .general) {
        if let error = error {
            log("\(message): \(error.localizedDescription)", level: .error, category: category)
        } else {
            log(message, level: .error, category: category)
        }
    }
}
