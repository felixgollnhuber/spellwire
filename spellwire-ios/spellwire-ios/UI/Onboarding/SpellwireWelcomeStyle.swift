import SwiftUI

enum SpellwirePalette {
    static let foreground = Color(uiColor: .label)
    static let secondaryForeground = Color(uiColor: .secondaryLabel)
    static let accent = Color(red: 0.22, green: 0.24, blue: 0.26)
    static let accentSoft = Color(red: 0.44, green: 0.47, blue: 0.50)
    static let accentSuccess = Color(red: 0.39, green: 0.72, blue: 0.55)

    static func backgroundStops(for colorScheme: ColorScheme) -> [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.05, green: 0.06, blue: 0.07),
                Color(red: 0.08, green: 0.09, blue: 0.10),
                Color(red: 0.10, green: 0.11, blue: 0.12),
            ]
        }

        return [
            Color(red: 0.97, green: 0.97, blue: 0.96),
            Color(red: 0.95, green: 0.95, blue: 0.94),
            Color(red: 0.93, green: 0.93, blue: 0.92),
        ]
    }

    static func panelFill(for colorScheme: ColorScheme) -> Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.06)
        }

        return Color.white.opacity(0.72)
    }

    static func panelStroke(for colorScheme: ColorScheme) -> Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.08)
        }

        return Color.black.opacity(0.08)
    }

    static func glow(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
    }

    static func secondaryGlow(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.04) : Color.white.opacity(0.88)
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

enum SpellwireActionButtonVariant: Sendable {
    case primary
    case secondary
    case outline
    case ghost
    case destructive
}

enum SpellwireActionButtonSize: Sendable {
    case sm
    case md
    case lg
    case xl

    var height: CGFloat {
        switch self {
        case .sm: 32
        case .md: 40
        case .lg: 48
        case .xl: 56
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .sm: 12
        case .md: 16
        case .lg: 18
        case .xl: 20
        }
    }

    var font: Font {
        switch self {
        case .sm: .spellwireBody(15, weight: .semibold)
        case .md: .spellwireBody(16, weight: .semibold)
        case .lg: .spellwireBody(17, weight: .semibold)
        case .xl: .spellwireBody(18, weight: .semibold)
        }
    }

    var isFullWidthByDefault: Bool { self == .xl }
}

struct SpellwireActionButton<Label: View>: View {
    private let variant: SpellwireActionButtonVariant
    private let size: SpellwireActionButtonSize
    private let tint: Color
    private let fullWidth: Bool
    private let isLoading: Bool
    private let action: () -> Void
    private let label: () -> Label

    init(
        variant: SpellwireActionButtonVariant = .primary,
        size: SpellwireActionButtonSize = .md,
        tint: Color = SpellwirePalette.accent,
        fullWidth: Bool? = nil,
        isLoading: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.variant = variant
        self.size = size
        self.tint = tint
        self.fullWidth = fullWidth ?? size.isFullWidthByDefault
        self.isLoading = isLoading
        self.action = action
        self.label = label
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.height / 2, style: .continuous)

        Button(action: action) {
            ZStack {
                label()
                    .opacity(isLoading ? 0 : 1)

                if isLoading {
                    ProgressView()
                }
            }
            .font(size.font)
            .padding(.horizontal, size.horizontalPadding)
            .frame(height: size.height)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .contentShape(shape)
        }
        .contentShape(shape)
        .buttonStyle(SpellwireActionButtonPressStyle())
        .modifier(
            SpellwireActionButtonChrome(
                variant: variant,
                height: size.height,
                tint: tint
            )
        )
        .disabled(isLoading)
    }
}

struct SpellwireActionNavigationLink<Destination: View, Label: View>: View {
    private let destination: Destination
    private let variant: SpellwireActionButtonVariant
    private let size: SpellwireActionButtonSize
    private let tint: Color
    private let fullWidth: Bool
    private let label: () -> Label

    init(
        destination: Destination,
        variant: SpellwireActionButtonVariant = .primary,
        size: SpellwireActionButtonSize = .md,
        tint: Color = SpellwirePalette.accent,
        fullWidth: Bool? = nil,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.destination = destination
        self.variant = variant
        self.size = size
        self.tint = tint
        self.fullWidth = fullWidth ?? size.isFullWidthByDefault
        self.label = label
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.height / 2, style: .continuous)

        NavigationLink(destination: destination) {
            label()
                .font(size.font)
                .padding(.horizontal, size.horizontalPadding)
                .frame(height: size.height)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .contentShape(shape)
        }
        .buttonStyle(SpellwireActionButtonPressStyle())
        .modifier(
            SpellwireActionButtonChrome(
                variant: variant,
                height: size.height,
                tint: tint
            )
        )
    }
}

private struct SpellwireActionButtonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26.0, *) {
            configuration.label
        } else {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .opacity(configuration.isPressed ? 0.92 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
        }
    }
}

private struct SpellwireActionButtonChrome: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    let variant: SpellwireActionButtonVariant
    let height: CGFloat
    let tint: Color

    private var cornerRadius: CGFloat { height / 2 }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            ios26Glass(content: content)
        } else {
            fallback(content: content)
        }
    }

    @available(iOS 26.0, *)
    private func ios26Glass(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        let glass: Glass = {
            switch variant {
            case .primary:
                return .regular.tint(tint).interactive()
            case .secondary:
                return .regular.interactive()
            case .outline:
                return .clear.interactive()
            case .ghost:
                return .clear.interactive()
            case .destructive:
                return .regular.tint(.red).interactive()
            }
        }()

        let foreground: AnyShapeStyle = {
            switch variant {
            case .primary, .destructive:
                return AnyShapeStyle(.white)
            case .secondary:
                return AnyShapeStyle(.primary)
            case .outline, .ghost:
                return AnyShapeStyle(tint)
            }
        }()

        return content
            .foregroundStyle(foreground)
            .glassEffect(glass, in: shape)
            .overlay {
                if variant == .outline {
                    shape.strokeBorder(tint.opacity(0.45), lineWidth: 1)
                }
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.55)
    }

    private func fallback(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        let foreground: AnyShapeStyle = {
            switch variant {
            case .primary, .destructive:
                return AnyShapeStyle(.white)
            case .secondary:
                return AnyShapeStyle(.primary)
            case .outline, .ghost:
                return AnyShapeStyle(tint)
            }
        }()

        return content
            .foregroundStyle(foreground)
            .background {
                switch variant {
                case .primary:
                    shape.fill(tint.opacity(0.22))
                        .background(shape.fill(.regularMaterial))
                case .secondary:
                    shape.fill(.thinMaterial)
                case .outline, .ghost:
                    shape.fill(.clear)
                case .destructive:
                    shape.fill(Color.red.opacity(0.22))
                        .background(shape.fill(.regularMaterial))
                }
            }
            .overlay {
                switch variant {
                case .primary:
                    shape.strokeBorder(tint.opacity(0.18), lineWidth: 1)
                case .secondary:
                    shape.strokeBorder(.primary.opacity(0.10), lineWidth: 1)
                case .outline:
                    shape.strokeBorder(tint.opacity(0.55), lineWidth: 1)
                case .ghost:
                    EmptyView()
                case .destructive:
                    shape.strokeBorder(Color.red.opacity(0.22), lineWidth: 1)
                }
            }
            .opacity(isEnabled ? 1 : 0.55)
            .contentShape(shape)
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
