import SwiftUI

@main
struct FlashlightApp: App {
    @StateObject private var flashlightService = FlashlightService()
    @StateObject private var morseCodeEngine = MorseCodeEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(flashlightService)
                .environmentObject(morseCodeEngine)
                .preferredColorScheme(.dark)
        }
    }
}
