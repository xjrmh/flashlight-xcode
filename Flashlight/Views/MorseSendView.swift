import SwiftUI
import UIKit

struct MorseSendView: View {
    @EnvironmentObject var flashlight: FlashlightService
    @EnvironmentObject var morseEngine: MorseCodeEngine

    @State private var showHistory = false
    @State private var hasPrewarmedKeyboard = false

    var body: some View {
        ZStack {
            // Background
            Color.black.ignoresSafeArea()
                .onTapGesture {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            
            // Hidden keyboard pre-warmer
            if !hasPrewarmedKeyboard {
                KeyboardPrewarmer {
                    hasPrewarmedKeyboard = true
                }
            }

            GeometryReader { geometry in
                let isCompact = geometry.size.width < 600

                if isCompact {
                    VStack(spacing: 0) {
                        headerSection
                            .padding(.horizontal, 20)
                            .padding(.top, 20)
                            .padding(.bottom, 12)

                        ScrollView {
                            VStack(spacing: 24) {
                                inputSection
                                morsePreviewSection
                                speedControlSection
                                sendControlSection
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 20)
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        headerSection
                            .padding(.horizontal, 32)
                            .padding(.top, 24)
                            .padding(.bottom, 12)

                        ScrollView {
                            HStack(alignment: .top, spacing: 24) {
                                VStack(spacing: 24) {
                                    inputSection
                                    morsePreviewSection
                                }
                                .frame(maxWidth: .infinity)

                                VStack(spacing: 24) {
                                    speedControlSection
                                    sendControlSection
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .padding(.horizontal, 32)
                            .padding(.bottom, 32)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showHistory) {
            SendHistorySheet(history: morseEngine.sendHistory)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Send Morse")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)

                Text("Type a message and flash it with your torch")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            LiquidGlassButton(
                title: nil,
                icon: "clock.arrow.circlepath",
                isActive: showHistory
            ) {
                withAnimation(.spring(response: 0.3)) {
                    showHistory.toggle()
                }
            }
        }
    }

    // MARK: - Input

    private var inputSection: some View {
        LiquidGlassCard(cornerRadius: 20, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("MESSAGE")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.4))

                TextField("Enter text to send...", text: $morseEngine.inputText)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .tint(.cyan)
                    .submitLabel(.send)
                    .onSubmit {
                        if !morseEngine.inputText.isEmpty && !morseEngine.isSending {
                            morseEngine.startSending(using: flashlight)
                        }
                    }
                    .onChange(of: morseEngine.inputText) { _, _ in
                        morseEngine.updateMorseRepresentation()
                    }
                    .disabled(morseEngine.isSending)

                // Character count
                HStack {
                    Spacer()
                    Text("\(morseEngine.inputText.count) characters")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
        }
    }

    // MARK: - Morse Preview

    private var morsePreviewSection: some View {
        LiquidGlassCard(cornerRadius: 20, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("MORSE CODE")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(.white.opacity(0.4))

                    Spacer()

                    if !morseEngine.sendingMorseRepresentation.isEmpty {
                        Button {
                            UIPasteboard.general.string = morseEngine.sendingMorseRepresentation
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .buttonStyle(HapticButtonStyle())
                    }
                }

                if morseEngine.sendingMorseRepresentation.isEmpty {
                    Text("Type a message above to see morse code")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.3))
                } else {
                    // Visual morse display
                    MorseVisualizer(
                        morse: morseEngine.sendingMorseRepresentation,
                        highlightedIndex: morseEngine.isSending ? morseEngine.currentSendElementIndex : nil
                    )

                    // Text morse display
                    Text(morseEngine.sendingMorseRepresentation)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(.cyan.opacity(0.8))
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Speed Control

    private var speedControlSection: some View {
        LiquidGlassCard(cornerRadius: 20, padding: 16) {
            VStack(spacing: 16) {
                LiquidGlassSlider(
                    value: $morseEngine.sendingSpeed,
                    range: 5...30,
                    label: "Speed",
                    icon: "gauge.medium",
                    accentColor: .orange,
                    showPercentage: false
                )

                HStack {
                    Text("\(Int(morseEngine.sendingSpeed)) WPM")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.orange)

                    Spacer()

                    Text(speedLabel)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.4))
                }
                
                Divider().background(Color.white.opacity(0.1))
                
                // Sound toggle
                HStack {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(morseEngine.sendWithSound ? .cyan : .white.opacity(0.6))
                        .frame(width: 24)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Send With Sound")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                        
                        Text(morseEngine.sendWithSound ? "Plays a tone while flashing" : "Light only")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $morseEngine.sendWithSound)
                        .labelsHidden()
                        .tint(.cyan)
                }
                
                Divider().background(Color.white.opacity(0.1))

                // Prefix toggle
                HStack {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 14))
                        .foregroundStyle(morseEngine.sendWithPreamble ? .cyan : .white.opacity(0.6))
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Send With Prefix")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)

                        Text(morseEngine.sendWithPreamble ? "Adds sync pattern before message" : "No sync pattern")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.4))
                    }

                    Spacer()

                    Toggle("", isOn: $morseEngine.sendWithPreamble)
                        .labelsHidden()
                        .tint(.cyan)
                }

                Divider().background(Color.white.opacity(0.1))

                // Loop toggle
                HStack {
                    Image(systemName: "repeat")
                        .font(.system(size: 14))
                        .foregroundStyle(morseEngine.loopSending ? .cyan : .white.opacity(0.6))
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Loop Message")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)

                        Text(morseEngine.loopSending ? "Repeats until stopped" : "Send once")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.4))
                    }

                    Spacer()

