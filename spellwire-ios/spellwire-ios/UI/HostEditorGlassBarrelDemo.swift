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

    private let edgeGlassHeight: CGFloat = 82

    private let dragSlotSize: CGFloat = 44
    private let dragSensitivity: Double = 0.38

    // Items per second.
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
                    // Background inside the card.
                    shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(white: 0.18),
                                    Color(white: 0.09),
                                    Color(white: 0.03)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    // Moving text barrel.
                    TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
                        let elapsed = timeline.date.timeIntervalSinceReferenceDate - startTime

                        let loopLength = Double(max(words.count, 1))
                        let autoPosition = (elapsed * autoSpeed)
                            .truncatingRemainder(dividingBy: loopLength)

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

                    // Tiny full-pane tint so the card still reads as one surface.
                    // This does not blur the readable center.
                    shape
                        .fill(.black.opacity(0.035))
                        .allowsHitTesting(false)

                    // Dimming only at the top and bottom.
                    // The center stays clear so the text remains readable.
                    EdgeDimmingLayer(
                        cornerRadius: cornerRadius,
                        edgeHeight: edgeGlassHeight
                    )
                    .allowsHitTesting(false)

                    // Real Liquid Glass only at the top and bottom.
                    // This gives the edges the heavy glass look without destroying the center.
                    EdgeLiquidGlassLayer(
                        cornerRadius: cornerRadius,
                        edgeHeight: edgeGlassHeight
                    )
                    .allowsHitTesting(false)

                    // Edge shine only.
                    EdgeShineLayer(
                        cornerRadius: cornerRadius,
                        edgeHeight: edgeGlassHeight
                    )
                    .allowsHitTesting(false)

                    // Full outline.
                    shape
                        .strokeBorder(.white.opacity(0.28), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .frame(width: paneWidth, height: paneHeight)
                .clipShape(shape)
                .contentShape(shape)
                .shadow(color: .black.opacity(0.28), radius: 22, y: 14)
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

            Text("Text barrel behind edge-only Liquid Glass. The center stays readable while the top and bottom fade into glass.")
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

                // Use font-size changes instead of scaleEffect.
                // scaleEffect makes moving text softer.
                let fontSize = 27 + CGFloat(front) * 8

                if fade > 0.02 {
                    Text(text)
                        .font(.system(size: fontSize, weight: .heavy, design: .rounded))
                        .tracking(1.5)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(width: 270, height: 44)
                        .opacity(fade)
                        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
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

private struct EdgeLiquidGlassLayer: View {
    let cornerRadius: CGFloat
    let edgeHeight: CGFloat

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: cornerRadius,
            style: .continuous
        )

        shape
            .fill(.white.opacity(0.001))
            .liquidGlassPane(cornerRadius: cornerRadius)
            .mask {
                EdgeFadeMask(
                    cornerRadius: cornerRadius,
                    edgeHeight: edgeHeight
                )
            }
    }
}

private struct EdgeDimmingLayer: View {
    let cornerRadius: CGFloat
    let edgeHeight: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.black.opacity(0.18))
            .mask {
                EdgeFadeMask(
                    cornerRadius: cornerRadius,
                    edgeHeight: edgeHeight
                )
            }
    }
}

private struct EdgeShineLayer: View {
    let cornerRadius: CGFloat
    let edgeHeight: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.32), location: 0.00),
                        .init(color: .white.opacity(0.12), location: 0.18),
                        .init(color: .clear, location: 0.50),
                        .init(color: .white.opacity(0.08), location: 0.82),
                        .init(color: .white.opacity(0.22), location: 1.00)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .blendMode(.screen)
            .mask {
                EdgeFadeMask(
                    cornerRadius: cornerRadius,
                    edgeHeight: edgeHeight
                )
            }
    }
}

private struct EdgeFadeMask: View {
    let cornerRadius: CGFloat
    let edgeHeight: CGFloat

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: cornerRadius,
            style: .continuous
        )

        GeometryReader { proxy in
            VStack(spacing: 0) {
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0.00),
                        .init(color: .white.opacity(0.85), location: 0.28),
                        .init(color: .white.opacity(0.35), location: 0.68),
                        .init(color: .white.opacity(0.00), location: 1.00)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: min(edgeHeight, proxy.size.height / 2))

                Spacer(minLength: 0)

                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.00), location: 0.00),
                        .init(color: .white.opacity(0.35), location: 0.32),
                        .init(color: .white.opacity(0.85), location: 0.72),
                        .init(color: .white, location: 1.00)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: min(edgeHeight, proxy.size.height / 2))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(shape)
        }
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
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

#Preview {
    HostEditorGlassBarrelDemo()
}