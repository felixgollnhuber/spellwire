import UIKit

enum HapticEvent: Equatable {
    case selection
    case confirmation
    case success
    case warning
    case error

    var pattern: HapticPattern {
        switch self {
        case .selection:
            return .selection
        case .confirmation:
            return .impact(.light)
        case .success:
            return .notification(.success)
        case .warning:
            return .notification(.warning)
        case .error:
            return .notification(.error)
        }
    }
}

enum HapticPattern: Equatable {
    case selection
    case impact(UIImpactFeedbackGenerator.FeedbackStyle)
    case notification(UINotificationFeedbackGenerator.FeedbackType)
}

@MainActor
struct HapticsClient {
    private let performer: (HapticEvent) -> Void

    init(perform: @escaping (HapticEvent) -> Void) {
        performer = perform
    }

    func play(_ event: HapticEvent) {
        performer(event)
    }

    static let noop = HapticsClient { _ in }

    static let live = HapticsClient { event in
        LiveHapticsPerformer.shared.play(event.pattern)
    }

    static func recording(_ sink: @escaping ([HapticEvent]) -> Void) -> (client: HapticsClient, recorder: HapticsRecorder) {
        let recorder = HapticsRecorder(onChange: sink)
        return (
            HapticsClient { event in
                recorder.record(event)
            },
            recorder
        )
    }
}

@MainActor
final class HapticsRecorder {
    private(set) var events: [HapticEvent] = []
    private let onChange: ([HapticEvent]) -> Void

    init(onChange: @escaping ([HapticEvent]) -> Void = { _ in }) {
        self.onChange = onChange
    }

    func record(_ event: HapticEvent) {
        events.append(event)
        onChange(events)
    }
}

@MainActor
private final class LiveHapticsPerformer {
    static let shared = LiveHapticsPerformer()

    private let selectionGenerator = UISelectionFeedbackGenerator()
    private let lightImpactGenerator = UIImpactFeedbackGenerator(style: .light)
    private let notificationGenerator = UINotificationFeedbackGenerator()

    func play(_ pattern: HapticPattern) {
        switch pattern {
        case .selection:
            selectionGenerator.selectionChanged()
            selectionGenerator.prepare()
        case .impact(let style):
            let generator: UIImpactFeedbackGenerator
            switch style {
            case .light:
                generator = lightImpactGenerator
            default:
                generator = UIImpactFeedbackGenerator(style: style)
            }
            generator.impactOccurred()
            generator.prepare()
        case .notification(let type):
            notificationGenerator.notificationOccurred(type)
            notificationGenerator.prepare()
        }
    }
}
