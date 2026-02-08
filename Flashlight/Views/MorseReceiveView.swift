import SwiftUI

struct MorseReceiveView: View {
    @EnvironmentObject var morseEngine: MorseCodeEngine
    @StateObject private var cameraDetector = CameraLightDetector()

    @State private var showHistory = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geometry in
                let isCompact = geometry.size.width < 600

                if isCompact {
                    VStack(spacing: 20) {
                        headerSection
                        cameraPreviewSection
                        signalIndicator
                        decodedSection
                        controlsSection
                        if showHistory { historySection }
                    }
                    .padding(20)
                } else {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(spacing: 20) {
                            headerSection
                            cameraPreviewSection
                            signalIndicator
                        }
                        .frame(maxWidth: .infinity)

                        VStack(spacing: 20) {
                            decodedSection
                            settingsSection
                            controlsSection
                            if showHistory { historySection }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(32)
                }
            }
        }
        .onAppear {
            cameraDetector.setupCamera()
            cameraDetector.onBrightnessUpdate = { brightness in
                morseEngine.updateLightLevel(brightness)
            }
        }
        .onDisappear {
            cameraDetector.stop()
            morseEngine.stopReceiving()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Receive Morse")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)

                Text("Point camera at a flashing light source")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            HStack(spacing: 8) {
                LiquidGlassButton(
                    title: nil,
                    icon: "slider.horizontal.3",
                    isActive: showSettings
                ) {
                    withAnimation(.spring(response: 0.3)) {
                        showSettings.toggle()
                    }
                }

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
    }

    // MARK: - Camera Preview

    private var cameraPreviewSection: some View {
        ZStack {
            // Camera feed
            CameraPreviewView(detector: cameraDetector)
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
                )

            // ROI overlay
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            morseEngine.lightDetected ? Color.green : Color.white.opacity(0.4),
                            style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                        )
                        .frame(width: 80, height: 80)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(morseEngine.lightDetected ? Color.green.opacity(0.1) : Color.clear)
                        )
                    Spacer()
                }
                Spacer()
            }

            // Status overlay
            if !cameraDetector.isRunning && !morseEngine.isReceiving {
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.black.opacity(0.7))

                    VStack(spacing: 12) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.white.opacity(0.4))

                        Text("Tap Start to begin detecting")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
        }
        .frame(height: 240)
    }

    // MARK: - Signal Indicator

    private var signalIndicator: some View {
        LiquidGlassCard(cornerRadius: 16, padding: 12) {
            VStack(spacing: 10) {
                HStack {
                    Text("SIGNAL")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(.white.opacity(0.4))

                    Spacer()

                    HStack(spacing: 4) {
                        Circle()
                            .fill(morseEngine.lightDetected ? .green : .red.opacity(0.5))
                            .frame(width: 8, height: 8)

                        Text(morseEngine.lightDetected ? "LIGHT DETECTED" : "NO SIGNAL")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(morseEngine.lightDetected ? .green : .white.opacity(0.4))
                    }
                }

                // Brightness level bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Background track
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 8)

                        // Level fill
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: brightnessGradientColors,
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(
                                width: max(0, geo.size.width * morseEngine.currentBrightnessLevel),
                                height: 8
                            )
                            .animation(.linear(duration: 0.05), value: morseEngine.currentBrightnessLevel)

                        // Threshold marker
                        Rectangle()
                            .fill(.white.opacity(0.6))
                            .frame(width: 2, height: 16)
                            .offset(x: geo.size.width * morseEngine.detectionThreshold - 1)
                    }
                }
                .frame(height: 16)

                // Recent signals visualization
                if !morseEngine.receivedSignals.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 3) {
                            ForEach(morseEngine.receivedSignals.suffix(50)) { signal in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(signal.type == .dot ? Color.green.opacity(0.7) : Color.cyan.opacity(0.7))
                                    .frame(
                                        width: signal.type == .dot ? 6 : 18,
                                        height: 12
                                    )
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private var brightnessGradientColors: [Color] {
        if morseEngine.currentBrightnessLevel > morseEngine.detectionThreshold {
            return [.green.opacity(0.6), .green]
        }
        return [.orange.opacity(0.4), .orange.opacity(0.6)]
    }

    // MARK: - Decoded Section

    private var decodedSection: some View {
        LiquidGlassCard(cornerRadius: 20, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("DECODED MESSAGE")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(.white.opacity(0.4))

                    Spacer()

                    if !morseEngine.decodedText.isEmpty {
                        Button {
                            UIPasteboard.general.string = morseEngine.decodedText
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }

                // Morse code raw
                if morseEngine.detectedMorse.isEmpty {
                    Text("Waiting for signal...")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.3))
                } else {
                    Text(morseEngine.detectedMorse)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.cyan.opacity(0.7))
                        .lineLimit(3)
                }

                if !morseEngine.decodedText.isEmpty {
                    Divider().background(Color.white.opacity(0.1))

                    Text(morseEngine.decodedText)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                }
                
                Spacer(minLength: 0)
            }
            .frame(minHeight: 120)
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        Group {
            if showSettings {
                LiquidGlassCard(cornerRadius: 20, padding: 16) {
                    VStack(spacing: 16) {
                        LiquidGlassSlider(
                            value: $morseEngine.detectionThreshold,
                            range: 0.1...0.9,
                            label: "Detection Threshold",
                            icon: "waveform.path",
                            accentColor: .green
                        )

                        LiquidGlassSlider(
                            value: $morseEngine.sendingSpeed,
                            range: 5...30,
                            label: "Expected Speed (WPM)",
                            icon: "gauge.medium",
                            accentColor: .orange,
                            showPercentage: false
                        )
                    }
                }
            }
        }
    }

    // MARK: - Controls

    private var controlsSection: some View {
        HStack(spacing: 12) {
            // Start / Stop
            Button {
                if morseEngine.isReceiving {
                    cameraDetector.stop()
                    morseEngine.stopReceiving()
                } else {
                    cameraDetector.start()
                    morseEngine.startReceiving()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: morseEngine.isReceiving ? "stop.fill" : "camera.fill")
                        .font(.system(size: 18, weight: .semibold))

                    Text(morseEngine.isReceiving ? "Stop" : "Start Detecting")
                        .font(.system(size: 16, weight: .bold))
                }
                .foregroundStyle(morseEngine.isReceiving ? .white : .black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    Capsule()
                        .fill(morseEngine.isReceiving ? .red.opacity(0.8) : .white)
                )
            }
            .buttonStyle(.plain)

            // Clear
            if !morseEngine.detectedMorse.isEmpty {
                Button {
                    morseEngine.clearReceived()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 52, height: 52)
                        .background(
                            Circle()
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    Circle()
                                        .fill(Color.white.opacity(0.05))
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - History

    private var historySection: some View {
        LiquidGlassCard(cornerRadius: 20, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("RECEIVE HISTORY")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.4))

                if morseEngine.receiveHistory.isEmpty {
                    Text("No messages received yet")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.vertical, 8)
                } else {
                    ForEach(morseEngine.receiveHistory) { message in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(message.text)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.white)

                                Text(message.morse)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.green.opacity(0.5))
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(message.formattedTime)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        .padding(.vertical, 6)

                        if message.id != morseEngine.receiveHistory.last?.id {
                            Divider().background(Color.white.opacity(0.05))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Camera Preview UIKit Bridge

struct CameraPreviewView: UIViewRepresentable {
    let detector: CameraLightDetector

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black

        if let previewLayer = detector.previewLayer {
            previewLayer.frame = view.bounds
            view.layer.addSublayer(previewLayer)
        }

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let previewLayer = detector.previewLayer {
            previewLayer.frame = uiView.bounds
            if previewLayer.superlayer == nil {
                uiView.layer.addSublayer(previewLayer)
            }
        }
    }
}

#Preview {
    MorseReceiveView()
        .environmentObject(MorseCodeEngine())
}
