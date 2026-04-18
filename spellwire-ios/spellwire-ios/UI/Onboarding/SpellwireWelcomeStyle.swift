import SwiftUI

enum SpellwirePalette {
    static let foreground = Color(uiColor: .label)
    static let secondaryForeground = Color(uiColor: .secondaryLabel)
    static let accent = Color(red: 0.16, green: 0.63, blue: 0.98)
    static let accentSoft = Color(red: 0.52, green: 0.83, blue: 1.0)
    static let accentSuccess = Color(red: 0.24, green: 0.82, blue: 0.52)

    static func backgroundStops(for colorScheme: ColorScheme) -> [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.03, green: 0.05, blue: 0.09),
                Color(red: 0.06, green: 0.10, blue: 0.16),
                Color(red: 0.04, green: 0.16, blue: 0.18),
            ]
        }

        return [
            Color(red: 0.94, green: 0.97, blue: 1.0),
            Color(red: 0.90, green: 0.96, blue: 0.99),
            Color(red: 0.92, green: 0.98, blue: 0.96),
        ]
    }

    static func panelFill(for colorScheme: ColorScheme) -> Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.08)
        }

        return Color.white.opacity(0.56)
    }

    static func panelStroke(for colorScheme: ColorScheme) -> Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.10)
        }

        return Color.black.opacity(0.06)
    }

    static func glow(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? accent.opacity(0.36) : accent.opacity(0.22)
    }

    static func secondaryGlow(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? accentSoft.opacity(0.16) : Color.white.opacity(0.94)
    }
}

extension Font {
    static func spellwireDisplay(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }

    static func spellwireBody(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

struct SpellwireCanvas: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .foregroundStyle(SpellwirePalette.foreground)
            .background {
                ZStack {
                    LinearGradient(
                        colors: SpellwirePalette.backgroundStops(for: colorScheme),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    Circle()
                        .fill(SpellwirePalette.glow(for: colorScheme))
                        .frame(width: 320, height: 320)
                        .blur(radius: 40)
                        .offset(x: 132, y: -250)

                    Circle()
                        .fill(SpellwirePalette.secondaryGlow(for: colorScheme))
                        .frame(width: 360, height: 360)
                        .blur(radius: 88)
                        .offset(x: -120, y: 330)

                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.03 : 0.14),
                            .clear,
                            Color.white.opacity(colorScheme == .dark ? 0.02 : 0.08),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
                .ignoresSafeArea()
            }
    }
}

struct SpellwireBlurRiseOnAppear: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .blur(radius: reduceMotion ? 0 : (isVisible ? 0 : 14))
            .opacity(isVisible ? 1 : 0)
            .offset(y: reduceMotion ? 0 : (isVisible ? 0 : 24))
            .animation(.easeOut(duration: reduceMotion ? 0.18 : 0.7), value: isVisible)
            .onAppear {
                isVisible = true
            }
    }
}

struct SpellwireGlassPanel<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            content
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(SpellwirePalette.panelFill(for: colorScheme))
                .overlay {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(SpellwirePalette.panelStroke(for: colorScheme), lineWidth: 1)
                }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 30))
    }
}

extension View {
    func spellwireCanvas() -> some View {
        modifier(SpellwireCanvas())
    }

    func spellwireBlurRiseOnAppear() -> some View {
        modifier(SpellwireBlurRiseOnAppear())
    }
}
