import SwiftUI

private enum BarrelAxis: String, CaseIterable, Identifiable, Equatable {
    case wheelPickerStyle
    case vertical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wheelPickerStyle:
            return "Wheel"
        case .vertical:
            return "Vertical"
        }
    }

    func dragAmount(from value: DragGesture.Value) -> CGFloat {
        switch self {
        case .wheelPickerStyle:
            return value.translation.height
        case .vertical:
            return value.translation.width
        }
    }
}

struct HostEditorGlassBarrelDemo: View {
    private let words = [
        "SWIFTUI",
        "LIQUID",
        "GLASS",
        "BARREL",
        "ROLLING",
        "TEXT",
        "BEHIND",
        "PANE"
    ]

    private let maxPaneWidth: CGFloat = 330
    private let paneHeight: CGFloat = 230
    private let cornerRadius: CGFloat = 34

    private let dragSlotSize: CGFloat = 44
    private let dragSensitivity: Double = 0.38
    private let autoSpeed: Double = 0.85

    @State private var axis: BarrelAxis = .wheelPickerStyle
    @State private var basePosition: Double = 0
    @State private var startTime = Date.now.timeIntervalSinceReferenceDate

    @GestureState private var dragPosition: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Axis", selection: $axis) {
                ForEach(BarrelAxis.allCases) { axis in
                    Text(axis.title).tag(axis)
                }
            }
            .pickerStyle(.segmented)

            GeometryReader { proxy in
                let paneWidth = min(proxy.size.width, maxPaneWidth)
                let shape = RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )

                ZStack {
                    // Background.
                    shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(white: 0.14),
                                    Color(white: 0.08),
                                    Color(white: 0.03)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    // Glass base.
                    // This is now BEHIND the text, so it does not blur the letters.
                    shape
                        .fill(.white.opacity(0.001))
                        .liquidGlassPane(cornerRadius: cornerRadius)
                        .allowsHitTesting(false)

                    // Slight dimming so the text still feels inside the pane.
                    shape
                        .fill(.black.opacity(0.08))
                        .allowsHitTesting(false)

                    // Sharp text layer.
                    TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
                        let elapsed = timeline.date.timeIntervalSinceReferenceDate - startTime
                        let autoPosition = elapsed * autoSpeed
                        let position = basePosition + autoPosition + dragPosition

                        TextBarrel(
                            texts: words,
                            position: position,
                            axis: axis
                        )
                        .frame(width: paneWidth, height: paneHeight)
                        .clipped()
                        .transaction { transaction in
                            transaction.animation = nil
                        }
                    }

                    // Non-blurring glass highlight on top.
                    shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.16),
                                    .white.opacity(0.04),
                                    .clear,
                                    .black.opacity(0.10)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .blendMode(.screen)
                        .allowsHitTesting(false)

                    shape
                        .stroke(.white.opacity(0.24), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .frame(width: paneWidth, height: paneHeight)
                .clipShape(shape)
                .contentShape(shape)
                .shadow(color: .black.opacity(0.25), radius: 22, y: 14)
                .gesture(
                    DragGesture()
                        .updating($dragPosition) { value, state, _ in
                            let drag = axis.dragAmount(from: value)
                            state = Double(drag / dragSlotSize) * dragSensitivity
                        }
                        .onEnded { value in
                            let drag = axis.dragAmount(from: value)
                            let addedPosition = Double(drag / dragSlotSize) * dragSensitivity

                            basePosition = normalizedPosition(basePosition + addedPosition)
                        }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.snappy, value: axis)
            }
            .frame(height: paneHeight + 20)

            Text("Text barrel in back, one clear glass pane in front. Switch between wheel-style vertical travel and side-to-side travel.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black.ignoresSafeArea())
    }

    private func normalizedPosition(_ position: Double) -> Double {
        guard !words.isEmpty else { return position }

        let count = Double(words.count)
        let remainder = position.truncatingRemainder(dividingBy: count)

        return remainder >= 0 ? remainder : remainder + count
    }
}

private struct TextBarrel: View {
    let texts: [String]
    let position: Double
    let axis: BarrelAxis

    @Environment(\.displayScale) private var displayScale

    private let wheelRadius: CGFloat = 94
    private let verticalRadius: CGFloat = 126

    private var maxDelta: Double {
        max(2, Double(texts.count) / 2)
    }

    var body: some View {
        ZStack {
            ForEach(Array(texts.enumerated()), id: \.offset) { item in
                let index = item.offset
                let text = item.element

                let delta = circularDelta(
                    index: index,
                    position: position,
                    count: texts.count
                )

                let progress = delta / maxDelta
                let arc = progress * (.pi / 2)

                let front = max(0, cos(arc))
                let fade = max(0, min(1, (front - 0.05) / 0.95))

                let radius = axis == .vertical ? verticalRadius : wheelRadius
                let rawTravel = CGFloat(sin(arc)) * radius
                let travel = pixelSnapped(rawTravel)

                // Use font size instead of scaleEffect.
                // scaleEffect often makes moving text look soft.
                let fontSize = 27 + CGFloat(front) * 8

                if fade > 0.02 {
                    Text(text)
                        .font(.system(size: fontSize, weight: .bold, design: .rounded))
                        .tracking(1.5)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(width: 270, height: 44)
                        .opacity(fade)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .offset(
                            x: axis == .vertical ? travel : 0,
                            y: axis == .wheelPickerStyle ? travel : 0
                        )
                        .zIndex(front)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func circularDelta(index: Int, position: Double, count: Int) -> Double {
        guard count > 0 else { return 0 }

        let countValue = Double(count)
        var delta = Double(index) - position

        delta = delta.truncatingRemainder(dividingBy: countValue)

        if delta > countValue / 2 {
            delta -= countValue
        }

        if delta < -countValue / 2 {
            delta += countValue
        }

        return delta
    }

    private func pixelSnapped(_ value: CGFloat) -> CGFloat {
        guard displayScale > 0 else { return value }

        return (value * displayScale).rounded() / displayScale
    }
}

private extension View {
    @ViewBuilder
    func liquidGlassPane(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: cornerRadius,
            style: .continuous
        )

        if #available(iOS 26.0, *) {
            self.glassEffect(.clear, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

#Preview {
    HostEditorGlassBarrelDemo()
}