                    if morseEngine.isSending && morseEngine.loopSending {
                        Text("×\(morseEngine.currentLoopCount)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.cyan)
                            .padding(.trailing, 8)
                    }

                    Toggle("", isOn: $morseEngine.loopSending)
                        .labelsHidden()
                        .tint(.cyan)
                }
            }
        }
    }

    private var speedLabel: String {
        switch morseEngine.sendingSpeed {
        case 0..<10: return "Beginner"
        case 10..<18: return "Standard"
        case 18..<25: return "Advanced"
        default: return "Expert"
        }
    }

    // MARK: - Send Control

    private var sendControlSection: some View {
        VStack(spacing: 16) {
            if morseEngine.isSending {
                // Progress bar
                LiquidGlassCard(cornerRadius: 16, padding: 12) {
                    VStack(spacing: 8) {
                        HStack {
                            Text("Transmitting...")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                            Spacer()
                            Text("\(Int(morseEngine.sendProgress * 100))%")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundStyle(.cyan)
                        }

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.1))
                                    .frame(height: 4)

                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [.cyan, .white],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(
                                        width: geo.size.width * morseEngine.sendProgress,
                                        height: 4
                                    )
                                    .animation(.linear(duration: 0.1), value: morseEngine.sendProgress)
                            }
                        }
                        .frame(height: 4)
                    }
                }
            }

            // Send / Stop button
            Button {
                if morseEngine.isSending {
                    morseEngine.stopSending(using: flashlight)
                } else {
                    morseEngine.startSending(using: flashlight)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: morseEngine.isSending ? "stop.fill" : "antenna.radiowaves.left.and.right")
                        .font(.system(size: 20, weight: .semibold))

                    Text(morseEngine.isSending ? "Stop Sending" : "Send Morse")
                        .font(.system(size: 18, weight: .bold))
                }
                .foregroundStyle(morseEngine.isSending ? .white : .black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    ZStack {
                        if morseEngine.isSending {
                            Capsule()
                                .fill(.red.opacity(0.8))
                        } else {
                            Capsule()
                                .fill(.white)
                        }
                    }
                )
            }
            .buttonStyle(HapticButtonStyle())
            .disabled(morseEngine.inputText.isEmpty && !morseEngine.isSending)
            .opacity(morseEngine.inputText.isEmpty && !morseEngine.isSending ? 0.4 : 1)

            Button {
                morseEngine.resetSending(using: flashlight)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Reset")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Recommended before transmitting")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                        )
                )
            }
            .buttonStyle(HapticButtonStyle())
        }
    }

}

// MARK: - Send History Sheet

struct SendHistorySheet: View {
    @Environment(\.dismiss) var dismiss
    let history: [MorseMessage]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if history.isEmpty {
                            Text("No messages sent yet")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.3))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 40)
                        } else {
                            ForEach(history) { message in
                                LiquidGlassCard(cornerRadius: 16, padding: 14) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text(message.text)
                                                .font(.system(size: 16, weight: .medium))
                                                .foregroundStyle(.white)
                                            Spacer()
                                            Text(message.formattedTime)
                                                .font(.system(size: 12))
                                                .foregroundStyle(.white.opacity(0.3))
                                        }

                                        HStack {
                                            Text(message.morse)
                                                .font(.system(size: 12, design: .monospaced))
                                                .foregroundStyle(.cyan.opacity(0.6))
                                                .lineLimit(2)
                                            
                                            Spacer()
                                            
                                            Button {
                                                UIPasteboard.general.string = "\(message.text)\n\(message.morse)"
                                                HapticFeedback.impact(.light)
                                            } label: {
                                                Image(systemName: "doc.on.doc")
                                                    .font(.system(size: 14))
                                                    .foregroundStyle(.white.opacity(0.4))
                                            }
                                            .buttonStyle(HapticButtonStyle())
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Send History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.cyan)
                        .buttonStyle(HapticButtonStyle())
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}

// MARK: - Morse Visualizer

struct MorseVisualizer: View {
    let morse: String
    var highlightedIndex: Int?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 3) {
                ForEach(Array(morse.enumerated()), id: \.offset) { index, char in
                    MorseElementView(
                        char: char,
                        isActive: index == (highlightedIndex ?? -1)
                    )
                }
            }
            .padding(.vertical, 8)
        }
    }
}

// Separate view for better performance - avoids recreating all elements
private struct MorseElementView: View {
    let char: Character
    let isActive: Bool
    
    var body: some View {
        switch char {
        case ".":
            RoundedRectangle(cornerRadius: 2)
                .fill(isActive ? Color.white : Color.cyan.opacity(0.6))
                .frame(width: 8, height: 14)
        case "-":
            RoundedRectangle(cornerRadius: 2)
                .fill(isActive ? Color.white : Color.cyan.opacity(0.6))
                .frame(width: 22, height: 14)
        case " ":
            Color.clear.frame(width: 8, height: 14)
        case "/":
            Color.clear.frame(width: 16, height: 14)
        default:
            EmptyView()
        }
    }
}

// MARK: - Keyboard Prewarmer

struct KeyboardPrewarmer: UIViewRepresentable {
    let onComplete: () -> Void
    
    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField()
        textField.alpha = 0
        textField.isUserInteractionEnabled = false
        
        // Pre-warm keyboard on next run loop
        DispatchQueue.main.async {
            textField.becomeFirstResponder()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                textField.resignFirstResponder()
                onComplete()
            }
        }
        
        return textField
    }
    
    func updateUIView(_ uiView: UITextField, context: Context) {}
}

#Preview {
    MorseSendView()
        .environmentObject(FlashlightService())
        .environmentObject(MorseCodeEngine())
}
