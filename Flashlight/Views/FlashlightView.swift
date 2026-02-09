import SwiftUI

struct FlashlightView: View {
    @EnvironmentObject var flashlight: FlashlightService
    @State private var showPulseRing = false
    @State private var animateGlow = false
    @State private var isStrobeActive = false
    @State private var strobeIntensity: Double = 0
    @State private var didActivateStrobeDrag = false
    @State private var strobeDragStartedOutside = false
    @State private var powerButtonFrame: CGRect = .zero

    private let strobeControlSize: CGFloat = 320
    
    // Timer state - sliderValue 305 = infinity, 5-300 = actual seconds
    @State private var timerSliderValue: Double = 305 // Max = infinity
    @State private var remainingTime: Double = 0
    @State private var timerTask: Task<Void, Never>?
    
    // Convert slider value to actual duration (0 = infinity internally)
    private var timerDuration: Double {
        timerSliderValue >= 305 ? 0 : timerSliderValue
    }
    
    private var timerLabel: String {
        if timerSliderValue >= 305 {
            return "∞"
        } else if timerSliderValue >= 60 {
            let mins = Int(timerSliderValue) / 60
            let secs = Int(timerSliderValue) % 60
            if secs == 0 {
                return "\(mins)m"
            }
            return "\(mins)m \(secs)s"
        } else {
            return "\(Int(timerSliderValue))s"
        }
    }
    
