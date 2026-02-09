import SwiftUI
import UIKit

// MARK: - Liquid Glass Background Modifier

struct LiquidGlassBackground: ViewModifier {
    var cornerRadius: CGFloat = 24
    var opacity: Double = 0.15
    var blurRadius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    // Base frosted glass layer
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.ultraThinMaterial)

                    // Glass highlight gradient
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(opacity * 1.5),
                                    Color.white.opacity(opacity * 0.3),
                                    Color.clear,
                                    Color.white.opacity(opacity * 0.2),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    // Inner border for glass edge effect
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.4),
                                    Color.white.opacity(0.1),
                                    Color.white.opacity(0.05),
                                    Color.white.opacity(0.2),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                }
            )
    }
}

// MARK: - Liquid Glass Card

struct LiquidGlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 24
    var padding: CGFloat = 20
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .modifier(LiquidGlassBackground(cornerRadius: cornerRadius))
    }
}

// MARK: - Liquid Glass Button

struct LiquidGlassButton: View {
    let title: String?
    let icon: String?
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                }
                if let title = title {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .foregroundStyle(isActive ? .black : .white)
            .padding(.horizontal, title == nil ? 14 : 20)
            .padding(.vertical, 12)
            .background(
                ZStack {
                    if isActive {
                        Capsule()
                            .fill(.white)
                    } else {
                        Capsule()
                            .fill(.ultraThinMaterial)
                        Capsule()
                            .fill(Color.white.opacity(0.1))
                        Capsule()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.3),
                                        Color.white.opacity(0.1),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.5
                            )
                    }
                }
            )
        }
        .buttonStyle(HapticButtonStyle())
    }
}

// MARK: - Liquid Glass Toggle

struct LiquidGlassToggle: View {
    @Binding var isOn: Bool
    var size: CGFloat = 80
    var accentColor: Color = .white
    var shadowColor: Color = .white
    
    @State private var pressDepth: CGFloat = 0.0  // 0 = not pressed, 1 = fully pressed

    var body: some View {
        let pressScale = 1.0 - (pressDepth * 0.12)
        let innerShadowOpacity = pressDepth * 0.5
        let outerShadowRadius = max(0, 20 - (pressDepth * 18))
        let brightnessAdjust = -pressDepth * 0.15
        
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                isOn.toggle()
            }
        } label: {
            ZStack {
                // Outer ring - base layer
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: size, height: size)

                // Main fill with gradient
                Circle()
                    .fill(
                        RadialGradient(
                            colors: isOn
                                ? [accentColor.opacity(0.9), accentColor.opacity(0.3)]
                                : [Color.white.opacity(0.15), Color.white.opacity(0.05)],
                            center: .center,
                            startRadius: 0,
                            endRadius: size / 2
                        )
                    )
                    .frame(width: size, height: size)
                
                // Inner shadow overlay for pressed depth effect
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.black.opacity(innerShadowOpacity * 0.6),
                                Color.black.opacity(innerShadowOpacity * 0.3),
                                Color.clear
                            ],
                            center: .top,
                            startRadius: 0,
                            endRadius: size * 0.7
                        )
                    )
                    .frame(width: size, height: size)

                // Glass border
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                accentColor.opacity(isOn ? 0.8 : 0.3),
                                accentColor.opacity(isOn ? 0.3 : 0.1),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
                    .frame(width: size, height: size)

                // Power icon
                Image(systemName: "power")
                    .font(.system(size: size * 0.35, weight: .medium))
                    .foregroundStyle(isOn ? .black : .white.opacity(0.7))
                    .scaleEffect(1.0 - (pressDepth * 0.08))
            }
            .brightness(brightnessAdjust)
            .scaleEffect(pressScale)
        }
        .buttonStyle(PressableButtonStyle(pressDepth: $pressDepth))
        .shadow(color: isOn ? shadowColor.opacity(0.4 * (1 - pressDepth)) : .clear, radius: outerShadowRadius)
    }
}

// MARK: - Pressable Button Style

struct PressableButtonStyle: ButtonStyle {
    @Binding var pressDepth: CGFloat
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed {
                    withAnimation(.easeOut(duration: 0.08)) {
                        pressDepth = 0.4
                    }
                    HapticFeedback.impact(.light)
                } else {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) {
                        pressDepth = 0.0
                    }
                }
            }
    }
}

// MARK: - Liquid Glass Slider

struct LiquidGlassSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var label: String
    var icon: String
    var accentColor: Color = .white
    var showPercentage: Bool = true
    @State private var lastHapticStep: Int = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accentColor)

                Text(label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))

                Spacer()

                if showPercentage {
                    let percentage = Int(((value - range.lowerBound) / (range.upperBound - range.lowerBound)) * 100)
                    Text("\(percentage)%")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            // Custom slider track
            GeometryReader { geometry in
                let width = geometry.size.width
                let normalizedValue = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                let thumbX = normalizedValue * Double(width)

                ZStack(alignment: .leading) {
                    // Track background
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .frame(height: 6)

                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 6)

                    // Filled track
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [accentColor.opacity(0.8), accentColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(6, CGFloat(thumbX)), height: 6)

                    // Thumb
                    Circle()
                        .fill(.white)
                        .frame(width: 22, height: 22)
                        .shadow(color: accentColor.opacity(0.3), radius: 6)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5)
                        )
                        .offset(x: max(0, min(CGFloat(thumbX) - 11, CGFloat(width) - 22)))
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let fraction = max(0, min(1, Double(gesture.location.x / width)))
                            value = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
                            let step = Int((fraction * 100.0) / 2.0)
                            if step != lastHapticStep {
                                lastHapticStep = step
                                HapticFeedback.selectionChanged()
                            }
                        }
                )
            }
            .frame(height: 22)
        }
    }
}

// MARK: - Haptics

enum HapticFeedback {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    static func selectionChanged() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }
}

struct HapticButtonStyle: ButtonStyle {
    var style: UIImpactFeedbackGenerator.FeedbackStyle = .light

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed {
                    HapticFeedback.impact(style)
                }
            }
    }
}

// MARK: - View Extension

extension View {
    func liquidGlass(cornerRadius: CGFloat = 24, opacity: Double = 0.15) -> some View {
        modifier(LiquidGlassBackground(cornerRadius: cornerRadius, opacity: opacity))
    }
}
