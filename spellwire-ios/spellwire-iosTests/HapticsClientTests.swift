import XCTest
@testable import spellwire_ios

@MainActor
final class HapticsClientTests: XCTestCase {
    func testEventMappingUsesExpectedPatterns() {
        XCTAssertEqual(HapticEvent.selection.pattern, .selection)
        XCTAssertEqual(HapticEvent.confirmation.pattern, .impact(.light))
        XCTAssertEqual(HapticEvent.success.pattern, .notification(.success))
        XCTAssertEqual(HapticEvent.warning.pattern, .notification(.warning))
        XCTAssertEqual(HapticEvent.error.pattern, .notification(.error))
    }

    func testRecordingClientCapturesEventsInOrder() {
        let pair = HapticsClient.recording { _ in }

        pair.client.play(.selection)
        pair.client.play(.success)
        pair.client.play(.error)

        XCTAssertEqual(pair.recorder.events, [.selection, .success, .error])
    }

    func testNoOpClientAcceptsEvents() {
        HapticsClient.noop.play(.warning)
        HapticsClient.noop.play(.success)
    }
}
