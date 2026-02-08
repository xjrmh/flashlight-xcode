import SwiftUI

/// A reference sheet showing the morse code alphabet
struct MorseReferenceSheet: View {
    @Environment(\.dismiss) var dismiss

    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible()),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // Letters section
                        sectionHeader("LETTERS")

                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), id: \.self) { letter in
                                if let morse = MorseCode.characterToMorse[letter] {
                                    morseCard(String(letter), morse: morse)
                                }
                            }
                        }

                        // Numbers section
                        sectionHeader("NUMBERS")

                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(Array("0123456789"), id: \.self) { digit in
                                if let morse = MorseCode.characterToMorse[digit] {
                                    morseCard(String(digit), morse: morse)
                                }
                            }
                        }

                        // Timing reference
                        sectionHeader("TIMING")

                        LiquidGlassCard(cornerRadius: 16, padding: 16) {
                            VStack(alignment: .leading, spacing: 12) {
                                timingRow("Dot", duration: "1 unit", visual: dotVisual)
                                timingRow("Dash", duration: "3 units", visual: dashVisual)
                                Divider().background(Color.white.opacity(0.1))
                                timingRow("Element gap", duration: "1 unit", visual: nil)
                                timingRow("Letter gap", duration: "3 units", visual: nil)
                                timingRow("Word gap", duration: "7 units", visual: nil)
                            }
                        }

                        Color.clear.frame(height: 40)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Morse Code Reference")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.cyan)
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .bold))
            .tracking(3)
            .foregroundStyle(.white.opacity(0.4))
    }

    private func morseCard(_ character: String, morse: String) -> some View {
        HStack(spacing: 8) {
            Text(character)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 28)

            // Visual dots and dashes
            HStack(spacing: 2) {
                ForEach(Array(morse.enumerated()), id: \.offset) { _, element in
                    if element == "." {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.cyan.opacity(0.7))
                            .frame(width: 6, height: 10)
                    } else if element == "-" {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.cyan.opacity(0.7))
                            .frame(width: 16, height: 10)
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .modifier(LiquidGlassBackground(cornerRadius: 12, opacity: 0.08))
    }

    private var dotVisual: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.cyan.opacity(0.7))
            .frame(width: 8, height: 12)
    }

    private var dashVisual: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.cyan.opacity(0.7))
            .frame(width: 24, height: 12)
    }

    private func timingRow(_ label: String, duration: String, visual: (some View)?) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))

            Spacer()

            if let visual = visual {
                AnyView(visual)
                    .padding(.trailing, 8)
            }

            Text(duration)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

#Preview {
    MorseReferenceSheet()
}
