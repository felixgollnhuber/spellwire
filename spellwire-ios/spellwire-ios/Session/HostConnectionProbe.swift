import Foundation
import Observation

struct ApprovedHostTrust: Sendable {
    let openSSHKey: String
    let fingerprintSHA256: String
}

@MainActor
@Observable
final class HostConnectionProbe: TerminalTransportDelegate {
    var state: TerminalConnectionState = .idle
    var errorMessage: String?
    var pendingHostKeyChallenge: HostKeyChallenge?
    private(set) var approvedHostTrust: ApprovedHostTrust?

    private let haptics: HapticsClient
    private var transport: TerminalTransport?
    private var pendingTrustReply: ((Bool) -> Void)?
    private var didReachConnectedState = false
    private var isDisconnectRequested = false

    init(haptics: HapticsClient? = nil) {
        self.haptics = haptics ?? .live
    }

    func connect(host: HostRecord, identity: SSHDeviceIdentity) {
        disconnect()

        state = .connecting
        errorMessage = nil
        pendingHostKeyChallenge = nil
        pendingTrustReply = nil
        didReachConnectedState = false
        isDisconnectRequested = false

        do {
            let transport = SSHTerminalTransport(
                host: host,
                identity: try identity.clientIdentity(username: host.username),
                trustedHost: trustedHostForRetry,
                context: TerminalSessionContext(
                    title: host.nickname,
                    workingDirectory: nil,
                    prefersTmuxResume: host.prefersTmuxResume,
                    tmuxSessionName: host.tmuxSessionName
                )
            ) { [weak self] challenge, reply in
                guard let self else { return }
                self.presentHostKeyChallenge(challenge, reply: reply)
            }

            transport.delegate = self
            self.transport = transport
            transport.connect()
        } catch {
            state = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
            haptics.play(.error)
        }
    }

    func disconnect() {
        isDisconnectRequested = true
        transport?.disconnect()
        transport = nil
        pendingTrustReply = nil
        pendingHostKeyChallenge = nil
    }

    func resetApprovedTrust() {
        approvedHostTrust = nil
    }

    func presentHostKeyChallenge(_ challenge: HostKeyChallenge, reply: @escaping (Bool) -> Void) {
        state = .trustPrompt
        pendingHostKeyChallenge = challenge
        pendingTrustReply = reply
        haptics.play(.warning)
    }

    func resolveHostKeyChallenge(approved: Bool) {
        guard let challenge = pendingHostKeyChallenge else { return }

        if approved {
            approvedHostTrust = ApprovedHostTrust(
                openSSHKey: challenge.openSSHKey,
                fingerprintSHA256: challenge.fingerprint
            )
        }

        pendingHostKeyChallenge = nil
        let reply = pendingTrustReply
        pendingTrustReply = nil
        haptics.play(approved ? .success : .warning)
        reply?(approved)
    }

    func transportDidConnect() {
        didReachConnectedState = true
        state = .connected
        errorMessage = nil
        haptics.play(.success)
    }

    func transportDidReceive(data: Data) {}

    func transportDidDisconnect(error: Error?) {
        transport = nil
        pendingTrustReply = nil

        if isDisconnectRequested, didReachConnectedState {
            return
        }

        if let error {
            state = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
            haptics.play(.error)
        } else {
            state = .disconnected
        }
    }

    func transportDidReceiveExitStatus(_ status: Int32) {}

    private var trustedHostForRetry: TrustedHost? {
        guard let approvedHostTrust else { return nil }
        return TrustedHost(
            hostID: UUID(),
            openSSHKey: approvedHostTrust.openSSHKey,
            fingerprintSHA256: approvedHostTrust.fingerprintSHA256,
            approvedAt: .now
        )
    }
}
