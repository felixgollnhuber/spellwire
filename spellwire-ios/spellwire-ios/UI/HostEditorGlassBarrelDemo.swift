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

                    // Only this part moves.
                    // The glass pane does not get recreated every animation frame.
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

                    // Dimming layer behind glass.
                    shape
                        .fill(.black.opacity(0.12))
                        .allowsHitTesting(false)

                    // One Liquid Glass pane in front.
                    shape
                        .fill(.white.opacity(0.001))
                        .liquidGlassPane(cornerRadius: cornerRadius)
                        .overlay {
                            shape
                                .stroke(.white.opacity(0.24), lineWidth: 1)
                        }
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
                let fade = max(0, min(1, (front - 0.06) / 0.94))

                let radius = axis == .vertical ? verticalRadius : wheelRadius
                let travel = CGFloat(sin(arc)) * radius

                Text(text)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 250, height: 44)
                    .scaleEffect(
                        x: axis == .vertical
                            ? 0.72 + CGFloat(front) * 0.28
                            : 0.92 + CGFloat(front) * 0.08,
                        y: axis == .wheelPickerStyle
                            ? 0.72 + CGFloat(front) * 0.28
                            : 0.92 + CGFloat(front) * 0.08
                    )
                    .opacity(fade)
                    .shadow(color: .black.opacity(0.55), radius: 12, y: 4)
                    .offset(
                        x: axis == .vertical ? travel : 0,
                        y: axis == .wheelPickerStyle ? travel : 0
                    )
                    .zIndex(front)
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