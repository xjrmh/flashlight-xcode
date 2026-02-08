import SwiftUI

struct FlashlightView: View {
    @EnvironmentObject var flashlight: FlashlightService
    @State private var showPulseRing = false
    @State private var animateGlow = false

    var body: some View {
        ZStack {
            // Dynamic background
            backgroundGradient

            // Main content
            GeometryReader { geometry in
                let isCompact = geometry.size.width < 600

                if isCompact {
                    // iPhone layout — vertical with fixed control panel
                    let controlPanelHeight: CGFloat = 260
                    let bottomPadding: CGFloat = 20
                    let availableHeight = geometry.size.height - controlPanelHeight - bottomPadding - geometry.safeAreaInsets.bottom
                    
                    VStack(spacing: 0) {
                        // Torch visual centered in remaining space
                        torchVisual
                            .frame(height: availableHeight)
                        
                        // Fixed control panel at bottom
                        controlPanel
                            .padding(.horizontal, 24)
                            .padding(.bottom, bottomPadding)
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
        }
    }

    // MARK: - Background

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
                                Color.white.opacity(0.05 * flashlight.brightness),
                                lineWidth: 1
                            )
                            .frame(
                                width: CGFloat(160 + i * 40) * flashlight.beamWidth,
                                height: CGFloat(160 + i * 40) * flashlight.beamWidth
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
                            endRadius: 70 * flashlight.beamWidth
                        )
                    )
                    .frame(width: 150, height: 150)

                // Power button
                LiquidGlassToggle(isOn: $flashlight.isOn, size: 90)
                    .onChange(of: flashlight.isOn) { _, _ in
                        flashlight.applyTorch()
                        showPulseRing = flashlight.isOn
                    }
            }

            // Status text
            Text(flashlight.isOn ? "ON" : "OFF")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .tracking(6)
                .foregroundStyle(flashlight.isOn ? .white : .white.opacity(0.3))
        }
    }

    // MARK: - Control Panel

    private var controlPanel: some View {
        LiquidGlassCard(cornerRadius: 28, padding: 24) {
            VStack(spacing: 24) {
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

                // Beam width slider
                LiquidGlassSlider(
                    value: $flashlight.beamWidth,
                    label: "Beam Width",
                    icon: "light.max",
                    accentColor: .cyan
                )
                .onChange(of: flashlight.beamWidth) { _, newValue in
                    flashlight.setBeamWidth(newValue)
                }

                Divider()
                    .background(Color.white.opacity(0.1))

                // Quick presets
                HStack(spacing: 12) {
                    PresetButton(title: "Low", icon: "sun.min.fill") {
                        withAnimation {
                            flashlight.brightness = 0.25
                            flashlight.beamWidth = 0.5
                            flashlight.applyTorch()
                        }
                    }

                    PresetButton(title: "Medium", icon: "sun.max.fill") {
                        withAnimation {
                            flashlight.brightness = 0.6
                            flashlight.beamWidth = 0.75
                            flashlight.applyTorch()
                        }
                    }

                    PresetButton(title: "Max", icon: "light.max") {
                        withAnimation {
                            flashlight.brightness = 1.0
                            flashlight.beamWidth = 1.0
                            flashlight.applyTorch()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Preset Button

private struct PresetButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.7))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.white.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    FlashlightView()
        .environmentObject(FlashlightService())
        .environmentObject(MorseCodeEngine())
}