    private var remainingTimeLabel: String {
        let seconds = Int(remainingTime)
        if seconds >= 60 {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
        return "\(seconds)s"
    }

    var body: some View {
        ZStack {
            // Dynamic background
            backgroundGradient

            // Main content
            GeometryReader { geometry in
                let isCompact = geometry.size.width < 600

                if isCompact {
                    // iPhone layout — vertical with fixed control panel above tab bar
                    VStack(spacing: 0) {
                        // Torch visual centered in remaining space
                        torchVisual
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        
                        // Fixed control panel at bottom, just above tab bar
                        controlPanel
                            .padding(.horizontal, 20)
                            .padding(.bottom, 20)
                    }
                } else {
                    // iPad layout — horizontal split
                    HStack(spacing: 40) {
                        VStack {
                            Spacer()
                            torchVisual
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)

                        VStack {
                            Spacer()
                            controlPanel
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(40)
                }
            }
        }
        .onChange(of: flashlight.isOn) { _, newValue in
            withAnimation(.easeInOut(duration: 0.5)) {
                animateGlow = newValue
            }
            
            // Handle timer
            if newValue && timerDuration > 0 {
                startTimer()
            } else {
                stopTimer()
            }
        }
        .onChange(of: flashlight.isStrobing) { _, isStrobing in
            if !isStrobing {
                isStrobeActive = false
                strobeIntensity = 0
            }
        }
    }
    
    private func startTimer() {
        stopTimer()
        remainingTime = timerDuration
        
        timerTask = Task { @MainActor in
            while remainingTime > 0 && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                if Task.isCancelled { break }
                remainingTime -= 1
            }
            
            if !Task.isCancelled && remainingTime <= 0 {
                flashlight.turnOff()
            }
        }
    }
    
    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
        remainingTime = 0
    }

    private func isPresetSelected(_ value: Double) -> Bool {
        flashlight.isOn && abs(flashlight.brightness - value) <= 0.02
    }

    private func exitStrobeIfNeeded() {
        if isStrobeActive {
            flashlight.stopStrobe()
            isStrobeActive = false
            strobeIntensity = 0
        }
    }

    private func distanceOutsideRect(point: CGPoint, rect: CGRect) -> CGFloat {
        let deadZone: CGFloat = 8
        let expanded = rect.insetBy(dx: -deadZone, dy: -deadZone)
        let dx = max(expanded.minX - point.x, 0, point.x - expanded.maxX)
        let dy = max(expanded.minY - point.y, 0, point.y - expanded.maxY)
        return sqrt(dx * dx + dy * dy)
    }

    private func playStrobeHaptic() {
        HapticFeedback.impact(.light)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 70_000_000)
            HapticFeedback.impact(.light)
        }
    }

    // MARK: - Background

    private var powerToggleBinding: Binding<Bool> {
        Binding(
            get: { flashlight.isOn },
            set: { newValue in
                if isStrobeActive {
                    flashlight.stopStrobe()
                    isStrobeActive = false
                    strobeIntensity = 0
                }
                if newValue {
                    flashlight.turnOn()
                } else {
                    flashlight.turnOff()
                }
            }
        )
    }

    private var backgroundGradient: some View {
        ZStack {
            Color.black

            // Ambient glow when torch is on
            if animateGlow {
                RadialGradient(
                    colors: [
                        Color.white.opacity(0.08 * flashlight.brightness),
                        Color.white.opacity(0.03 * flashlight.brightness),
                        Color.clear,
                    ],
                    center: .center,
                    startRadius: 50,
                    endRadius: 400
                )
                .transition(.opacity)
            }

            // Subtle dark gradient overlay
            LinearGradient(
                colors: [
                    Color.black.opacity(0.3),
                    Color.clear,
                    Color.black.opacity(0.5),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Torch Visual

    private var torchVisual: some View {
        VStack(spacing: 24) {
            // Beam visualization
            ZStack {
                // Outer glow rings
                if flashlight.isOn {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .stroke(
                                (isStrobeActive ? Color.red : Color.white).opacity(0.05 * flashlight.brightness),
                                lineWidth: 1
                            )
                            .frame(
                                width: CGFloat(160 + i * 40),
                                height: CGFloat(160 + i * 40)
                            )
                            .scaleEffect(showPulseRing ? 1.1 : 1.0)
                            .animation(
                                .easeInOut(duration: 2)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.3),
                                value: showPulseRing
                            )
                    }
                }

                // Beam cone visualization
                Circle()
                    .fill(
                        RadialGradient(
                            colors: flashlight.isOn
                                ? [
                                    Color.white.opacity(0.6 * flashlight.brightness),
                                    Color.white.opacity(0.2 * flashlight.brightness),
                                    Color.white.opacity(0.05 * flashlight.brightness),
                                    Color.clear,
                                ]
                                : [
                                    Color.white.opacity(0.05),
                                    Color.clear,
                                ],
                            center: .center,
                            startRadius: 5,
                            endRadius: 70
                        )
                    )
                    .frame(width: 150, height: 150)

                // Power button
                ZStack {
                    LiquidGlassToggle(
                        isOn: powerToggleBinding,
                        size: 90,
                        accentColor: isStrobeActive ? .red : .white,
                        shadowColor: isStrobeActive ? .red : .white
                    )
                        .onChange(of: flashlight.isOn) { _, _ in
                            showPulseRing = flashlight.isOn
                        }
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .preference(key: PowerButtonFrameKey.self, value: proxy.frame(in: .named("strobeButton")))
                            }
                        )

                    if isStrobeActive {
                        VStack(spacing: 6) {
                            Text("STROBE")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .tracking(2)
                                .foregroundStyle(.white.opacity(0.8))

                            Capsule()
                                .fill(Color.white.opacity(0.2))
                                .frame(width: 120, height: 6)
                                .overlay(
                                    Capsule()
                                        .fill(Color.white)
                                        .frame(width: max(8, 120 * strobeIntensity), height: 6)
                                        .animation(.linear(duration: 0.05), value: strobeIntensity)
                                )
                        }
                        .offset(y: -150)
                    }
                }
                .frame(width: strobeControlSize, height: strobeControlSize)
                .contentShape(Rectangle())
                .coordinateSpace(name: "strobeButton")
                .onPreferenceChange(PowerButtonFrameKey.self) { frame in
                    powerButtonFrame = frame
                }
                .highPriorityGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            guard powerButtonFrame != .zero else { return }
                            let startInside = distanceOutsideRect(point: value.startLocation, rect: powerButtonFrame) == 0
                            if isStrobeActive {
                                strobeDragStartedOutside = !startInside
                            } else if !startInside {
                                return
                            }

                            let location = value.location
                            let outsideDistance = distanceOutsideRect(point: location, rect: powerButtonFrame)
                            if outsideDistance > 0 {
                                let normalized = min(1.0, max(0.0, outsideDistance / 120.0))
                                if normalized > 0.05 {
                                    if !isStrobeActive {
                                        isStrobeActive = true
                                        flashlight.startStrobe(intensity: normalized)
                                        playStrobeHaptic()
                                    } else {
                                        flashlight.updateStrobeIntensity(normalized)
                                    }
                                    didActivateStrobeDrag = true
                                    strobeIntensity = normalized
                                }
                            } else if isStrobeActive && !strobeDragStartedOutside {
                                flashlight.stopStrobe()
                                isStrobeActive = false
                                didActivateStrobeDrag = false
                                strobeIntensity = 0
                            }
                        }
                        .onEnded { _ in
                            didActivateStrobeDrag = false
                            strobeDragStartedOutside = false
                        }
                )
            }

        }
    }

    // MARK: - Control Panel

    private var controlPanel: some View {
        LiquidGlassCard(cornerRadius: 28, padding: 24) {
            VStack(spacing: 20) {
                // Brightness slider
                LiquidGlassSlider(
                    value: $flashlight.brightness,
                    label: "Brightness",
                    icon: "sun.max.fill",
                    accentColor: .yellow
                )
                .onChange(of: flashlight.brightness) { _, newValue in
                    flashlight.setBrightness(newValue)
                }

                Divider()
                    .background(Color.white.opacity(0.1))

                // Timer slider
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "timer")
                            .font(.system(size: 14))
                            .foregroundStyle(.cyan)
                        
                        Text("Auto-off Timer")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                        
                        Spacer()
                        
                        if flashlight.isOn && timerDuration > 0 && remainingTime > 0 {
                            Text(remainingTimeLabel)
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundStyle(.cyan)
                        } else {
                            Text(timerLabel)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    
                    // Custom slider: 5-305 where 305 = infinity (rightmost)
                    Slider(value: $timerSliderValue, in: 5...305, step: 5)
                        .tint(.cyan)
                        .onChange(of: timerSliderValue) { _, _ in
                            HapticFeedback.selectionChanged()
                            if timerDuration > 0 {
                                if flashlight.isOn {
                                    startTimer()
                                } else {
                                    flashlight.turnOn()
                                }
                            } else {
                                stopTimer()
                            }
                        }
                    
                    // Timer preset buttons
                    HStack(spacing: 8) {
                        TimerPresetButton(label: "30s", isSelected: timerSliderValue == 30) {
                            timerSliderValue = 30
                        }
                        TimerPresetButton(label: "1m", isSelected: timerSliderValue == 60) {
                            timerSliderValue = 60
                        }
                        TimerPresetButton(label: "5m", isSelected: timerSliderValue == 300) {
                            timerSliderValue = 300
                        }
                        TimerPresetButton(label: "∞", isSelected: timerSliderValue >= 305) {
                            timerSliderValue = 305
                        }
                    }
                }

                Divider()
                    .background(Color.white.opacity(0.1))

                // Quick presets
                HStack(spacing: 12) {
                    PresetButton(
                        title: "Low",
                        icon: "sun.min.fill",
                        isSelected: isPresetSelected(0.25)
                    ) {
                        exitStrobeIfNeeded()
                        withAnimation {
                            flashlight.brightness = 0.25
                            flashlight.turnOn()
                        }
                    }

                    PresetButton(
                        title: "Medium",
                        icon: "sun.max.fill",
                        isSelected: isPresetSelected(0.5)
                    ) {
                        exitStrobeIfNeeded()
                        withAnimation {
                            flashlight.brightness = 0.5
                            flashlight.turnOn()
                        }
                    }

                    PresetButton(
                        title: "Max",
                        icon: "light.max",
                        isSelected: isPresetSelected(1.0)
                    ) {
                        exitStrobeIfNeeded()
                        withAnimation {
                            flashlight.brightness = 1.0
                            flashlight.turnOn()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Timer Preset Button

private struct TimerPresetButton: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(isSelected ? .black : .white.opacity(0.6))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.cyan : Color.white.opacity(0.1))
                )
        }
        .buttonStyle(HapticButtonStyle())
    }
}

// MARK: - Preset Button

private struct PresetButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isSelected ? .black : .white.opacity(0.7))
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.ultraThinMaterial))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.white.opacity(isSelected ? 0.2 : 0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.white.opacity(isSelected ? 0.6 : 0.1), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(HapticButtonStyle())
    }
}

#Preview {
    FlashlightView()
        .environmentObject(FlashlightService())
        .environmentObject(MorseCodeEngine())
}
private struct PowerButtonFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

