import SwiftUI

struct MorseSendView: View {
    @EnvironmentObject var flashlight: FlashlightService
    @EnvironmentObject var morseEngine: MorseCodeEngine

    @State private var showHistory = false

    var body: some View {
        ZStack {
            // Background
            Color.black.ignoresSafeArea()

            GeometryReader { geometry in
                let isCompact = geometry.size.width < 600

                ScrollView {
                    if isCompact {
                        VStack(spacing: 24) {
                            headerSection
                            inputSection
                            morsePreviewSection
                            speedControlSection
                            sendControlSection
                            if showHistory { historySection }
                        }
                        .padding(20)
                    } else {
                        // iPad: side-by-side
                        HStack(alignment: .top, spacing: 24) {
                            VStack(spacing: 24) {
                                headerSection
                                inputSection
                                morsePreviewSection
                            }
                            .frame(maxWidth: .infinity)

                            VStack(spacing: 24) {
                                speedControlSection
                                sendControlSection
                                if showHistory { historySection }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .padding(32)
                    }
                }
            }
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
                title: "History",
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

                TextField("Enter text to send...", text: $morseEngine.inputText, axis: .vertical)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .tint(.cyan)
                    .lineLimit(4)
                    .onChange(of: morseEngine.inputText) { _, _ in
                        morseEngine.updateMorseRepresentation()
                    }
                    .disabled(morseEngine.isSending)

                // Character count
                HStack {
                    Spacer()
                    Text("\(morseEngine.inputText.count) characters")
                        .font(.system(size: 12, design: .monospaced))
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

                    if !morseEngine.morseRepresentation.isEmpty {
                        Button {
                            UIPasteboard.general.string = morseEngine.morseRepresentation
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }

                if morseEngine.morseRepresentation.isEmpty {
                    Text("Type a message above to see morse code")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.3))
                } else {
                    // Visual morse display
                    MorseVisualizer(
                        morse: morseEngine.morseRepresentation,
                        currentIndex: morseEngine.isSending ? morseEngine.currentSendIndex : nil
                    )

                    // Text morse display
                    Text(morseEngine.morseRepresentation)
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
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
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.orange)

                    Spacer()

                    Text(speedLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
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
            .buttonStyle(.plain)
            .disabled(morseEngine.inputText.isEmpty && !morseEngine.isSending)
            .opacity(morseEngine.inputText.isEmpty && !morseEngine.isSending ? 0.4 : 1)
        }
    }

    // MARK: - History

    private var historySection: some View {
        LiquidGlassCard(cornerRadius: 20, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("SEND HISTORY")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.4))

                if morseEngine.sendHistory.isEmpty {
                    Text("No messages sent yet")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.vertical, 8)
                } else {
                    ForEach(morseEngine.sendHistory) { message in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(message.text)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.white)

                                Text(message.morse)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.cyan.opacity(0.5))
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(message.formattedTime)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        .padding(.vertical, 6)

                        if message.id != morseEngine.sendHistory.last?.id {
                            Divider().background(Color.white.opacity(0.05))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Morse Visualizer

struct MorseVisualizer: View {
    let morse: String
    var currentIndex: Int?

    var body: some View {
        let elements = parseMorse()

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(Array(elements.enumerated()), id: \.offset) { index, element in
                    morseElement(element, isActive: index == (currentIndex ?? -1))
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func parseMorse() -> [MorseElement] {
        var elements: [MorseElement] = []
        for char in morse {
            switch char {
            case ".": elements.append(.dot)
            case "-": elements.append(.dash)
            case " ": elements.append(.letterGap)
            case "/": elements.append(.wordGap)
            default: break
            }
        }
        return elements
    }

    @ViewBuilder
    private func morseElement(_ element: MorseElement, isActive: Bool) -> some View {
        switch element {
        case .dot:
            RoundedRectangle(cornerRadius: 2)
                .fill(isActive ? Color.white : Color.cyan.opacity(0.6))
                .frame(width: 8, height: 14)
                .shadow(color: isActive ? .white.opacity(0.5) : .clear, radius: 4)
        case .dash:
            RoundedRectangle(cornerRadius: 2)
                .fill(isActive ? Color.white : Color.cyan.opacity(0.6))
                .frame(width: 22, height: 14)
                .shadow(color: isActive ? .white.opacity(0.5) : .clear, radius: 4)
        case .letterGap:
            Color.clear.frame(width: 8, height: 14)
        case .wordGap:
            Color.clear.frame(width: 16, height: 14)
        }
    }

    enum MorseElement {
        case dot, dash, letterGap, wordGap
    }
}

#Preview {
    MorseSendView()
        .environmentObject(FlashlightService())
        .environmentObject(MorseCodeEngine())
}
