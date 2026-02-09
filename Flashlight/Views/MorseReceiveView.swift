import SwiftUI
import AVFoundation

struct MorseReceiveView: View {
    @EnvironmentObject var morseEngine: MorseCodeEngine
    @StateObject private var cameraDetector = CameraLightDetector()

    @State private var showHistory = false
    @State private var showSettings = false

    private let roiOverlaySize: CGFloat = 80

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geometry in
                let isCompact = geometry.size.width < 600

                if isCompact {
                    VStack(spacing: 0) {
                        headerSection
                            .padding(.horizontal, 20)
                            .padding(.top, 20)
                            .padding(.bottom, 12)

                        cameraPreviewSection
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)

                        ScrollView {
                            VStack(spacing: 20) {
                                signalIndicator
                                decodedSection
                                controlsSection
                                settingsSection
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

                        HStack(alignment: .top, spacing: 24) {
                            VStack(spacing: 20) {
                                cameraPreviewSection
                                signalIndicator
                            }
                            .frame(maxWidth: .infinity)

                            ScrollView {
                                VStack(spacing: 20) {
                                    decodedSection
                                    controlsSection
                                    settingsSection
                                }
                                .frame(maxWidth: .infinity, alignment: .top)
                                .padding(.bottom, 32)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .padding(.horizontal, 32)
                        .padding(.bottom, 32)
                    }
                }
            }
        }
        .sheet(isPresented: $showHistory) {
            ReceiveHistorySheet(history: morseEngine.receiveHistory)
        }
        .onAppear {
            cameraDetector.setupCamera()
            cameraDetector.onBrightnessUpdate = { brightness in
                morseEngine.updateLightLevel(brightness)
            }
            // Start detecting by default
            cameraDetector.start()
            morseEngine.startReceiving()
        }
        .onChange(of: morseEngine.dedicatedSourceMode) { _, _ in
            morseEngine.resetReceivingState()
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

            // Dimming overlay with cutout for center detection area (when active)
            if morseEngine.isReceiving {
                Canvas { context, size in
                    // Fill entire area with semi-transparent black
                    let fullRect = CGRect(origin: .zero, size: size)
                    context.fill(Path(roundedRect: fullRect, cornerRadius: 20), with: .color(.black.opacity(0.6)))
                    
                    // Cut out the center square
                    let centerSize: CGFloat = 80
                    let centerRect = CGRect(
                        x: (size.width - centerSize) / 2,
                        y: (size.height - centerSize) / 2,
                        width: centerSize,
                        height: centerSize
                    )
                    context.blendMode = .destinationOut
                    context.fill(Path(roundedRect: centerRect, cornerRadius: 8), with: .color(.white))
                }
                .allowsHitTesting(false)
            }

            // ROI overlay border
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            morseEngine.lightDetected ? Color.green : Color.white.opacity(0.4),
                            style: StrokeStyle(lineWidth: 2, dash: morseEngine.isReceiving ? [] : [8, 4])
                        )
                        .frame(width: roiOverlaySize, height: roiOverlaySize)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(morseEngine.lightDetected ? Color.green.opacity(0.15) : Color.clear)
                        )
                    Spacer()
                }
                Spacer()
            }

            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        updateRoiSize(using: proxy.size)
                    }
                    .onChange(of: proxy.size) { _, newSize in
                        updateRoiSize(using: newSize)
                    }
            }
            .allowsHitTesting(false)

            // Status overlay when not receiving
            if !morseEngine.isReceiving {
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.black.opacity(0.7))

                    Image(systemName: "camera.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.4))
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
                            .fill(signalStatusColor)
                            .frame(width: 8, height: 8)

                        Text(signalStatusText)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(signalStatusColor)
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
    
    private var signalStatusText: String {
        if !morseEngine.isReceiving {
            return "READY"
        }
        if morseEngine.dedicatedSourceMode && !morseEngine.preambleDetected {
            return morseEngine.lightDetected ? "SEARCHING SYNC..." : "WAITING FOR SYNC"
        }
        return morseEngine.lightDetected ? "LIGHT DETECTED" : "NO SIGNAL"
    }
    
    private var signalStatusColor: Color {
        if !morseEngine.isReceiving {
            return .white.opacity(0.4)
        }
        if morseEngine.dedicatedSourceMode && !morseEngine.preambleDetected {
            return morseEngine.lightDetected ? .orange : .yellow.opacity(0.6)
        }
        return morseEngine.lightDetected ? .green : .red.opacity(0.5)
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
                        .buttonStyle(HapticButtonStyle())
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
        LiquidGlassCard(cornerRadius: 20, padding: 16) {
            VStack(spacing: 16) {
                // Source mode toggle (always visible)
                HStack {
                    Image(systemName: morseEngine.dedicatedSourceMode ? "antenna.radiowaves.left.and.right" : "light.max")
                        .font(.system(size: 16))
                        .foregroundStyle(morseEngine.dedicatedSourceMode ? .cyan : .white.opacity(0.6))
                        .frame(width: 24)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(morseEngine.dedicatedSourceMode ? "Dedicated Source" : "All Light Sources")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                        
                        Text(morseEngine.dedicatedSourceMode ? "Waits for sync pattern" : "Decodes any flashing light")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $morseEngine.dedicatedSourceMode)
                        .labelsHidden()
                        .tint(.cyan)
                }

                if showSettings {
                    Divider().background(Color.white.opacity(0.1))

                    HStack {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 16))
                            .foregroundStyle(morseEngine.autoSensitivity ? .green : .white.opacity(0.6))
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto Sensitivity")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white)

                            Text("Keeps threshold within your range")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.4))
                        }

                        Spacer()

                        Toggle("", isOn: $morseEngine.autoSensitivity)
                            .labelsHidden()
                            .tint(.green)
                    }

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

    // MARK: - Controls

    private func updateRoiSize(using size: CGSize) {
        let minSide = max(1, min(size.width, size.height))
        let fraction = max(0.05, min(0.9, roiOverlaySize / minSide))
        cameraDetector.roiSize = fraction
    }

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
            .buttonStyle(HapticButtonStyle())

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
                .buttonStyle(HapticButtonStyle())
            }
        }
    }

}

// MARK: - Camera Preview UIKit Bridge

struct CameraPreviewView: UIViewRepresentable {
    @ObservedObject var detector: CameraLightDetector

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        if let previewLayer = detector.previewLayer {
            uiView.setPreviewLayer(previewLayer)
        }
    }
}

class CameraPreviewUIView: UIView {
    private var previewLayer: AVCaptureVideoPreviewLayer?
    
    func setPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        // Only add if not already added
        if previewLayer !== layer {
            previewLayer?.removeFromSuperlayer()
            previewLayer = layer
            layer.frame = bounds
            layer.videoGravity = .resizeAspectFill
            self.layer.addSublayer(layer)
        }
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
}

// MARK: - Receive History Sheet

struct ReceiveHistorySheet: View {
    @Environment(\.dismiss) var dismiss
    let history: [MorseMessage]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if history.isEmpty {
                            Text("No messages received yet")
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

                                        Text(message.morse)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(.green.opacity(0.6))
                                            .lineLimit(2)
                                    }
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Receive History")
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

#Preview {
    MorseReceiveView()
        .environmentObject(MorseCodeEngine())
}
