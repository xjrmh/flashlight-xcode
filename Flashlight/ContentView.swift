import SwiftUI

struct ContentView: View {
    @State private var selectedTab: AppTab = .flashlight

    enum AppTab: String, CaseIterable {
        case flashlight = "Flashlight"
        case morseSend = "Send"
        case morseReceive = "Receive"

        var icon: String {
            switch self {
            case .flashlight: return "flashlight.on.fill"
            case .morseSend: return "ellipsis.message.fill"
            case .morseReceive: return "camera.fill"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            FlashlightView()
                .tabItem {
                    Label(AppTab.flashlight.rawValue, systemImage: AppTab.flashlight.icon)
                }
                .tag(AppTab.flashlight)

            MorseSendView()
                .tabItem {
                    Label(AppTab.morseSend.rawValue, systemImage: AppTab.morseSend.icon)
                }
                .tag(AppTab.morseSend)

            MorseReceiveView()
                .tabItem {
                    Label(AppTab.morseReceive.rawValue, systemImage: AppTab.morseReceive.icon)
                }
                .tag(AppTab.morseReceive)
        }
        .tint(.white)
    }
}

#Preview {
    ContentView()
        .environmentObject(FlashlightService())
        .environmentObject(MorseCodeEngine())
}
