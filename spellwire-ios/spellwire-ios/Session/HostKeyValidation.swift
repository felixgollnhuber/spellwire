import CryptoKit
import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOSSH

typealias HostKeyChallengeHandler = @MainActor (HostKeyChallenge, @escaping (Bool) -> Void) -> Void

nonisolated enum HostKeyFingerprint {
    static func openSSHString(for hostKey: NIOSSHPublicKey) -> String {
        String(openSSHPublicKey: hostKey)
    }

    static func sha256(for openSSHKey: String) -> String {
        let digest = SHA256.hash(data: Data(openSSHKey.utf8))
        return "SHA256:\(Data(digest).base64EncodedString())"
    }
}

nonisolated final class AppHostKeyValidationDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let host: HostRecord
    private let trustedHost: TrustedHost?
    private let onHostKeyChallenge: HostKeyChallengeHandler

    init(host: HostRecord, trustedHost: TrustedHost?, onHostKeyChallenge: @escaping HostKeyChallengeHandler) {
        self.host = host
        self.trustedHost = trustedHost
        self.onHostKeyChallenge = onHostKeyChallenge
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let openSSHKey = HostKeyFingerprint.openSSHString(for: hostKey)
        let fingerprint = HostKeyFingerprint.sha256(for: openSSHKey)

        if let trustedHost {
            if trustedHost.openSSHKey == openSSHKey {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(
                    TransportError.hostKeyMismatch(
                        expected: trustedHost.fingerprintSHA256,
                        received: fingerprint
                    )
                )
            }
            return
        }

        let challenge = HostKeyChallenge(
            hostLabel: "\(host.hostname):\(host.port)",
            fingerprint: fingerprint,
            openSSHKey: openSSHKey
        )

        Task { @MainActor in
            self.onHostKeyChallenge(challenge) { approved in
                approved
                    ? validationCompletePromise.succeed(())
                    : validationCompletePromise.fail(TransportError.rejectedHostKey)
            }
        }
    }
}
