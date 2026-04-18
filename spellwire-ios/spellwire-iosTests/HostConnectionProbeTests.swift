import XCTest
@testable import spellwire_ios

@MainActor
final class HostConnectionProbeTests: XCTestCase {
    func testTrustPromptAndApprovalEmitWarningThenSuccess() {
        let pair = HapticsClient.recording { _ in }
        let probe = HostConnectionProbe(haptics: pair.client)
        let challenge = HostKeyChallenge(
            hostLabel: "Mac mini",
            fingerprint: "SHA256:test",
            openSSHKey: "ssh-ed25519 AAAATEST"
        )

        probe.presentHostKeyChallenge(challenge) { _ in }
        probe.resolveHostKeyChallenge(approved: true)

        XCTAssertEqual(pair.recorder.events, [.warning, .success])
    }

    func testTransportOutcomesEmitSuccessAndError() {
        let pair = HapticsClient.recording { _ in }
        let probe = HostConnectionProbe(haptics: pair.client)

        probe.transportDidConnect()
        probe.transportDidDisconnect(error: TransportError.connectionFailed("Lost"))

        XCTAssertEqual(pair.recorder.events, [.success, .error])
    }
}
