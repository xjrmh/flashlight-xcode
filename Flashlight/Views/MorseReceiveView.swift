import SwiftUI
import AVFoundation

struct MorseReceiveView: View {
    @EnvironmentObject var morseEngine: MorseCodeEngine
    @StateObject private var cameraDetector = CameraLightDetector()

    @State private var showHistory = false
    @State private var showSettings = false
    @State private var showPermissionAlert = false
    
    // Replay mode state
    @State private var isInReplayMode = false
    @State private var replayImage: CGImage?
    @State private var roiPosition: CGPoint = CGPoint(x: 0.5, y: 0.5)  // Normalized 0-1
    @State private var isDraggingROI = false

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
        .alert("Camera Access Required", isPresented: $showPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Please enable camera access in Settings to detect morse code signals.")
        }
        .onAppear {
            cameraDetector.checkPermission { granted in
                if granted {
                    cameraDetector.setupCamera()
                    cameraDetector.onBrightnessUpdate = { brightness, timestamp in
                        // Only send updates to engine when actively receiving
                        if morseEngine.isReceiving {
                            morseEngine.updateLightLevel(brightness, timestamp: timestamp)
                        }
                    }
                    // Always start camera feed for preview (but not detection)
                    cameraDetector.start()
                } else if cameraDetector.permissionStatus == .denied {
                    showPermissionAlert = true
                }
            }
        }
        .onChange(of: morseEngine.dedicatedSourceMode) { _, _ in
            morseEngine.resetReceivingState()
        }
        .onDisappear {
            cameraDetector.stop()
            if morseEngine.isReceiving {
                morseEngine.stopReceiving()
            }
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
            // Show replay image or live camera feed
            if isInReplayMode, let cgImage = replayImage {
                GeometryReader { geo in
                    Image(decorative: cgImage, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(Color.orange.opacity(0.5), lineWidth: 2)
                )
            } else {
                // Camera feed
                CameraPreviewView(detector: cameraDetector)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
                    )
            }

            // Dimming overlay with cutout for detection area
            if morseEngine.isReceiving || isInReplayMode {
                GeometryReader { geo in
                    Canvas { context, size in
                        // Fill entire area with semi-transparent black
                        let fullRect = CGRect(origin: .zero, size: size)
                        context.fill(Path(roundedRect: fullRect, cornerRadius: 20), with: .color(.black.opacity(0.6)))
                        
                        // Cut out the ROI square at current position
                        let centerSize: CGFloat = 80
                        let centerX = isInReplayMode ? roiPosition.x * size.width : size.width / 2
                        let centerY = isInReplayMode ? roiPosition.y * size.height : size.height / 2
                        let centerRect = CGRect(
                            x: centerX - centerSize / 2,
                            y: centerY - centerSize / 2,
                            width: centerSize,
                            height: centerSize
                        )
                        context.blendMode = .destinationOut
                        context.fill(Path(roundedRect: centerRect, cornerRadius: 8), with: .color(.white))
                    }
                }
                .allowsHitTesting(false)
            }

            // Draggable ROI overlay for replay mode
            if isInReplayMode {
                GeometryReader { geo in
                    let roiX = roiPosition.x * geo.size.width
                    let roiY = roiPosition.y * geo.size.height
                    
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isDraggingROI ? Color.orange : Color.cyan,
                            style: StrokeStyle(lineWidth: 3)
                        )
                        .frame(width: roiOverlaySize, height: roiOverlaySize)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.cyan.opacity(0.1))
                        )
                        .position(x: roiX, y: roiY)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    isDraggingROI = true
                                    // Update position (clamped to bounds)
                                    let newX = max(0.1, min(0.9, value.location.x / geo.size.width))
                                    let newY = max(0.1, min(0.9, value.location.y / geo.size.height))
                                    roiPosition = CGPoint(x: newX, y: newY)
                                }
                                .onEnded { _ in
                                    isDraggingROI = false
                                    // Reprocess with new ROI position
                                    reprocessWithNewROI()
                                }
                        )
                    
                    // Instruction text
                    VStack {
                        Text("Drag to reposition detection area")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(.black.opacity(0.6)))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                }
            } else {
                // Fixed ROI overlay border (non-replay mode)
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

            // Status overlay only when camera permission denied
            if cameraDetector.permissionStatus == .denied && !isInReplayMode {
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.black.opacity(0.7))

                    VStack(spacing: 12) {
                        Image(systemName: "camera.badge.ellipsis")
                            .font(.system(size: 36))
                            .foregroundStyle(.white.opacity(0.4))
                        
                        Text("Camera access denied")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.5))
                        
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.cyan)
                    }
                }
            }
            
            // "Ready" indicator when camera is on but not detecting
            if cameraDetector.isRunning && !morseEngine.isReceiving && !isInReplayMode && cameraDetector.permissionStatus == .authorized {
                VStack {
                    Spacer()
                    Text("Position camera at light source")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.black.opacity(0.5)))
                        .padding(.bottom, 12)
                }
            }
            
            // Replay mode indicator
            if isInReplayMode {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "play.circle.fill")
                            .foregroundStyle(.orange)
                        Text("REPLAY MODE")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.orange)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.black.opacity(0.7)))
                    .padding(.bottom, 8)
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

                // Detected WPM indicator (shown when we have data)
                if morseEngine.detectedWPM > 0 {
                    HStack {
                        Image(systemName: "gauge.with.dots.needle.67percent")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange.opacity(0.8))
                        
                        Text("\(Int(morseEngine.detectedWPM)) WPM")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.orange)
                        
                        Text("•")
                            .foregroundStyle(.white.opacity(0.3))
                        
                        Text(morseEngine.timingConfidence.rawValue)
                            .font(.system(size: 11))
                            .foregroundStyle(timingConfidenceColor)
                        
                        Spacer()
                    }
                }

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
        if cameraDetector.isCalibrating {
            return "CALIBRATING..."
        }
        if morseEngine.dedicatedSourceMode && !morseEngine.preambleDetected {
            return morseEngine.lightDetected ? "SEARCHING SYNC..." : "WAITING FOR SYNC"
        }
        // Show signal quality when not detecting light
        if !morseEngine.lightDetected {
            return cameraDetector.signalQuality.rawValue.uppercased()
        }
        return "LIGHT DETECTED"
    }
    
    private var signalStatusColor: Color {
        if !morseEngine.isReceiving {
            return .white.opacity(0.4)
        }
        if cameraDetector.isCalibrating {
            return .yellow
        }
        if morseEngine.dedicatedSourceMode && !morseEngine.preambleDetected {
            return morseEngine.lightDetected ? .orange : .yellow.opacity(0.6)
        }
        if morseEngine.lightDetected {
            return .green
        }
        // Color based on signal quality
        switch cameraDetector.signalQuality {
        case .none: return .red.opacity(0.5)
        case .weak: return .orange.opacity(0.6)
        case .good: return .yellow
        case .strong: return .green.opacity(0.7)
        }
    }
    
    private var timingConfidenceColor: Color {
        switch morseEngine.timingConfidence {
        case .learning: return .yellow.opacity(0.6)
        case .low: return .orange.opacity(0.7)
        case .medium: return .green.opacity(0.7)
        case .high: return .green
        }
    }
    
    // MARK: - Button Styling
    
    private var buttonTitle: String {
        if morseEngine.isProcessing {
            return "Analyzing..."
        } else if morseEngine.isReceiving {
            return "Stop"
        } else {
            return "Start Detecting"
        }
    }
    
    private var buttonForegroundColor: Color {
        if morseEngine.isProcessing {
            return .white
        } else if morseEngine.isReceiving {
            return .white
        } else {
            return .black
        }
    }
    
    private var buttonBackgroundColor: Color {
        if morseEngine.isProcessing {
            return .orange.opacity(0.8)
        } else if morseEngine.isReceiving {
            return .red.opacity(0.8)
        } else {
            return .white
        }
    }

    // MARK: - Decoded Section

    private var decodedSection: some View {
        LiquidGlassCard(cornerRadius: 20, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                // Morse code section
                HStack {
                    Text("MORSE CODE")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(.white.opacity(0.4))

                    Spacer()

                    if !morseEngine.detectedMorse.isEmpty {
                        Button {
                            UIPasteboard.general.string = morseEngine.detectedMorse
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12))
                                .foregroundStyle(.cyan.opacity(0.5))
                        }
                        .buttonStyle(HapticButtonStyle())
                    }
                }

                if morseEngine.detectedMorse.isEmpty {
                    Text("Waiting for signal...")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.3))
                } else {
                    Text(morseEngine.detectedMorse)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.cyan.opacity(0.7))
                        .lineLimit(3)
                        .textSelection(.enabled)
                }

                if !morseEngine.decodedText.isEmpty {
                    Divider().background(Color.white.opacity(0.1))

                    // Decoded message section
                    HStack {
                        Text("DECODED MESSAGE")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(2)
                            .foregroundStyle(.white.opacity(0.4))

                        Spacer()

                        Button {
                            UIPasteboard.general.string = morseEngine.decodedText
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .buttonStyle(HapticButtonStyle())
                    }

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
                // Toggle ON = All Light Sources, Toggle OFF = Dedicated Source
                HStack {
                    Image(systemName: morseEngine.dedicatedSourceMode ? "antenna.radiowaves.left.and.right" : "light.max")
                        .font(.system(size: 16))
                        .foregroundStyle(morseEngine.dedicatedSourceMode ? .white.opacity(0.6) : .cyan)
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
                    
                    Toggle("", isOn: Binding(
                        get: { !morseEngine.dedicatedSourceMode },
                        set: { morseEngine.dedicatedSourceMode = !$0 }
                    ))
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

                            Text("Adapts to ambient light conditions")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.4))
                        }

                        Spacer()

                        Toggle("", isOn: $morseEngine.autoSensitivity)
                            .labelsHidden()
                            .tint(.green)
                    }

                    // Only show manual sensitivity slider when auto-sensitivity is OFF
                    if !morseEngine.autoSensitivity {
                        LiquidGlassSlider(
                            value: $morseEngine.detectionThreshold,
                            range: 0.1...0.9,
                            label: "Detection Sensitivity",
                            icon: "waveform.path",
                            accentColor: .green
                        )
                    }
                    
                    Divider().background(Color.white.opacity(0.1))
                    
                    // Auto-detected WPM display
                    HStack {
                        Image(systemName: "gauge.with.dots.needle.67percent")
                            .font(.system(size: 16))
                            .foregroundStyle(.orange)
                            .frame(width: 24)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Detected Speed")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white)
                            
                            Text(morseEngine.timingConfidence.rawValue)
                                .font(.system(size: 11))
                                .foregroundStyle(timingConfidenceColor)
                        }
                        
                        Spacer()
                        
                        if morseEngine.detectedWPM > 0 {
                            Text("\(Int(morseEngine.detectedWPM)) WPM")
                                .font(.system(size: 16, weight: .bold, design: .monospaced))
                                .foregroundStyle(.orange)
                        } else {
                            Text("--")
                                .font(.system(size: 16, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
                    
                    // Gap timing info (debug)
                    if !morseEngine.gapTimingInfo.isEmpty {
                        HStack {
                            Image(systemName: "timer")
                                .font(.system(size: 16))
                                .foregroundStyle(.cyan.opacity(0.7))
                                .frame(width: 24)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Gap Thresholds")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.white)
                                
                                Text(morseEngine.gapTimingInfo)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.cyan.opacity(0.6))
                            }
                            
                            Spacer()
                        }
                    }
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
            // Replay mode: Exit replay button
            if isInReplayMode {
                Button {
                    exitReplayMode()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Exit Replay")
                            .font(.system(size: 16, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        Capsule()
                            .fill(.gray.opacity(0.6))
                    )
                }
                .buttonStyle(HapticButtonStyle())
            } else {
                // Start / Stop / Processing
                Button {
                    if morseEngine.isReceiving && !morseEngine.isProcessing {
                        // Stop and enter replay mode
                        cameraDetector.stopRecording()
                        morseEngine.stopReceiving()
                        if cameraDetector.hasRecording {
                            enterReplayMode()
                        }
                    } else if !morseEngine.isReceiving && !morseEngine.isProcessing {
                        // Start recording
                        cameraDetector.start()
                        cameraDetector.startRecording()
                        morseEngine.startReceiving()
                    }
                } label: {
                    HStack(spacing: 10) {
                        if morseEngine.isProcessing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: morseEngine.isReceiving ? "stop.fill" : "camera.fill")
                                .font(.system(size: 18, weight: .semibold))
                        }

                    Text(buttonTitle)
                        .font(.system(size: 16, weight: .bold))
                }
                .foregroundStyle(buttonForegroundColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    Capsule()
                        .fill(buttonBackgroundColor)
                )
                }
                .buttonStyle(HapticButtonStyle())
                .disabled(morseEngine.isProcessing)
            }

            // Clear button - only show when there's detected morse and not in replay mode
            if !morseEngine.detectedMorse.isEmpty && !isInReplayMode {
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
    
    // MARK: - Replay Mode
    
    private func enterReplayMode() {
        isInReplayMode = true
        roiPosition = CGPoint(x: 0.5, y: 0.5)
        
        // Start replay with first frame
        cameraDetector.startReplay { [self] image, timestamp in
            DispatchQueue.main.async {
                self.replayImage = image
            }
        }
    }
    
    private func exitReplayMode() {
        isInReplayMode = false
        replayImage = nil
        cameraDetector.stopReplay()
        cameraDetector.clearRecording()
        
        // Restart camera preview
        cameraDetector.start()
    }
    
    private func reprocessWithNewROI() {
        // Restart replay from beginning
        cameraDetector.restartReplay { [self] image, timestamp in
            DispatchQueue.main.async {
                self.replayImage = image
            }
        }
        
        // Reprocess all recorded frames with new ROI position
        let results = cameraDetector.reprocessRecording(
            roiCenterX: roiPosition.x,
            roiCenterY: roiPosition.y
        )
        
        // Feed reprocessed data to morse engine
        morseEngine.reprocessFromRecording(brightnessData: results)
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
