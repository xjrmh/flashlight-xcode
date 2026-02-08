import SwiftUI

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
    let title: String
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
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(isActive ? .black : .white)
            .padding(.horizontal, 20)
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
        .buttonStyle(.plain)
    }
}

// MARK: - Liquid Glass Toggle

struct LiquidGlassToggle: View {
    @Binding var isOn: Bool
    var size: CGFloat = 80

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                isOn.toggle()
            }
        } label: {
            ZStack {
                // Outer ring
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: size, height: size)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: isOn
                                ? [Color.white.opacity(0.9), Color.white.opacity(0.3)]
                                : [Color.white.opacity(0.15), Color.white.opacity(0.05)],
                            center: .center,
                            startRadius: 0,
                            endRadius: size / 2
                        )
                    )
                    .frame(width: size, height: size)

                // Glass border
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isOn ? 0.8 : 0.3),
                                Color.white.opacity(isOn ? 0.3 : 0.1),
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
            }
        }
        .buttonStyle(.plain)
        .shadow(color: isOn ? .white.opacity(0.4) : .clear, radius: 20)
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
                        }
                )
            }
            .frame(height: 22)
        }
    }
}

// MARK: - View Extension

extension View {
    func liquidGlass(cornerRadius: CGFloat = 24, opacity: Double = 0.15) -> some View {
        modifier(LiquidGlassBackground(cornerRadius: cornerRadius, opacity: opacity))
    }
}
